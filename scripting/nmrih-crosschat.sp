#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>
#include <morecolors>
#include <ripext>
#include <commandline>

// Comms plugins are optional: gag checks degrade gracefully when absent
#undef REQUIRE_PLUGIN
#include <basecomm>
#include <sourcecomms>
#define REQUIRE_PLUGIN

#define PLUGIN_VERSION "1.0.0"
#define PLUGIN_DESCRIPTION "Cross-server chat via command with per-player cooldown"

#define MAX_MSG_BUFFER 512
#define MAX_NAME_BUFFER 64
#define MAX_SID_BUFFER 32

public Plugin myinfo =
{
	name        = "[NMRiH] CrossChat",
	author      = "Baimiao2534",
	description = PLUGIN_DESCRIPTION,
	version     = PLUGIN_VERSION,
};

// ===== ConVars =====
ConVar cvEnabled;
ConVar cvServerId;
ConVar cvUrl;
ConVar cvToken;
ConVar cvCooldown;
ConVar cvAdminFlag;
ConVar cvFetchInterval;
ConVar cvMaxLen;
ConVar cvPrefix;
ConVar cvConsoleEnabled;
ConVar cvConsoleCooldown;
ConVar cvConsoleName;
ConVar cvRequireAuth;

// ===== Cookies =====
Cookie gH_CookieExempt;
Cookie gH_CookieCooldown;

// ===== Runtime state =====
int gI_LastId = -1;                     // Highest relay message id already consumed
bool gB_Fetching = false;               // True while a fetch request is in flight
Handle gH_FetchTimer = null;            // Repeating fetch timer

float gF_NextUse[MAXPLAYERS + 1];       // Earliest time each player may send again
bool gB_Exempt[MAXPLAYERS + 1];         // Player-level cooldown exemption
int gI_PlayerCd[MAXPLAYERS + 1];        // Per-player cooldown seconds, -1 = follow global
float gF_ConsoleNextUse = 0.0;          // Earliest time the server console may send again
char gS_StartupSid[MAX_SID_BUFFER];     // -crosschat_sid launch parameter, highest priority server ID

// Players who sent a command while Steam auth was still pending; the message
// is dispatched automatically from OnClientAuthorized
char gS_PendingMsg[MAXPLAYERS + 1][MAX_MSG_BUFFER];
bool gB_HasPending[MAXPLAYERS + 1];

bool gB_BaseComm = false;               // basecomm plugin available
bool gB_SourceComms = false;            // sourcecomms++ plugin available
int gI_FetchFails = 0;                  // Consecutive fetch failures, for throttled logging

public void OnPluginStart()
{
	LoadTranslations("crosschat.phrases");
	LoadTranslations("common.phrases");

	// Create convars and bind config file cfg/sourcemod/plugin.crosschat.cfg
	cvEnabled      = CreateConVar("sm_crosschat_enabled", "1", "Enable/Disable cross-server chat", _, true, 0.0, true, 1.0);
	cvServerId     = CreateConVar("sm_crosschat_serverid", "S1", "Short server identifier shown as message prefix. Set per process via the -crosschat_sid startup parameter", FCVAR_DONTRECORD);
	cvUrl          = CreateConVar("sm_crosschat_url", "", "Full URL of the PHP relay endpoint, e.g. https://example.com/relay/api.php");
	cvToken        = CreateConVar("sm_crosschat_token", "", "Shared auth token (UUID), must match the relay config.php or data/token.json");
	cvCooldown     = CreateConVar("sm_crosschat_cooldown", "30", "Default per-player cooldown in seconds", _, true, 0.0);
	cvAdminFlag    = CreateConVar("sm_crosschat_adminflag", "b", "Admin flag letter(s) that bypass cooldown automatically, empty to disable");
	cvFetchInterval= CreateConVar("sm_crosschat_fetchinterval", "2.0", "Seconds between relay polls", _, true, 1.0, true, 60.0);
	cvMaxLen       = CreateConVar("sm_crosschat_maxlen", "128", "Maximum message length in characters", _, true, 16.0, true, 512.0);
	cvPrefix       = CreateConVar("sm_crosschat_prefix", "CrossChat", "Chat prefix (without brackets)");
	cvConsoleEnabled = CreateConVar("sm_crosschat_console_enabled", "0", "Allow the server console to send cross-server messages", _, true, 0.0, true, 1.0);
	cvConsoleCooldown = CreateConVar("sm_crosschat_console_cooldown", "0", "Server console send cooldown in seconds, 0 = no cooldown", _, true, 0.0);
	cvConsoleName  = CreateConVar("sm_crosschat_console_name", "Console", "Display name for server console messages");
	cvRequireAuth  = CreateConVar("sm_crosschat_require_auth", "1", "Require Steam authentication before players may send messages", _, true, 0.0, true, 1.0);

	CreateConVar("sm_crosschat_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION, FCVAR_SPONLY | FCVAR_NOTIFY | FCVAR_DONTRECORD);

	// Player and server console command: client 0 takes the console branch
	RegConsoleCmd("sm_crosschat", Cmd_CrossChat, "sm_crosschat <message> - send a message to all servers");

	// Admin commands
	RegAdminCmd("sm_crosschat_exempt", Cmd_Exempt, ADMFLAG_GENERIC, "sm_crosschat_exempt <player> - toggle cooldown exemption for a player");
	RegAdminCmd("sm_crosschat_cd", Cmd_Cd, ADMFLAG_GENERIC, "sm_crosschat_cd <player> <seconds|-1> - set per-player cooldown, -1 follows global");
	RegAdminCmd("sm_crosschat_resetcd", Cmd_ResetCd, ADMFLAG_GENERIC, "sm_crosschat_resetcd <player> - clear a player's current cooldown wait");
	RegAdminCmd("sm_crosschat_status", Cmd_Status, ADMFLAG_GENERIC, "sm_crosschat_status <player> - show a player's cooldown configuration");
	RegAdminCmd("sm_crosschat_toggle", Cmd_Toggle, ADMFLAG_CONFIG, "sm_crosschat_toggle - enable or disable cross-server chat");

	// Player preference cookies, persisted per SteamID by clientprefs
	gH_CookieExempt   = new Cookie("crosschat_exempt", "CrossChat cooldown exemption", CookieAccess_Protected);
	gH_CookieCooldown = new Cookie("crosschat_cd", "CrossChat per-player cooldown", CookieAccess_Protected);

	cvFetchInterval.AddChangeHook(OnFetchIntervalChanged);

	// Cache the -crosschat_sid launch parameter so each process of a
	// multi-process server can carry its own identity on its command line
	GetCommandLineParam("-crosschat_sid", gS_StartupSid, sizeof(gS_StartupSid));
	if (gS_StartupSid[0] != '\0')
	{
		PrintToServer("[CrossChat] Startup parameter -crosschat_sid active, server ID locked to \"%s\"", gS_StartupSid);
	}

	AutoExecConfig(true, "plugin.crosschat");

	// AutoExecConfig only creates the file when missing; upgrade installs keep
	// the old file and miss newly added convars, so append any that are absent
	MigrateConfig();
}

/**
 * Keeps an existing plugin.crosschat.cfg in sync across upgrades:
 * appends newly introduced convars and strips obsolete entries.
 */
void MigrateConfig()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "cfg/sourcemod/plugin.crosschat.cfg");

	if (!FileExists(path))
	{
		return;  // First install: AutoExecConfig writes the complete file
	}

	// Read all lines once; stale lines are filtered out below
	ArrayList lines = new ArrayList(ByteCountToCells(256));
	ArrayList known = new ArrayList(ByteCountToCells(64));

	File file = OpenFile(path, "r");
	if (file == null)
	{
		delete lines;
		delete known;
		return;
	}

	char line[256], name[64];
	bool removedStale = false;
	while (file.ReadLine(line, sizeof(line)))
	{
		// Strip the trailing newline; WriteLine re-adds it uniformly
		TrimString(line);

		// Detect the cvar name at the start of a non-comment line
		int start = 0;
		while (line[start] == ' ' || line[start] == '\t') start++;

		if (line[start] == 's')
		{
			int i;
			for (i = start; i < sizeof(line) && line[i] != ' ' && line[i] != '\t' && line[i] != '\r' && line[i] != '\n' && line[i] != '\0'; i++) {}
			int len = i - start;
			if (len > 0 && len < sizeof(name))
			{
				strcopy(name, len + 1, line[start]);

				// sm_crosschat_serverid is FCVAR_DONTRECORD by design: the
				// identity comes from the -crosschat_sid startup parameter,
				// never from the shared config file. Strip stale entries.
				if (StrEqual(name, "sm_crosschat_serverid"))
				{
					removedStale = true;
					continue;
				}

				known.PushString(name);
			}
		}

		lines.PushString(line);
	}
	delete file;

	// Append convars introduced in later versions, each with a version banner
	static const char convarNames[][] = {
		"sm_crosschat_enabled", "sm_crosschat_url",
		"sm_crosschat_token", "sm_crosschat_cooldown", "sm_crosschat_adminflag",
		"sm_crosschat_fetchinterval", "sm_crosschat_maxlen", "sm_crosschat_prefix",
		"sm_crosschat_console_enabled", "sm_crosschat_console_cooldown",
		"sm_crosschat_console_name", "sm_crosschat_require_auth",
	};

	bool added = false;
	char defVal[192], buf[256];
	ConVar cvar;
	for (int i = 0; i < sizeof(convarNames); i++)
	{
		bool found = false;
		for (int j = 0; j < known.Length; j++)
		{
			known.GetString(j, name, sizeof(name));
			if (StrEqual(name, convarNames[i]))
			{
				found = true;
				break;
			}
		}

		if (found)
		{
			continue;
		}

		cvar = FindConVar(convarNames[i]);
		if (cvar == null)
		{
			continue;
		}

		if (!added)
		{
			FormatEx(buf, sizeof(buf), "// ---- Added by upgrade to %s ----", PLUGIN_VERSION);
			lines.PushString("");
			lines.PushString(buf);
			added = true;
		}

		cvar.GetDefault(defVal, sizeof(defVal));
		if (defVal[0] == '\0')
		{
			FormatEx(buf, sizeof(buf), "%s \"\"", convarNames[i]);
		}
		else
		{
			FormatEx(buf, sizeof(buf), "%s \"%s\"", convarNames[i], defVal);
		}
		lines.PushString(buf);
	}

	// Rewrite only when the file actually changed
	if (removedStale || added)
	{
		file = OpenFile(path, "w");
		if (file != null)
		{
			for (int i = 0; i < lines.Length; i++)
			{
				lines.GetString(i, line, sizeof(line));
				file.WriteLine("%s", line);
			}
			delete file;
			PrintToServer("[CrossChat] Configuration file migrated (obsolete entries removed, new entries appended)");
		}
	}

	delete lines;
	delete known;
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
	// basecomm / sourcecomms natives stay optional so the plugin loads without them
	MarkNativeAsOptional("BaseComm_IsClientGagged");
	MarkNativeAsOptional("SourceComms_GetClientGagType");
	return APLRes_Success;
}

// ===== Library tracking for optional gag checks =====

public void OnAllPluginsLoaded()
{
	gB_BaseComm    = LibraryExists("basecomm");
	gB_SourceComms = LibraryExists("sourcecomms++");
	CreateFetchTimer();
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "basecomm"))      gB_BaseComm = true;
	if (StrEqual(name, "sourcecomms++")) gB_SourceComms = true;
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "basecomm"))      gB_BaseComm = false;
	if (StrEqual(name, "sourcecomms++")) gB_SourceComms = false;
}

public void OnMapStart()
{
	// Fetch timer does not survive map changes, rebuild it
	CreateFetchTimer();
}

public void OnConfigsExecuted()
{
	// Startup parameter takes priority over the cfg file; mirror it into the
	// convar so sm_crosschat_serverid reflects the effective identity
	if (gS_StartupSid[0] != '\0')
	{
		cvServerId.SetString(gS_StartupSid);
	}
	CreateFetchTimer();
}

void OnFetchIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	CreateFetchTimer();
}

void CreateFetchTimer()
{
	delete gH_FetchTimer;
	gH_FetchTimer = CreateTimer(cvFetchInterval.FloatValue, Timer_Fetch, _, TIMER_REPEAT);
}

// ===== Client lifecycle =====

public void OnClientCookiesCached(int client)
{
	char value[16];

	gH_CookieExempt.Get(client, value, sizeof(value));
	gB_Exempt[client] = (value[0] == '1');

	gH_CookieCooldown.Get(client, value, sizeof(value));
	gI_PlayerCd[client] = (value[0] == '\0') ? -1 : StringToInt(value);
}

public void OnClientDisconnect(int client)
{
	gF_NextUse[client] = 0.0;
	gB_Exempt[client] = false;
	gI_PlayerCd[client] = -1;
	gB_HasPending[client] = false;
	gS_PendingMsg[client][0] = '\0';
}

public void OnClientAuthorized(int client, const char[] auth)
{
	// Dispatch the message the player queued while Steam auth was pending
	if (gB_HasPending[client] && IsClientInGame(client))
	{
		char message[MAX_MSG_BUFFER];
		strcopy(message, sizeof(message), gS_PendingMsg[client]);
		gB_HasPending[client] = false;
		gS_PendingMsg[client][0] = '\0';
		SendPlayerMessage(client, message);
	}
}

// ===== Server identity =====

/**
 * Resolves the effective server identifier.
 * The -crosschat_sid launch parameter always wins so each process of a
 * multi-process server carries its own identity; otherwise the
 * sm_crosschat_serverid convar applies, falling back to S1.
 */
void GetEffectiveServerId(char[] sid, int maxlen)
{
	if (gS_StartupSid[0] != '\0')
	{
		strcopy(sid, maxlen, gS_StartupSid);
		return;
	}

	cvServerId.GetString(sid, maxlen);
	if (sid[0] == '\0')
	{
		strcopy(sid, maxlen, "S1");
	}
}

// ===== Player command =====

public Action Cmd_CrossChat(int client, int args)
{
	// Server console (client 0) takes the console branch; in-game clients
	// and admins can never reach it
	if (client == 0)
	{
		return ConsoleSend(args);
	}

	char prefix[64];
	cvPrefix.GetString(prefix, sizeof(prefix));

	if (!cvEnabled.BoolValue)
	{
		CReplyToCommand(client, "%t", "Disabled", prefix);
		return Plugin_Handled;
	}

	// Show usage and personal cooldown status when called without arguments
	if (args < 1)
	{
		CReplyToCommand(client, "%t", "Usage", prefix);
		int remaining = GetRemainingCooldown(client);
		if (remaining > 0)
		{
			CReplyToCommand(client, "%t", "Cooldown Remaining", prefix, remaining);
		}
		else
		{
			CReplyToCommand(client, "%t", "Ready To Send", prefix);
		}
		return Plugin_Handled;
	}

	char url[256];
	cvUrl.GetString(url, sizeof(url));
	if (url[0] == '\0')
	{
		CReplyToCommand(client, "%t", "Not Configured", prefix);
		return Plugin_Handled;
	}

	// Blocked players are not allowed to relay messages
	if (IsGagged(client))
	{
		CReplyToCommand(client, "%t", "Gagged", prefix);
		return Plugin_Handled;
	}

	int auth = GetSteamAccountID(client);
	if (auth == 0 && cvRequireAuth.BoolValue)
	{
		// Steam auth still pending: queue the message instead of rejecting it,
		// then retry from OnClientAuthorized
		GetCmdArgString(gS_PendingMsg[client], sizeof(gS_PendingMsg[]));
		StripCmdQuotes(gS_PendingMsg[client]);
		gB_HasPending[client] = true;
		CReplyToCommand(client, "%t", "Auth Pending", prefix);
		return Plugin_Handled;
	}

	// Enforce cooldown unless exempt
	int remaining = GetRemainingCooldown(client);
	if (remaining > 0)
	{
		CReplyToCommand(client, "%t", "Cooldown Remaining", prefix, remaining);
		return Plugin_Handled;
	}

	char message[MAX_MSG_BUFFER];
	GetCmdArgString(message, sizeof(message));
	StripCmdQuotes(message);

	SendPlayerMessage(client, message);

	return Plugin_Handled;
}

/**
 * Validates and relays a player message. Called directly when Steam auth is
 * already done, or deferred from OnClientAuthorized for queued messages.
 * With require_auth disabled, unauthenticated players relay auth=0.
 */
void SendPlayerMessage(int client, const char[] message)
{
	char prefix[64];
	cvPrefix.GetString(prefix, sizeof(prefix));

	char url[256];
	cvUrl.GetString(url, sizeof(url));
	if (url[0] == '\0')
	{
		return;
	}

	// Drop empty input and other command prefixes leaking into the relay
	if (message[0] == '\0' || message[0] == '/' || message[0] == '!' || message[0] == '@')
	{
		return;
	}

	int auth = GetSteamAccountID(client);
	if (auth == 0 && cvRequireAuth.BoolValue)
	{
		return;
	}

	// Enforce cooldown unless exempt
	int remaining = GetRemainingCooldown(client);
	if (remaining > 0)
	{
		CPrintToChat(client, "%t", "Cooldown Remaining", prefix, remaining);
		return;
	}

	char msgBuf[MAX_MSG_BUFFER];
	strcopy(msgBuf, sizeof(msgBuf), message);
	TruncateUtf8Chars(msgBuf, cvMaxLen.IntValue);

	char name[MAX_NAME_BUFFER];
	GetClientName(client, name, sizeof(name));
	TrimString(name);

	char sid[MAX_SID_BUFFER];
	GetEffectiveServerId(sid, sizeof(sid));

	char token[128];
	cvToken.GetString(token, sizeof(token));

	// Reserve the cooldown slot before the async request leaves
	int cooldown = GetEffectiveCooldown(client);
	if (cooldown > 0)
	{
		gF_NextUse[client] = GetGameTime() + float(cooldown);
	}

	// Log the outgoing message like a regular say line; delivery failures
	// are logged separately in the response callback
	LogToGame("[CrossChat] [%s] %s: %s", sid, name, msgBuf);

	HTTPRequest request = new HTTPRequest(url);
	request.Timeout = 10;
	request.AppendFormParam("action", "send");
	request.AppendFormParam("token", "%s", token);
	request.AppendFormParam("sid", "%s", sid);
	request.AppendFormParam("auth", "%d", auth);
	request.AppendFormParam("name", "%s", name);
	request.AppendFormParam("msg", "%s", msgBuf);
	request.PostForm(SendCallback, GetClientSerial(client));
}

public void SendCallback(HTTPResponse response, any value, const char[] error)
{
	int client = GetClientFromSerial(value);
	if (client == 0 || !IsClientInGame(client))
	{
		return;
	}

	char prefix[64];
	cvPrefix.GetString(prefix, sizeof(prefix));

	if (error[0] != '\0')
	{
		PrintToServer("[CrossChat] Player message failed: %s", error);
		CPrintToChat(client, "%t", "Send Failed", prefix);
	}
	else if (response.Status != HTTPStatus_OK)
	{
		PrintToServer("[CrossChat] Player message failed: HTTP status %d", response.Status);
		CPrintToChat(client, "%t", "Send Failed", prefix);
	}
	else
	{
		CPrintToChat(client, "%t", "Sent", prefix);
	}
}

// ===== Server console branch =====

/**
 * Console broadcast path, reached only when sm_crosschat is issued from the
 * server console (client 0). Governed by its own enable switch, cooldown
 * and display name.
 */
Action ConsoleSend(int args)
{
	if (!cvConsoleEnabled.BoolValue)
	{
		PrintToServer("[CrossChat] Console broadcasting is disabled (sm_crosschat_console_enabled 0)");
		return Plugin_Handled;
	}

	char url[256];
	cvUrl.GetString(url, sizeof(url));
	if (url[0] == '\0')
	{
		PrintToServer("[CrossChat] Relay URL is not configured (sm_crosschat_url)");
		return Plugin_Handled;
	}

	// Independent console cooldown, 0 = unlimited
	int cooldown = cvConsoleCooldown.IntValue;
	if (cooldown > 0)
	{
		float remaining = gF_ConsoleNextUse - GetGameTime();
		if (remaining > 0.0)
		{
			PrintToServer("[CrossChat] Console cooldown active, %d second(s) remaining", RoundToCeil(remaining));
			return Plugin_Handled;
		}
	}

	if (args < 1)
	{
		PrintToServer("[CrossChat] Usage: sm_crosschat <message>");
		return Plugin_Handled;
	}

	char message[MAX_MSG_BUFFER];
	GetCmdArgString(message, sizeof(message));
	StripCmdQuotes(message);

	if (message[0] == '\0' || message[0] == '/' || message[0] == '!' || message[0] == '@')
	{
		return Plugin_Handled;
	}

	TruncateUtf8Chars(message, cvMaxLen.IntValue);

	char name[MAX_NAME_BUFFER];
	cvConsoleName.GetString(name, sizeof(name));
	TrimString(name);
	if (name[0] == '\0')
	{
		strcopy(name, sizeof(name), "Console");
	}

	char sid[MAX_SID_BUFFER];
	GetEffectiveServerId(sid, sizeof(sid));

	char token[128];
	cvToken.GetString(token, sizeof(token));

	if (cooldown > 0)
	{
		gF_ConsoleNextUse = GetGameTime() + float(cooldown);
	}

	// Log the outgoing console message like a regular say line
	LogToGame("[CrossChat] [%s] %s: %s", sid, name, message);

	HTTPRequest request = new HTTPRequest(url);
	request.Timeout = 10;
	request.AppendFormParam("action", "send");
	request.AppendFormParam("token", "%s", token);
	request.AppendFormParam("sid", "%s", sid);
	request.AppendFormParam("auth", "0");  // 0 marks a server console message
	request.AppendFormParam("name", "%s", name);
	request.AppendFormParam("msg", "%s", message);
	request.PostForm(SendCallbackConsole);

	return Plugin_Handled;
}

public void SendCallbackConsole(HTTPResponse response, any value, const char[] error)
{
	if (error[0] != '\0')
	{
		// Transport failure: unreachable host, DNS, TLS verification
		PrintToServer("[CrossChat] Console message failed: %s", error);
	}
	else if (response.Status != HTTPStatus_OK)
	{
		// 400=old relay or empty params, 403=token mismatch, 500=relay error
		PrintToServer("[CrossChat] Console message failed: HTTP status %d", response.Status);
	}
	else
	{
		PrintToServer("[CrossChat] Console message sent to all servers");
	}
}

// ===== Fetch loop =====

public Action Timer_Fetch(Handle timer)
{
	if (!cvEnabled.BoolValue || gB_Fetching)
	{
		return Plugin_Continue;
	}

	char url[256];
	cvUrl.GetString(url, sizeof(url));
	if (url[0] == '\0')
	{
		return Plugin_Continue;
	}

	char sid[MAX_SID_BUFFER];
	GetEffectiveServerId(sid, sizeof(sid));

	char token[128];
	cvToken.GetString(token, sizeof(token));

	gB_Fetching = true;

	HTTPRequest request = new HTTPRequest(url);
	request.Timeout = 10;
	request.AppendQueryParam("action", "fetch");
	request.AppendQueryParam("token", "%s", token);
	request.AppendQueryParam("sid", "%s", sid);
	request.AppendQueryParam("since", "%d", gI_LastId);
	request.Get(FetchCallback);

	return Plugin_Continue;
}

public void FetchCallback(HTTPResponse response, any value, const char[] error)
{
	gB_Fetching = false;

	if (error[0] != '\0' || response.Status != HTTPStatus_OK)
	{
		// Retried silently every tick; log the first failure and then
		// roughly once a minute so persistent problems stay visible
		gI_FetchFails++;
		if (gI_FetchFails == 1 || gI_FetchFails % 30 == 0)
		{
			if (error[0] != '\0')
			{
				PrintToServer("[CrossChat] Fetch failed (%d consecutive): %s", gI_FetchFails, error);
			}
			else
			{
				PrintToServer("[CrossChat] Fetch failed (%d consecutive): HTTP status %d", gI_FetchFails, response.Status);
			}
		}
		return;
	}

	gI_FetchFails = 0;

	// response.Data returns a reference owned by the response; never delete it
	JSONObject root = view_as<JSONObject>(response.Data);
	if (root == null)
	{
		return;
	}

	int last = root.GetInt("last");
	bool firstSync = (gI_LastId == -1);

	// Get() returns a new handle that must be deleted when done
	JSONArray msgs = view_as<JSONArray>(root.Get("msgs"));
	if (msgs != null)
	{
		// On the first poll only adopt the cursor so old messages never flood the chat
		if (!firstSync)
		{
			for (int i = 0; i < msgs.Length; i++)
			{
				JSONObject entry = view_as<JSONObject>(msgs.Get(i));
				if (entry == null)
				{
					continue;
				}

				char sid[MAX_SID_BUFFER];
				char name[MAX_NAME_BUFFER];
				char message[MAX_MSG_BUFFER];

				entry.GetString("s", sid, sizeof(sid));
				entry.GetString("n", name, sizeof(name));
				entry.GetString("m", message, sizeof(message));

				BroadcastIncoming(sid, name, message);
				delete entry;
			}
		}
		delete msgs;
	}

	if (last > gI_LastId)
	{
		gI_LastId = last;
	}

	// Announce the cursor adoption once so skipped history is never mysterious
	if (firstSync)
	{
		PrintToServer("[CrossChat] Relay connection established, listening from message #%d (earlier messages skipped)", gI_LastId);
	}
}

void BroadcastIncoming(const char[] sid, const char[] name, const char[] message)
{
	char prefix[64];
	cvPrefix.GetString(prefix, sizeof(prefix));

	CPrintToChatAll("%t", "Incoming Message", prefix, sid, name, message);

	// Console echo and game log so cross-server chat leaves the same
	// trail as regular player say messages
	PrintToServer("[CrossChat] [%s] %s: %s", sid, name, message);
	LogToGame("[CrossChat] [%s] %s: %s", sid, name, message);
}

// ===== Admin commands =====

public Action Cmd_Exempt(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[SM] %t", "Exempt Usage");
		return Plugin_Handled;
	}

	char targetArg[MAX_NAME_LENGTH];
	GetCmdArg(1, targetArg, sizeof(targetArg));

	int target = FindTarget(client, targetArg, true, false);
	if (target == -1)
	{
		return Plugin_Handled;
	}

	gB_Exempt[target] = !gB_Exempt[target];

	char value[4];
	strcopy(value, sizeof(value), gB_Exempt[target] ? "1" : "0");
	gH_CookieExempt.Set(target, value);

	char prefix[64];
	cvPrefix.GetString(prefix, sizeof(prefix));

	char targetName[MAX_NAME_LENGTH];
	GetClientName(target, targetName, sizeof(targetName));

	if (gB_Exempt[target])
	{
		ReplyToCommand(client, "%t", "Exempt Enabled", targetName);
		CPrintToChat(target, "%t", "Exempt Enabled Self", prefix);
	}
	else
	{
		ReplyToCommand(client, "%t", "Exempt Disabled", targetName);
		CPrintToChat(target, "%t", "Exempt Disabled Self", prefix);
	}

	return Plugin_Handled;
}

public Action Cmd_Cd(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "[SM] %t", "Cd Usage");
		return Plugin_Handled;
	}

	char targetArg[MAX_NAME_LENGTH];
	GetCmdArg(1, targetArg, sizeof(targetArg));

	int target = FindTarget(client, targetArg, true, false);
	if (target == -1)
	{
		return Plugin_Handled;
	}

	char secondsArg[16];
	GetCmdArg(2, secondsArg, sizeof(secondsArg));
	int seconds = StringToInt(secondsArg);

	// -1 restores "follow the global default" behaviour
	if (seconds < -1)
	{
		ReplyToCommand(client, "[SM] %t", "Cd Usage");
		return Plugin_Handled;
	}

	gI_PlayerCd[target] = seconds;

	char value[16];
	IntToString(seconds, value, sizeof(value));
	gH_CookieCooldown.Set(target, value);

	char targetName[MAX_NAME_LENGTH];
	GetClientName(target, targetName, sizeof(targetName));

	if (seconds == -1)
	{
		ReplyToCommand(client, "%t", "Cd Reset Global", targetName);
	}
	else
	{
		ReplyToCommand(client, "%t", "Cd Set", targetName, seconds);
	}

	return Plugin_Handled;
}

public Action Cmd_ResetCd(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[SM] %t", "ResetCd Usage");
		return Plugin_Handled;
	}

	char targetArg[MAX_NAME_LENGTH];
	GetCmdArg(1, targetArg, sizeof(targetArg));

	int target = FindTarget(client, targetArg, true, false);
	if (target == -1)
	{
		return Plugin_Handled;
	}

	gF_NextUse[target] = 0.0;

	char prefix[64];
	cvPrefix.GetString(prefix, sizeof(prefix));

	char targetName[MAX_NAME_LENGTH];
	GetClientName(target, targetName, sizeof(targetName));

	ReplyToCommand(client, "%t", "ResetCd Done", targetName);
	CPrintToChat(target, "%t", "ResetCd Done Self", prefix);

	return Plugin_Handled;
}

public Action Cmd_Status(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[SM] %t", "Status Usage");
		return Plugin_Handled;
	}

	char targetArg[MAX_NAME_LENGTH];
	GetCmdArg(1, targetArg, sizeof(targetArg));

	int target = FindTarget(client, targetArg, true, false);
	if (target == -1)
	{
		return Plugin_Handled;
	}

	char targetName[MAX_NAME_LENGTH];
	GetClientName(target, targetName, sizeof(targetName));

	if (IsExempt(target))
	{
		ReplyToCommand(client, "%t", "Status Exempt", targetName);
	}
	else
	{
		int cd = GetEffectiveCooldown(target);
		ReplyToCommand(client, "%t", "Status Cooldown", targetName, cd);
	}

	int remaining = GetRemainingCooldown(target);
	if (remaining > 0)
	{
		ReplyToCommand(client, "%t", "Status Remaining", remaining);
	}

	return Plugin_Handled;
}

public Action Cmd_Toggle(int client, int args)
{
	cvEnabled.BoolValue = !cvEnabled.BoolValue;

	if (cvEnabled.BoolValue)
	{
		ReplyToCommand(client, "[SM] %t", "Enabled Message");
	}
	else
	{
		ReplyToCommand(client, "[SM] %t", "Disabled Message");
	}

	return Plugin_Handled;
}

// ===== Cooldown helpers =====

/**
 * Whether the player skips cooldown entirely:
 * admin flag bypass first, then the stored exemption cookie.
 */
bool IsExempt(int client)
{
	if (HasBypassFlag(client))
	{
		return true;
	}
	return gB_Exempt[client];
}

/**
 * Effective cooldown seconds for a player:
 * exemption wins, then personal value, then the global convar.
 */
int GetEffectiveCooldown(int client)
{
	if (IsExempt(client))
	{
		return 0;
	}
	if (gI_PlayerCd[client] >= 0)
	{
		return gI_PlayerCd[client];
	}
	return cvCooldown.IntValue;
}

int GetRemainingCooldown(int client)
{
	float remaining = gF_NextUse[client] - GetGameTime();
	if (remaining <= 0.0)
	{
		return 0;
	}
	return RoundToCeil(remaining);
}

/**
 * Whether the player carries any admin flag listed in sm_crosschat_adminflag.
 */
bool HasBypassFlag(int client)
{
	char flagStr[8];
	cvAdminFlag.GetString(flagStr, sizeof(flagStr));
	if (flagStr[0] == '\0')
	{
		return false;
	}

	AdminId admin = GetUserAdmin(client);
	if (admin == INVALID_ADMIN_ID)
	{
		return false;
	}

	AdminFlag flag;
	for (int i = 0; i < strlen(flagStr); i++)
	{
		if (FindFlagByChar(flagStr[i], flag) && GetAdminFlag(admin, flag, Access_Effective))
		{
			return true;
		}
	}
	return false;
}

// ===== Gag helpers (optional plugins) =====

bool IsGagged(int client)
{
	if (gB_BaseComm && BaseComm_IsClientGagged(client))
	{
		return true;
	}
	if (gB_SourceComms && SourceComms_GetClientGagType(client) != bNot)
	{
		return true;
	}
	return false;
}

// ===== Text helpers =====

/**
 * Truncates a UTF-8 string to maxChars code points without splitting characters.
 */
void TruncateUtf8Chars(char[] text, int maxChars)
{
	int count = 0;
	int len = strlen(text);

	for (int i = 0; i < len; i++)
	{
		// UTF-8 continuation bytes start with 10xxxxxx
		if ((text[i] & 0xC0) != 0x80)
		{
			count++;
			if (count > maxChars)
			{
				text[i] = '\0';
				return;
			}
		}
	}
}

/**
 * Strips surrounding quotes left by GetCmdArgString.
 */
void StripCmdQuotes(char[] text)
{
	int len = strlen(text);
	if (len > 1 && text[0] == '"' && text[len - 1] == '"')
	{
		text[len - 1] = '\0';
		strcopy(text, len, text[1]);
	}
}

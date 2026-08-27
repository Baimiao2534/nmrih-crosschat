# [NMRiH] CrossChat

> Cross-server chat for SourceMod servers, relayed by a lightweight PHP endpoint.

## Overview

CrossChat lets players on different servers talk to each other through a single command. Messages are sent to a central web relay (a plain PHP script, no database required) and polled by every connected server, then displayed in chat with a colored server tag.

Normal chat is never touched: players opt in per message via `/crosschat`, so regular `say`/`say_team`, chat tags and gag plugins keep working as usual.

## Features

- **Command-Based Sending**: players send cross-server messages with `/crosschat <message>` (silent) or `!crosschat <message>`; normal chat is unaffected.
- **Per-Player Cooldown**: global default cooldown, per-player override, and admin exemption — all persisted per SteamID via client cookies.
- **Admin Flag Bypass**: admins carrying a configurable flag automatically skip the cooldown.
- **Server Console Broadcast**: the server console can broadcast messages too, with its own enable switch, cooldown and display name. In-game clients and admins can never trigger the console branch.
- **Multi-Process Ready**: on servers running several srcds processes from one install, each process sets its identity with the `-crosschat_sid` startup parameter, so the shared config file never conflicts.
- **Gag Aware**: messages from gagged players (basecomm or SourceComms++) are refused.
- **Steam Auth Queue**: messages sent before Steam validation completes are queued and delivered automatically once the client authorizes.
- **Chat Logging**: incoming and outgoing messages are echoed to the server console and written to the game log, just like regular player chat.
- **UTF-8 Safe**: message length is counted in characters, not bytes; Chinese server IDs and names display correctly.
- **Config Auto-Migration**: new ConVars introduced by upgrades are appended to the existing config file automatically.
- **Multi-language Support**: translation files for English, Simplified Chinese and Traditional Chinese.

## Requirements

- [SourceMod 1.12](https://www.sourcemod.net/downloads.php?branch=stable)
- [REST in Pawn](https://github.com/ErikMinekus/sm-ripext/releases) — HTTP/JSON extension. Download the zip for your server OS and drop the `addons/sourcemod` contents onto your server.
- [nmrih-crosschat-webrelay](https://github.com/Baimiao2534/nmrih-crosschat-webrelay) — the PHP relay this plugin talks to. Requires PHP 8.5+, no database.

## Installation

1. Install the REST in Pawn extension (see Requirements).
2. Download and extract the attached archive.
3. Drag and drop the folders from the archive directly into your server's `nmrih/addons/sourcemod/` directory.
4. Restart the map or type `sm plugins load nmrih-crosschat` in the console.
5. The plugin will automatically generate its default configuration file on first run.

Deploy the web relay on any PHP 8.5+ host (see the [webrelay repository](https://github.com/Baimiao2534/nmrih-crosschat-webrelay) for instructions), then point `sm_crosschat_url` at it.

## Directory Structure

```
addons/sourcemod/
├── plugins/
│   └── nmrih-crosschat.smx
├── scripting/
│   ├── nmrih-crosschat.sp
│   └── include/
│       ├── ripext.inc
│       └── ripext/
│           ├── http.inc
│           └── json.inc
└── translations/
    ├── crosschat.phrases.txt       (English)
    ├── chi/
    │   └── crosschat.phrases.txt   (Simplified Chinese)
    └── zho/
        └── crosschat.phrases.txt   (Traditional Chinese)
```

## Configuration

The plugin generates a configuration file at:

```
nmrih/cfg/sourcemod/plugin.crosschat.cfg
```

Default configuration:

```c
// Enable/Disable cross-server chat
sm_crosschat_enabled "1"

// Short server identifier shown as message prefix.
// Overridden by the -crosschat_sid startup parameter.
sm_crosschat_serverid "S1"

// Full URL of the PHP relay endpoint
sm_crosschat_url ""

// Shared auth token (UUID), must match the relay
sm_crosschat_token ""

// Default per-player cooldown in seconds
sm_crosschat_cooldown "30"

// Admin flag letter(s) that bypass cooldown automatically, empty to disable
sm_crosschat_adminflag "b"

// Seconds between relay polls
sm_crosschat_fetchinterval "2.0"

// Maximum message length in characters
sm_crosschat_maxlen "128"

// Chat prefix (without brackets)
sm_crosschat_prefix "CrossChat"

// Allow the server console to send cross-server messages
sm_crosschat_console_enabled "0"

// Server console send cooldown in seconds, 0 = no cooldown
sm_crosschat_console_cooldown "0"

// Display name for server console messages
sm_crosschat_console_name "Console"

// Require Steam authentication before players may send messages
sm_crosschat_require_auth "1"
```

### Server Identity

Every server in the relay group must use a **unique** ID, otherwise messages are filtered as "own" and never cross servers. Two ways to set it:

- Single-process servers: set `sm_crosschat_serverid` in the console or `server.cfg`.
- Multi-process servers (several srcds from one install sharing one config file): pass the identity on the command line so each process carries its own:

```bash
./srcds_run -game nmrih -port 28022 ... -crosschat_sid S2 +map nmo_suzhou
```

The startup parameter always wins over the config file. UTF-8 IDs such as `-crosschat_sid "纯净经典"` are supported.

## Commands

### Players

| Command | Description |
|---|---|
| `!crosschat <message>` / `/crosschat <message>` | Send a message to all servers. Without arguments, shows usage and your cooldown status. |

### Admins (ADMFLAG_GENERIC)

| Command | Description |
|---|---|
| `sm_crosschat_exempt <player>` | Toggle cooldown exemption for a player. |
| `sm_crosschat_cd <player> <seconds\|-1>` | Set a per-player cooldown; `-1` restores the global default. |
| `sm_crosschat_resetcd <player>` | Clear a player's current cooldown wait. |
| `sm_crosschat_status <player>` | Show a player's cooldown configuration. |

### Admins (ADMFLAG_CONFIG)

| Command | Description |
|---|---|
| `sm_crosschat_toggle` | Enable or disable cross-server chat. |

### Server Console

| Command | Description |
|---|---|
| `sm_crosschat <message>` | Broadcast a message as the console identity. Governed by `sm_crosschat_console_enabled`, `sm_crosschat_console_cooldown` and `sm_crosschat_console_name`. |

## License

This project is licensed under the [GPL-3.0 License](LICENSE).

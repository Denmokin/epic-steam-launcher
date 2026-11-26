# Epic Steam Launcher

Play Epic Games Store titles from **Steam** (desktop or Big Picture, also over Sunshine/Moonlight) with the **real Steam overlay**, no GlosSI, no HidHide, no injected windows.

## How it works

Steam only puts its overlay into programs it starts, and into everything those programs start. Normally an Epic game is started by an already-running Epic launcher, so it's outside Steam's process tree.

`EpicSteamLauncher.exe --chain` fixes the chain:

```
Steam -> EpicSteamLauncher -> Epic Games Launcher (started fresh) -> game
```

1. Closes any running Epic launcher (and publisher launchers given with `--kill-path`).
2. Starts Epic itself with the game's launch link, as its own child, with Steam's `Steam*` environment markers removed (except `SteamOverlayGameId`). Otherwise launchers like Rockstar's think it's the Steam edition and fail with "Failed to launch Steam".
3. Waits for the game process, stays alive while it runs (Steam shows *Playing*), then closes Epic and leftover launchers so Steam / Big Picture comes back.

It writes a `log.txt` next to itself, including whether each process in the chain has Steam's overlay loaded.

## Shortcut Maker

`ShortcutMaker.ps1` is a small window app:

- lists your installed Epic games (from the new Epic launcher's `installations.jsonl` + catalog cache),
- adds the ones you tick to the Steam accounts you tick, using `EpicSteamLauncher.exe --chain`,
- applies cover art (portrait, wide, hero, logo) from **Epic** or from **Steam / SteamDB**:
  - *Find Steam IDs* looks each game up with Steam's store search (also retries without "Complete/Deluxe/... Edition"); IDs are editable,
  - *Open selected on SteamDB* opens the game on steamdb.info so you can check or copy the right App ID,
  - images come straight from Steam's CDN (SteamDB blocks automated access but shows the same images); games not on Steam fall back to Epic art,
- or from **SteamGridDB** (community art): paste your free API key from steamgriddb.com/profile/preferences/api into the window. It's saved in `steamgriddb.key` next to the script, which git ignores. Missing pictures are filled from Steam, then Epic.
- optionally adds a tile to **Sunshine/Moonlight** (asks for admin permission),
- closes and reopens Steam automatically (Steam must be closed to edit `shortcuts.vdf`; a backup is kept).

## Setup

1. Put `EpicSteamLauncher.cs`, `ShortcutMaker.ps1` and `build.ps1` in a folder **outside `AppData`** (for example `C:\Users\<you>\EpicSteamLauncher`).
2. Build: `powershell -ExecutionPolicy Bypass -File build.ps1`
3. Run: `powershell -ExecutionPolicy Bypass -File ShortcutMaker.ps1`

Turn **off** Epic's "start on boot". The launcher closes Epic before each launch, which would interrupt downloads.

## Launcher options

| Option | Meaning |
|---|---|
| `--uri <link>` | Epic launch link: `com.epicgames.launcher://apps/<namespace>%3A<itemId>%3A<appName>?action=launch&silent=true` |
| `--game <exe>` | The real game process to wait for (e.g. `GTA5_Enhanced.exe`) |
| `--chain` | Start Epic as our child so the game gets the Steam overlay |
| `--hide-launchers` | (chain) Hide Epic/publisher launcher windows while the game loads; shown again if the game hasn't started after `--hide-for` seconds (default 90) |
| `--kill-path <path>` | Close processes whose path contains this after the game (repeatable) |
| `--timeout <s>` | Give up if the game hasn't started (default 300) |
| `--grace <s>` | Wait after the game exits in case it restarts (default 8) |
| `--epic-exe <path>` | Epic launcher exe (default: read from the `com.epicgames.launcher` URL handler) |
| `--dry-run` | Log what would happen, change nothing |

## Notes

- If the Rockstar Games Launcher asks for admin rights on every launch, its install folder isn't writable by your account. Give your account Modify rights on that folder once.
- Started from Big Picture, the launcher brings Big Picture back when the game ends.

- Steam's own overlay is loaded the same way as for any non-Steam game. Anti-cheat (e.g. BattlEye) normally accepts it, but that's up to the game.
- Steam shortcut "Start in" must be **unquoted** with a trailing backslash, or Windows refuses to start it (error 267).
- If you run tools from a packaged (MSIX) app, files written under `AppData` may be redirected and invisible to Steam. Keep everything outside `AppData`.

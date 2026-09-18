# Non-Steam Shortcut Extension for Playnite

Creates non-Steam shortcuts in Steam for the games currently selected in Playnite,
copies your Playnite artwork into Steam's grid folder, and rewrites the Playnite
game to launch through Steam — so the Steam overlay works for the games in your
library that can accept it (see the notes below: sandboxed Xbox / Game Pass
titles and URL-launched games cannot).

Rerunning the extension is safe. It updates the existing shortcut using the
action titled "Launch without Steam".

## Playnite 9 / 10 support

Playnite 9 removed IronPython support entirely (Playnite throws
`IronPython support has been removed in Playnite 9`), which is why the original
`nonsteam.py` stopped working. This version is a PowerShell port —
`NonSteamShortcuts.psm1` — and targets the Playnite 9/10 SDK (SDK 6). Tested
against Playnite 10.60 / SDK 6.17.

The port also tracks the Playnite 9 data model changes:

| Playnite 8                          | Playnite 9 / 10                                        |
| ----------------------------------- | ------------------------------------------------------ |
| `Game.PlayAction` + `Game.OtherActions` | single `Game.GameActions` list with `IsPlayAction` |
| `GameAction.IsHandledByPlugin`      | removed                                                |
| `EmulatorProfileId` is a `Guid`     | now a `string`                                          |
| one emulator profile type           | `CustomEmulatorProfile` and `BuiltInEmulatorProfile`    |
| ROM path on the action              | `Game.Roms`                                             |

## Installation

1. Put this folder in your Playnite `Extensions` folder. It should contain
   `extension.yaml` and `NonSteamShortcuts.psm1`.
2. Restart Playnite, or use "Tools" → "Reload Scripts".

There is nothing to edit by hand. The extension finds your Steam install from
the registry on first run and locates the profile inside it; if more than one
Steam account is present it asks which to use, listing them by account name. You
can change it later with "Extensions" -> "Non-Steam Shortcuts" ->
"Find Steam Install Folder", where you can pick either the Steam install folder
or a specific `userdata\<id>` folder.

## Usage

**Close Steam first.** Steam rewrites `shortcuts.vdf` when it exits, which would
throw away anything written while it was running. The extension warns you if it
sees Steam running.

Select some games, then "Extensions" → "Non-Steam Shortcuts" →
"Create non-Steam shortcuts". Start Steam again afterwards.

Two menu entries are available:

*   **Create non-Steam shortcuts** — creates/updates the shortcuts and fills in
    any artwork slot that is currently empty. Artwork already in Steam's grid
    folder is left alone, so art you got from SteamGridDB, EmuDeck or Steam
    itself is not clobbered.
*   **Create non-Steam shortcuts (replace Steam artwork)** — same, but always
    overwrites the Steam-side artwork with what Playnite has.

## Artwork and metadata

Playnite media is copied into `userdata\<steamid>\config\grid`:

| Playnite            | Steam slot                          | File                |
| ------------------- | ----------------------------------- | ------------------- |
| `CoverImage`        | library capsule / portrait, 600x900 | `<appid>p.<ext>`    |
| `BackgroundImage`   | library hero, 1920x620              | `<appid>_hero.<ext>`|
| `Icon`              | shortcut icon                       | referenced in place |

Playnite covers are usually already 600x900 — the shape SteamGridDB serves — so
if you use the SteamGridDB metadata plugin in Playnite, that art carries straight
through to Steam.

Playnite **categories** are written to the shortcut's `tags`, so they show up as
Steam tags.

## Notes and limitations

*   **App IDs.** A brand new shortcut gets the usual
    `crc32(Exe + AppName) | 0x80000000` id. An existing shortcut keeps whatever
    `appid` it already had, because Steam names grid artwork after that field —
    replacing it would orphan the art already on disk.
*   **Games launched by a library plugin** (Epic, GOG, Ubisoft, etc.) store no
    play action in Playnite; the plugin supplies one at launch time. The
    extension asks the owning plugin for it, so these work without you having to
    set anything up. If a plugin hands back a URL rather than an executable the
    shortcut is still created, but Steam cannot attach the overlay to it.

*   **Microsoft Store / Xbox Game Pass games** are handled specially, because
    the Xbox plugin uses its own play controller and exposes no command line at
    all. The package's `AppxManifest.xml` is read instead:

    *   Titles declaring `Windows.FullTrustApplication` have a real `.exe`, so
        the shortcut targets it directly and Steam gets a process to track.
    *   Packaged UWP apps cannot be started that way at all, so those are
        activated via `explorer.exe shell:AppsFolder\<package>!<app>` — what the
        Xbox plugin itself does. These are listed separately in the results so
        you can see which shortcuts use that route.

    Both launch correctly and Steam tracks them as running. **The Steam overlay
    does not attach to Xbox / Game Pass games either way**, because the game runs
    inside the Microsoft app container. That is a property of the sandbox, not of
    how the shortcut starts them, so there is no way around it from here.

*   **Games must be installed.** A shortcut is a path to an executable, and
    until a game is installed there is nothing to point at. The resolved target
    is verified before anything is written, so an uninstalled game with a stale
    action cannot produce a dead shortcut.
*   **Emulators.** Both custom and built-in emulator profiles are supported.
    Built-in profiles that launch via a Playnite startup script have no fixed
    command line and are skipped.
*   `shortcuts.vdf` is backed up before every run to a timestamped
    `shortcuts.vdf.<yyyyMMdd-HHmmss>.bak` (the ten most recent are kept), and is
    swapped in via a temporary file so an error cannot leave a truncated file
    behind.

## Sources used for shortcut.vdf reverse engineering

*  https://github.com/tirish/steam-shortcut-editor/blob/master/lib/parser.js

    Has a fairly easy to follow VDF parser. The `parseObjectValue()` function recursively calls everything else.

*   https://github.com/CorporalQuesadilla/Steam-Shortcut-Manager/wiki/Steam-Shortcuts-Documentation

    Documents the shortcut fields and the app ID derivation.

## License

MIT — see `LICENSE`.

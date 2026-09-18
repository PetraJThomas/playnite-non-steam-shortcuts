# Non-Steam Shortcut Extension for Playnite

Adds the games you select in Playnite to Steam as non-Steam shortcuts, carries
your Playnite artwork across so they look right in the Steam library, and
rewrites the Playnite entry to launch through Steam.

Rerunning it is safe. Existing shortcuts are updated in place rather than
duplicated, and artwork already in Steam is left alone unless you ask for it to
be replaced.

## Requirements

*   **Playnite 9 or 10.** Tested against Playnite 10.60 (SDK 6.17).
*   **Windows PowerShell 5.1**, which ships with Windows. Nothing to install.
*   **Steam**, installed and signed in at least once.
*   Optionally, a free [SteamGridDB](https://www.steamgriddb.com/) API key for
    artwork Playnite does not have.

### Why this fork exists

Playnite 9 removed IronPython support outright — it throws
`IronPython support has been removed in Playnite 9` — so the original
`nonsteam.py` cannot load on Playnite 9 or later at all. This version is a
PowerShell rewrite against the current SDK. The original files are kept under
[`legacy/`](legacy/) for reference.

The Playnite 9 data model changes it had to absorb:

| Playnite 8                              | Playnite 9 / 10                                    |
| --------------------------------------- | -------------------------------------------------- |
| `Game.PlayAction` + `Game.OtherActions`  | one `Game.GameActions` list with `IsPlayAction`     |
| `GameAction.IsHandledByPlugin`           | removed                                             |
| `EmulatorProfileId` is a `Guid`          | now a `string`                                      |
| one emulator profile type                | `CustomEmulatorProfile` / `BuiltInEmulatorProfile`  |
| ROM path on the action                   | `Game.Roms`                                         |

## Installation

1.  Download this repository (**Code → Download ZIP**) and extract it.
2.  Copy the extracted folder into Playnite's `Extensions` folder:

    ```
    %AppData%\Playnite\Extensions\
    ```

    Or, for a portable install, the `Extensions` folder next to
    `Playnite.DesktopApp.exe`. You can open it from Playnite via
    **Settings → General → Open Extensions Folder**.

3.  The folder must contain `extension.yaml` and `NonSteamShortcuts.psm1` at its
    top level.
4.  Restart Playnite, or use **Tools → Reload Scripts**.

To confirm it loaded, check `playnite.log` for:

```
Loaded script extension: ...\NonSteamShortcuts.psm1, version 0.3.0
```

There is nothing to edit by hand — unlike the original, no paths are hardcoded.

### Updating

Replace `NonSteamShortcuts.psm1` and use **Tools → Reload Scripts**. Your saved
Steam folder and SteamGridDB key live in `%AppData%\Playnite\ExtensionsData` and
survive an update.

### Uninstalling

Delete the folder from `Extensions`. Shortcuts already written to Steam stay
there; remove them from Steam itself if you want them gone.

## First run

The extension finds your Steam install from the registry and locates the profile
inside it. If you have more than one Steam account on the machine it asks which
to use, listing them by account name.

If it cannot find Steam, use **Extensions → Non-Steam Shortcuts → Find Steam
Install Folder** and pick either the Steam install folder (for example
`C:\Program Files (x86)\Steam`) or a specific `userdata\<id>` profile folder —
either works, the profile is resolved from whatever you pick.

## Usage

> **Close Steam first.** Steam rewrites `shortcuts.vdf` when it exits, so
> anything written while it is running gets thrown away. The extension warns you
> if it sees Steam running, but the safe order is: close Steam → run this →
> start Steam.

Select one or more games in Playnite, right-click, then **Non-Steam Shortcuts**:

| Menu entry | What it does |
| ---------- | ------------ |
| **Create non-Steam shortcuts** | Creates or updates the shortcuts. Fills any artwork slot that is currently empty, leaving existing Steam artwork alone. |
| **Create non-Steam shortcuts (replace Steam artwork)** | The same, but always refreshes the Steam-side artwork from Playnite and SteamGridDB. |
| **Replace ALL non-Steam shortcuts with the selected games** | Destructive. See [Keeping Steam in sync](#keeping-steam-in-sync). |

Under **Extensions → Non-Steam Shortcuts** (the main menu) there are three more:

| Menu entry | What it does |
| ---------- | ------------ |
| **Find Steam Install Folder** | Choose which Steam profile to write to. |
| **Set SteamGridDB API key...** | Set or clear the key used for fallback artwork. |
| **Remove shortcuts for games deleted from Playnite** | Tidies up shortcuts whose game is gone. |

A progress window shows which game is being handled and how far through the
selection it is, and can be cancelled. Cancelling stops before anything is
written, so `shortcuts.vdf` is left exactly as it was.

When it finishes you get a summary of what was created, updated, skipped, and
why. Start Steam again to see the results.

### What happens to the Playnite entry

The game's play action becomes a `steam://rungameid/...` URL, and the original
action is kept alongside it, renamed **"Launch without Steam"**. So you can still
launch it directly from Playnite, and rerunning the extension picks that action
back up rather than pointing the shortcut at itself.

## Keeping Steam in sync

Delete a game from Playnite and its Steam shortcut stays behind, pointing at
nothing. There are two ways to clear those out.

### Remove shortcuts for games deleted from Playnite

The careful one. It removes only shortcuts this extension created, whose Playnite
game no longer exists, and asks before touching anything.

A shortcut counts as ours if either of two things says so:

*   a record kept in `owned_shortcuts.json` in the extension's data folder,
    mapping Steam app id to Playnite game id, which Steam cannot alter;
*   a `playnite:<game id>` stamp in the shortcut's `devkitgameid` field, which is
    part of Steam's own shortcut schema and meaningless for an ordinary shortcut.

Two signals rather than one because it is **not established** that Steam
preserves a value written to `devkitgameid` when it rewrites `shortcuts.vdf`. If
it strips it, the record still identifies our entries; if the record is lost, the
stamp still does.

Anything matched by neither is never touched, so shortcuts you added by hand or
with EmuDeck or Steam ROM Manager are safe.

> Shortcuts created before this feature existed are not marked as ours. Run
> "Create non-Steam shortcuts" over those games once and they will be picked up
> from then on.

### Replace ALL non-Steam shortcuts with the selected games

The blunt one, for when you would rather not depend on any of the above. It
throws away **every** non-Steam shortcut and rebuilds the list from the games you
have selected, so Steam ends up with exactly those and nothing else.

It needs no way of telling which shortcuts are ours, because it keeps none of
them. That is also why it is destructive: anything you added by hand or with
another tool goes too, along with launch options and artwork changed outside
Playnite. It says so, counts what will be lost, and defaults to cancelling.

`shortcuts.vdf` is backed up first, so restoring that file undoes it.

## Artwork and metadata

Playnite media is copied into `userdata\<steamid>\config\grid`:

| Playnite            | Steam slot                          | File                 |
| ------------------- | ----------------------------------- | -------------------- |
| `CoverImage`        | library capsule / portrait, 600x900 | `<appid>p.<ext>`     |
| `BackgroundImage`   | library hero, 1920x620              | `<appid>_hero.<ext>` |
| `Icon`              | shortcut icon                       | referenced in place  |

Playnite covers are usually already 600x900 — the shape SteamGridDB serves — so
if you use a SteamGridDB metadata addon in Playnite, that art carries straight
through.

Playnite **categories** are written to the shortcut's `tags`, so they show up as
Steam tags. Tags already on a shortcut are merged with, never replaced, so Steam
collections survive an update.

### SteamGridDB fallback

When Playnite has no cover for a game, the extension can pull fan-made art
straight from [SteamGridDB](https://www.steamgriddb.com/): the 600x900 grid, the
hero, and the logo.

1.  Get a free key at <https://www.steamgriddb.com/profile/preferences/api>.
2.  **Extensions → Non-Steam Shortcuts → Set SteamGridDB API key...** and paste
    it. The key is checked against the API as you save, so a bad one is caught
    immediately.
3.  Run **"replace Steam artwork"** on the games that were missing art.

Clear the field to turn the fallback off again.

The key is encrypted at rest with Windows DPAPI, tied to your Windows account on
this machine, so `steamgriddb_api_key.dat` is unreadable to other users and
useless if copied elsewhere. It is not a vault: anything already running as you
can ask DPAPI to decrypt it just as the extension does. The point is that the key
is not sitting in a text file to be read over your shoulder, synced or backed up.

Playnite's own art always wins — SteamGridDB is only consulted for slots that are
still empty, unless you use "replace Steam artwork". Matching is by game name, so
an unusual name can match the wrong title or nothing at all; `playnite.log`
records what each name matched.

Nothing is invented. With no key set, or when SteamGridDB has nothing, Steam
keeps its own plain name tile, and the summary lists every game that ended up
bare so you always know which ones they are.

## What works, and what does not

*   **Games must be installed.** A shortcut is a path to an executable, so there
    is nothing to point at until then. The target is verified before anything is
    written, so an uninstalled game with a stale action cannot produce a dead
    shortcut.

*   **Games launched by a library plugin** (Epic, GOG, Ubisoft, and so on) store
    no play action in Playnite — the plugin supplies one at launch. The extension
    asks the owning plugin for it, so these work with no setup. If a plugin hands
    back a URL rather than an executable the shortcut still works, but Steam
    cannot attach the overlay to it.

*   **Microsoft Store / Xbox Game Pass games** need special handling, because the
    Xbox plugin uses its own play controller and exposes no command line. The
    package's `AppxManifest.xml` is read instead:

    *   Titles declaring `Windows.FullTrustApplication` have a real `.exe`, so
        the shortcut targets it directly and Steam gets a process to track.
    *   Packaged UWP apps cannot be started that way at all, so those are
        activated via `explorer.exe shell:AppsFolder\<package>!<app>` — what the
        Xbox plugin itself does.

    Both launch correctly and Steam tracks them as running. **The Steam overlay
    does not attach to Xbox / Game Pass titles either way**, because the game runs
    inside the Microsoft app container. That is the sandbox, not the shortcut, so
    there is nothing this extension can do about it.

*   **Emulators.** Custom and built-in emulator profiles are both supported.
    Built-in profiles that launch through a Playnite startup script have no fixed
    command line and are skipped.

*   **Steam games are skipped**, since they are already in Steam.

*   **Two selected games with the same name** collapse onto one shortcut, because
    Steam identifies shortcuts by name. The duplicate is skipped and reported
    rather than silently overwriting the first.

## Safety

*   `shortcuts.vdf` is backed up before every run to a timestamped
    `shortcuts.vdf.<yyyyMMdd-HHmmss>.bak`, keeping the ten most recent.
*   It is written to a temporary file and swapped in, so a failure cannot leave a
    truncated file behind. If the write fails, the backup is restored.
*   Entries are kept in file order rather than re-keyed by name, so shortcuts
    with duplicate or empty names — common with EmuDeck and Steam ROM Manager —
    are preserved rather than dropped.
*   An existing shortcut keeps its stored `appid`, because Steam names grid
    artwork after that field. Replacing it would orphan the art already on disk.

## Troubleshooting

| Symptom | Cause |
| ------- | ----- |
| Menu entries missing | The extension did not load. Check `playnite.log` for `Loaded script extension`, and that `extension.yaml` is at the folder's top level. |
| Shortcuts vanish after closing Steam | Steam was running during the write. Close Steam, run it again. |
| "No Steam user profile was found" | The folder picked has no `userdata\<id>` inside it. Pick the Steam install folder or a profile folder. |
| Plain grey tiles in Steam | No artwork in Playnite and none on SteamGridDB. Give the game a cover in Playnite, then "replace Steam artwork". |
| Game skipped as "not installed" | Install it first — there is no executable to point at yet. |

`playnite.log` records a line for every decision, including what each library
plugin returned and what SteamGridDB matched.

## Sources used for shortcut.vdf reverse engineering

*   <https://github.com/tirish/steam-shortcut-editor/blob/master/lib/parser.js>

    A readable VDF parser; `parseObjectValue()` recursively calls everything else.

*   <https://github.com/CorporalQuesadilla/Steam-Shortcut-Manager/wiki/Steam-Shortcuts-Documentation>

    Documents the shortcut fields and the app ID derivation.

## License

MIT — see [`LICENSE`](LICENSE). Originally by Blake Burkhart; this is a PowerShell
port for Playnite 9/10.

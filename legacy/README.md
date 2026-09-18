# Legacy IronPython version

These are the original Playnite 8 IronPython files, kept for reference and to
keep the diff against upstream readable. They do not run on Playnite 9 or
later: Playnite 9 removed IronPython support outright.

They live in this subfolder rather than the extension root because Playnite
globs `*.*` in an extension's top-level directory and tries to load every file
it finds as a script, which made `nonsteam.py` throw
`Cannot load script file, uknown format.` on every startup.

The working extension is `../NonSteamShortcuts.psm1`.

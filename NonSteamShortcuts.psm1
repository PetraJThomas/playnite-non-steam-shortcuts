# Non-Steam Shortcuts for Playnite 10 (SDK 6)
#
# Originally an IronPython extension by Blake Burkhart (MIT licensed).
# IronPython support was removed in Playnite 9, so this is a PowerShell port.
#
# Creates/updates non-Steam shortcuts in Steam's shortcuts.vdf for the selected
# Playnite games, copies Playnite artwork into Steam's grid folder, and rewrites
# the Playnite play action to launch the game through Steam (so the Steam
# overlay works).

# MessageBoxButton/Image/Result live in PresentationFramework. Playnite is a WPF
# app so it is normally already loaded, but the error paths below must not be
# the thing that discovers otherwise.
Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue

# Default settings for entries in shortcuts.vdf
# See https://github.com/CorporalQuesadilla/Steam-Shortcut-Manager/wiki/Steam-Shortcuts-Documentation
# Be careful if you change these, it is easy to produce a shortcuts.vdf Steam rejects.
$script:ShortcutDefaults = [ordered]@{
    'allowoverlay'        = 1
    'allowdesktopconfig'  = 1
    'shortcutpath'        = ''
    'ishidden'            = 0
    'openvr'              = 0
    'devkit'              = 0
    'devkitgameid'        = ''
    'devkitoverrideappid' = 0
    'lastplaytime'        = 0
    'flatpakappid'        = ''
}

$script:LaunchWithoutSteamName = 'Launch without Steam'
$script:SteamActionName        = 'Non-Steam Steam Shortcut'
$script:SteamPluginId          = [Guid]::Parse('CB91DFC9-B977-43BF-8E70-55F46E410FAB')
$script:RunGameIdPrefix        = 'steam://rungameid/'
$script:OwnerPrefix            = 'playnite:'
$script:BackupsToKeep          = 10

# Copy these Playnite media fields into Steam's grid folder.
# Key   = Playnite Game property
# Value = suffix Steam appends to the app id for that art type
$script:GridArtMap = [ordered]@{
    'CoverImage'      = 'p'      # library capsule / portrait, 600x900
    'BackgroundImage' = '_hero'  # library hero banner, 1920x620
}


###############################################################################
# Menu entries
###############################################################################

function GetGameMenuItems
{
    param($getGameMenuItemsArgs)

    $create = New-Object Playnite.SDK.Plugins.ScriptGameMenuItem
    $create.Description  = 'Create non-Steam shortcuts'
    $create.FunctionName = 'Add-NonSteamShortcuts'
    $create.MenuSection  = '@Non-Steam Shortcuts'

    # The "from Playnite" pair exists because SteamGridDB matches on the game's
    # name and sometimes gets it wrong - it once answered "Farm Frenzy 3: Ice
    # Age" for "Ice Age 3(TM)". Curating the artwork in Playnite and pushing
    # that across is the way to overrule it, so these two never ask SteamGridDB
    # at all.
    $curated = New-Object Playnite.SDK.Plugins.ScriptGameMenuItem
    $curated.Description  = 'Create non-Steam shortcuts (use Playnite artwork, replacing Steam''s)'
    $curated.FunctionName = 'Add-NonSteamShortcutsFromPlaynite'
    $curated.MenuSection  = '@Non-Steam Shortcuts'

    $rebuild = New-Object Playnite.SDK.Plugins.ScriptGameMenuItem
    $rebuild.Description  = 'Replace ALL non-Steam shortcuts with the selected games'
    $rebuild.FunctionName = 'Reset-NonSteamShortcuts'
    $rebuild.MenuSection  = '@Non-Steam Shortcuts'

    $rebuildCurated = New-Object Playnite.SDK.Plugins.ScriptGameMenuItem
    $rebuildCurated.Description  = 'Replace ALL non-Steam shortcuts with the selected games (use Playnite artwork)'
    $rebuildCurated.FunctionName = 'Reset-NonSteamShortcutsFromPlaynite'
    $rebuildCurated.MenuSection  = '@Non-Steam Shortcuts'

    return @($create, $curated, $rebuild, $rebuildCurated)
}

function GetMainMenuItems
{
    param($getMainMenuItemsArgs)

    $steamFolder = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $steamFolder.Description  = 'Find Steam Install Folder'
    $steamFolder.FunctionName = 'Set-SteamUserdataFolder'
    $steamFolder.MenuSection  = '@Non-Steam Shortcuts'

    $gridKey = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $gridKey.Description  = 'Set SteamGridDB API key...'
    $gridKey.FunctionName = 'Set-SteamGridDbApiKey'
    $gridKey.MenuSection  = '@Non-Steam Shortcuts'

    $sync = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $sync.Description  = 'Remove shortcuts for games deleted from Playnite'
    $sync.FunctionName = 'Sync-NonSteamShortcuts'
    $sync.MenuSection  = '@Non-Steam Shortcuts'

    return @($steamFolder, $gridKey, $sync)
}


###############################################################################
# CRC-32 and Steam app id calculation
#
# Steam derives a shortcut's 32 bit id from a CRC-32 of Exe+AppName with the top
# bit forced high. The original script used pycrc with poly 0x04C11DB7,
# reflected in/out and 0xFFFFFFFF xor in/out, which is exactly standard CRC-32,
# so the table driven version below produces identical ids.
###############################################################################

# Written as decimals on purpose: PowerShell 5.1 parses a hex literal that fits
# in 32 bits as a *signed* Int32, so 0xEDB88320 and 0xFFFFFFFF would come out
# negative and silently corrupt the CRC.
$script:Crc32Poly    = [long]3988292384   # 0xEDB88320, reversed CRC-32 polynomial
$script:Crc32Mask    = [long]4294967295   # 0xFFFFFFFF
$script:AppIdHighBit = [long]2147483648   # 0x80000000
$script:Crc32Table   = $null

function Get-Crc32Table
{
    if ($null -ne $script:Crc32Table) { return ,$script:Crc32Table }

    $table = New-Object 'System.Int64[]' 256
    for ($i = 0; $i -lt 256; $i++) {
        $c = [long]$i
        for ($j = 0; $j -lt 8; $j++) {
            if ($c -band 1) {
                $c = $script:Crc32Poly -bxor [long]($c -shr 1)
            } else {
                $c = [long]($c -shr 1)
            }
        }
        $table[$i] = $c
    }
    $script:Crc32Table = $table
    return ,$table
}

function Get-Crc32
{
    param([byte[]]$Bytes)

    $table = Get-Crc32Table
    $crc = $script:Crc32Mask
    foreach ($b in $Bytes) {
        $idx = [int](($crc -bxor [long]$b) -band 0xFF)
        $crc = ([long]($crc -shr 8)) -bxor $table[$idx]
    }
    return ($crc -bxor $script:Crc32Mask) -band $script:Crc32Mask
}

function Get-ShortcutAppId
{
    <#
        The unsigned 32 bit id Steam uses to name grid artwork, and (as a signed
        int32) as the "appid" field inside shortcuts.vdf.
        Note: Exe is hashed *with* its surrounding quotes, matching Steam and
        every other non-Steam shortcut tool.
    #>
    param([string]$Exe, [string]$AppName)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Exe + $AppName)
    return (Get-Crc32 $bytes) -bor $script:AppIdHighBit
}

function ConvertTo-SignedAppId
{
    # shortcuts.vdf stores the app id in a signed int32 field
    param([long]$AppId)

    if ($AppId -ge 2147483648) { return [int]($AppId - 4294967296) }
    return [int]$AppId
}

function ConvertTo-UnsignedAppId
{
    # grid artwork and rungameid use the unsigned value
    param([long]$AppId)

    if ($AppId -lt 0) { return $AppId + 4294967296 }
    return $AppId
}

function Get-SteamRunGameUrl
{
    param([long]$AppId)

    # (appid << 32) | 0x02000000, computed with multiplication to stay clear of
    # signed shift overflow in PowerShell.
    $full = ([uint64]$AppId * [uint64]4294967296) + [uint64]33554432
    return $script:RunGameIdPrefix + $full.ToString()
}


###############################################################################
# Binary VDF (shortcuts.vdf) reader / writer
#
# 0x00 <key\0> <map...> 0x08   nested map
# 0x01 <key\0> <value\0>       UTF-8 string
# 0x02 <key\0> <int32 LE>      32 bit integer
# 0x08                         end of map
#
# Steam matches keys case insensitively, so all keys are lowercased on read.
###############################################################################

function Read-VdfString
{
    param([byte[]]$Bytes, [ref]$Position)

    $start = $Position.Value
    while ($Position.Value -lt $Bytes.Length -and $Bytes[$Position.Value] -ne 0) {
        $Position.Value++
    }
    if ($Position.Value -ge $Bytes.Length) {
        throw "Unterminated string at offset $start"
    }
    $text = [System.Text.Encoding]::UTF8.GetString($Bytes, $start, $Position.Value - $start)
    $Position.Value++   # consume the null terminator
    return $text
}

function Read-VdfMap
{
    param([byte[]]$Bytes, [ref]$Position)

    $map = [ordered]@{}
    while ($true) {
        if ($Position.Value -ge $Bytes.Length) {
            throw "Unexpected end of file inside a map"
        }
        $type = $Bytes[$Position.Value]
        $Position.Value++

        if ($type -eq 0x08) { break }

        $key = (Read-VdfString $Bytes $Position).ToLowerInvariant()

        switch ($type) {
            0x00 { $map[$key] = Read-VdfMap $Bytes $Position }
            0x01 { $map[$key] = Read-VdfString $Bytes $Position }
            0x02 {
                $map[$key] = [BitConverter]::ToInt32($Bytes, $Position.Value)
                $Position.Value += 4
            }
            default {
                throw ("Unknown VDF value type 0x{0:X2} at offset {1}" -f $type, ($Position.Value - 1))
            }
        }
    }
    # Comma prevents PowerShell from enumerating the dictionary on return
    return ,$map
}

function Read-ShortcutsVdf
{
    <#
        Returns every entry, in file order, as a List. Entries are deliberately
        NOT re-keyed by AppName: real shortcuts.vdf files contain duplicate and
        empty AppNames (EmuDeck, Steam ROM Manager, two emulator entries for one
        title), and keying by name would silently drop them on the next write.
    #>
    param([string]$Path)

    $entries = New-Object 'System.Collections.Generic.List[object]'

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return ,$entries }

    $position = 0
    $root = Read-VdfMap $bytes ([ref]$position)

    if (-not $root.Contains('shortcuts')) {
        throw "shortcuts.vdf has no 'shortcuts' section"
    }

    foreach ($entry in $root['shortcuts'].Values) {
        $entries.Add($entry)
    }
    return ,$entries
}

function Find-OwnedShortcutEntry
{
    <#
        The entry this extension already created for a particular Playnite
        game, found by the identity stamped into it rather than by its name.

        Matching on the name alone was wrong twice over: renaming a game in
        Playnite left the old shortcut orphaned in Steam forever and added a
        second one, and a shortcut someone else had made under the same name -
        EmuDeck, Steam ROM Manager, or by hand - was silently overwritten.
    #>
    param($Entries, [string]$GameId, $Owned)

    if ([string]::IsNullOrWhiteSpace($GameId)) { return $null }
    foreach ($entry in $Entries) {
        if ((Get-ShortcutOwnerId $entry $Owned) -eq $GameId) { return $entry }
    }
    return $null
}

function Find-ShortcutEntry
{
    # Steam compares AppNames case insensitively; first match wins.
    param($Entries, [string]$AppName)

    foreach ($entry in $Entries) {
        $name = $entry['appname']
        if ($name -and [string]::Equals($name, $AppName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $entry
        }
    }
    return $null
}

function Write-VdfCString
{
    param([System.IO.Stream]$Stream, [string]$Text)

    if ($null -eq $Text) { $Text = '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.WriteByte(0x00)
}

function Write-VdfMap
{
    param([System.IO.Stream]$Stream, [string]$Key, $Map)

    $Stream.WriteByte(0x00)
    Write-VdfCString $Stream $Key

    foreach ($k in @($Map.Keys)) {
        $v = $Map[$k]
        if ($v -is [System.Collections.IDictionary]) {
            Write-VdfMap $Stream $k $v
        }
        elseif ($v -is [string]) {
            $Stream.WriteByte(0x01)
            Write-VdfCString $Stream $k
            Write-VdfCString $Stream $v
        }
        elseif ($null -eq $v) {
            # Without this a $null falls into the integer branch below and is
            # written as a type-0x02 field holding 0, so a string key such as
            # 'icon' comes back as a number and Steam can reject the file.
            $Stream.WriteByte(0x01)
            Write-VdfCString $Stream $k
            Write-VdfCString $Stream ''
        }
        else {
            if ($v -is [bool]) { $v = [int]$v }
            $Stream.WriteByte(0x02)
            Write-VdfCString $Stream $k
            $Stream.Write([BitConverter]::GetBytes([int]$v), 0, 4)
        }
    }

    $Stream.WriteByte(0x08)
}

function Write-ShortcutsVdf
{
    <#
        Built in a temp file next to the target, then swapped in with
        File.Replace (or File.Move when there is nothing to replace), so an
        error part way through cannot leave a truncated shortcuts.vdf behind.
    #>
    param([string]$Path, $Entries)

    # Steam expects the entries to be keyed by their index as a string.
    $indexed = [ordered]@{}
    $i = 0
    foreach ($entry in $Entries) {
        $indexed[$i.ToString()] = $entry
        $i++
    }

    $tempPath = "$Path.tmp"
    try {
        $stream = [System.IO.File]::Create($tempPath)
        try {
            Write-VdfMap $stream 'shortcuts' $indexed
            $stream.WriteByte(0x08)
        }
        finally {
            # Push the bytes to the disk before the file is swapped in. Dispose
            # alone only reaches the OS cache, so a power loss moments after a
            # run could commit the rename onto an empty file.
            try { $stream.Flush($true) } catch { }
            $stream.Dispose()
        }

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            # [NullString]::Value, not $null: PowerShell marshals $null to "" for
            # a string parameter and File.Replace then rejects it.
            [System.IO.File]::Replace($tempPath, $Path, [NullString]::Value)
        } else {
            [System.IO.File]::Move($tempPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Backup-ShortcutsVdf
{
    # Timestamped, because clobbering a single .bak means the second run backs
    # up the damage done by the first and the pristine file is gone.
    param([string]$Path)

    $directory = Split-Path -Parent $Path
    $leaf      = Split-Path -Leaf $Path

    # Milliseconds, so two runs in the same second get separate backups AND the
    # fixed-width stamp still sorts lexically by age. A '-2' style suffix would
    # not: '-9' sorts after '-12'.
    $backupPath = '{0}.{1}.bak' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmssfff')
    $suffix = 1
    while (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        $backupPath = '{0}.{1}-{2:D2}.bak' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmssfff'), $suffix
        $suffix++
    }
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force -ErrorAction Stop

    # Prune on the timestamp in the NAME, not LastWriteTime. Copy-Item carries
    # the source's timestamp over, so every backup of a file this extension has
    # rewritten looks newer than the pristine one taken before it ever ran -
    # which made the oldest and most valuable backup the first to be deleted.
    #
    # The name is matched with a regex rather than -Filter because Win32
    # wildcards treat '*.bak' as matching '.bakery' too.
    # \d{3} is optional so backups written by earlier versions, which stamped
    # only to the second, are still recognised, counted and pruned.
    $pattern = '^' + [regex]::Escape($leaf) + '\.\d{8}-\d{6}(\d{3})?(-\d+)?\.bak$'
    # Oldest first: the stamp is fixed width, so the name sorts by age.
    $ours = @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match $pattern } |
              Sort-Object -Property Name)
    if ($ours.Count -gt $script:BackupsToKeep) {
        # The very first backup is the only copy of shortcuts.vdf as it was
        # before this extension ever touched it, which is exactly what someone
        # undoing a "replace ALL" needs. Keep it permanently and thin the
        # middle instead.
        $doomed = $ours[1..($ours.Count - $script:BackupsToKeep)]
        foreach ($f in $doomed) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return $backupPath
}


###############################################################################
# Steam userdata folder discovery
###############################################################################

function Join-PathSafe
{
    # Join-Path throws on a path whose drive no longer exists, which is the
    # normal state of affairs when Steam lives on an external disk that is
    # unplugged. Callers here want an answer, not an exception.
    param([string]$Path, [string]$ChildPath)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        return [System.IO.Path]::Combine($Path, $ChildPath)
    } catch {
        return $null
    }
}

function Test-SteamUserdataDir
{
    <#
        A Steam userdata profile folder is userdata\<numeric account id> and has
        a config subfolder. Checking only for "config" is not enough: the Steam
        install root has one too, and accepting it silently writes shortcuts
        where Steam will never read them.
    #>
    param([string]$Folder)

    if ([string]::IsNullOrWhiteSpace($Folder)) { return $false }
    $config = Join-PathSafe $Folder 'config'
    if (-not $config) { return $false }
    if (-not (Test-Path -LiteralPath $config -PathType Container)) { return $false }

    try {
        $leaf   = Split-Path -Leaf $Folder
        $parent = Split-Path -Leaf (Split-Path -Parent $Folder)
    } catch {
        return $false
    }
    return ($leaf -match '^\d+$') -and ($parent -eq 'userdata')
}

function Get-SteamUserdataConfigPath
{
    Restore-LegacyExtensionData
    if (-not (Test-Path -LiteralPath $CurrentExtensionDataPath -PathType Container)) {
        New-Item -ItemType Directory -Path $CurrentExtensionDataPath -Force | Out-Null
    }
    return (Join-Path $CurrentExtensionDataPath 'steam_userdata_path.txt')
}

function Get-SteamPersonaNames
{
    <#
        Map account id -> persona name from <steam root>\config\loginusers.vdf,
        purely so the profile picker can show a name instead of a bare number.
        loginusers.vdf keys profiles by 64 bit SteamID; the userdata folder is
        named with the lower 32 bits of it.
    #>
    param([string]$SteamRoot)

    $names = @{}
    if ([string]::IsNullOrWhiteSpace($SteamRoot)) { return $names }
    $path = Join-Path $SteamRoot 'config\loginusers.vdf'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $names }

    try {
        $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    } catch {
        return $names
    }

    $steamId = $null
    foreach ($line in ($text -split "`n")) {
        if ($line -match '^\s*"(\d{17})"\s*$') {
            $steamId = [uint64]$Matches[1]
            continue
        }
        if ($null -ne $steamId -and $line -match '^\s*"PersonaName"\s+"(.*)"\s*$') {
            $accountId = $steamId - [uint64]76561197960265728
            $names["$accountId"] = $Matches[1]
            $steamId = $null
        }
    }
    return $names
}

function Get-SteamInstallRoots
{
    $roots = New-Object 'System.Collections.Generic.List[string]'

    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($name in @('SteamPath', 'InstallPath')) {
                $value = $props.$name
                if (-not [string]::IsNullOrWhiteSpace($value)) { $roots.Add($value) }
            }
        } catch { }
    }
    $roots.Add("${env:ProgramFiles(x86)}\Steam")
    $roots.Add("$env:ProgramFiles\Steam")
    return ,([string[]]$roots.ToArray())
}

function Get-SteamProfilesUnder
{
    <#
        Given anything sensible - a Steam install root, a userdata folder, or a
        profile folder itself - return the profile folders it contains.
    #>
    param([string]$Path)

    $found = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrWhiteSpace($Path)) { return ,([string[]]@()) }

    # The profile folder itself
    if (Test-SteamUserdataDir $Path) {
        $found.Add($Path)
        return ,([string[]]$found.ToArray())
    }

    # A userdata folder, or a Steam root containing one
    $userdata = $Path
    try {
        if ((Split-Path -Leaf $Path) -ne 'userdata') {
            $userdata = Join-PathSafe $Path 'userdata'
        }
    } catch {
        return ,([string[]]@())
    }
    if (-not $userdata -or -not (Test-Path -LiteralPath $userdata -PathType Container)) {
        return ,([string[]]@())
    }

    foreach ($dir in (Get-ChildItem -LiteralPath $userdata -Directory -ErrorAction SilentlyContinue)) {
        # "0" and "anonymous" are not real accounts
        if ($dir.Name -eq '0' -or $dir.Name -eq 'anonymous') { continue }
        if (Test-SteamUserdataDir $dir.FullName) { $found.Add($dir.FullName) }
    }
    return ,([string[]]$found.ToArray())
}

function Find-SteamUserdataDirs
{
    <#
        Every Steam profile on this machine, de-duplicated. Steam writes
        SteamPath lowercased with forward slashes while the fallbacks are
        proper-cased with backslashes, so paths are normalised before comparing
        or the same folder gets offered twice.
    #>
    $seen  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $found = New-Object 'System.Collections.Generic.List[string]'

    foreach ($root in (Get-SteamInstallRoots)) {
        foreach ($profileDir in (Get-SteamProfilesUnder $root)) {
            $normalised = $profileDir
            try { $normalised = [System.IO.Path]::GetFullPath($normalised).TrimEnd('\') } catch { }
            if ($seen.Add($normalised)) { $found.Add($normalised) }
        }
    }
    return ,([string[]]$found.ToArray())
}

function Select-SteamProfileInteractively
{
    <#
        More than one Steam account on this machine, so ask which to use.
        Labelled with the persona name wherever loginusers.vdf provides one.
    #>
    param([string[]]$Profiles)

    if ($null -eq $Profiles -or $Profiles.Count -eq 0) { return $null }
    if ($Profiles.Count -eq 1) { return $Profiles[0] }

    # Persona names live in the Steam root, two levels above a profile folder.
    $steamRoot = $null
    try { $steamRoot = Split-Path -Parent (Split-Path -Parent $Profiles[0]) } catch { }
    $names = Get-SteamPersonaNames $steamRoot

    $options = New-Object 'System.Collections.Generic.List[Playnite.SDK.MessageBoxOption]'
    $byTitle = @{}
    $first   = $true
    foreach ($profileDir in $Profiles) {
        $accountId = Split-Path -Leaf $profileDir
        $label     = if ($names.ContainsKey($accountId)) { "$($names[$accountId])  ($accountId)" } else { $accountId }
        if ($byTitle.ContainsKey($label)) { $label = "$label  -  $profileDir" }
        $options.Add((New-Object Playnite.SDK.MessageBoxOption($label, $first, $false)))
        $byTitle[$label] = $profileDir
        $first = $false
    }
    $options.Add((New-Object Playnite.SDK.MessageBoxOption('Cancel', $false, $true)))

    $chosen = $PlayniteApi.Dialogs.ShowMessage(
        'More than one Steam account was found on this machine. Which one should the non-Steam shortcuts be added to?',
        'Non-Steam Shortcuts',
        [System.Windows.MessageBoxImage]::Question,
        $options)

    if ($null -eq $chosen -or $chosen.IsCancel -or -not $byTitle.ContainsKey($chosen.Title)) { return $null }
    return $byTitle[$chosen.Title]
}

function Set-SteamUserdataFolder
{
    param($scriptMainMenuItemActionArgs)

    $folder = Get-SelectedSteamUserdataFolder -Force
    if ($folder) {
        [void]$PlayniteApi.Dialogs.ShowMessage("Steam userdata folder set to:`n$folder", 'Non-Steam Shortcuts')
    }
}

function Select-SteamUserdataFolder
{
    param([switch]$Force)

    $configPath = Get-SteamUserdataConfigPath

    if (-not $Force -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $saved = (Get-Content -LiteralPath $configPath -Raw -ErrorAction SilentlyContinue)
        if ($saved) { $saved = $saved.Trim() }
        if (Test-SteamUserdataDir $saved) { return $saved }

        # An earlier version accepted any folder containing "config", so a saved
        # Steam install root is possible. Repair it instead of nagging.
        $repaired = Get-SteamProfilesUnder $saved
        if ($repaired.Count -ge 1) {
            $picked = Select-SteamProfileInteractively $repaired
            if ($picked) {
                Set-Content -LiteralPath $configPath -Value $picked -Encoding UTF8
                $__logger.Info("Non-Steam: corrected the saved Steam folder from '$saved' to '$picked'")
                return $picked
            }
            return $null
        }
        if (-not [string]::IsNullOrWhiteSpace($saved)) {
            $__logger.Warn("Non-Steam: the saved Steam folder '$saved' is no longer usable, asking again")
        }
    }

    $candidates = Find-SteamUserdataDirs

    if (-not $Force -and $candidates.Count -ge 1) {
        $picked = Select-SteamProfileInteractively $candidates
        if ($picked) {
            Set-Content -LiteralPath $configPath -Value $picked -Encoding UTF8
            $__logger.Info("Non-Steam: using Steam profile $picked")
            return $picked
        }
        return $null
    }

    $message = 'Select your Steam folder.' + [Environment]::NewLine + [Environment]::NewLine
    $message += 'You can pick the Steam install folder itself (for example '
    $message += 'C:\Program Files (x86)\Steam) and the right profile will be found inside it, '
    $message += 'or pick a specific userdata\<id> profile folder.'
    if ($candidates.Count -gt 0) {
        $message += [Environment]::NewLine + [Environment]::NewLine + 'Detected on this machine:' + [Environment]::NewLine
        $message += ($candidates -join [Environment]::NewLine)
    }
    [void]$PlayniteApi.Dialogs.ShowMessage($message, 'Non-Steam Shortcuts')

    $folder = $PlayniteApi.Dialogs.SelectFolder()
    if ([string]::IsNullOrWhiteSpace($folder)) { return $null }

    $profiles = Get-SteamProfilesUnder $folder
    if ($profiles.Count -eq 0) {
        [void]$PlayniteApi.Dialogs.ShowErrorMessage(
            "No Steam user profile was found in:`n$folder`n`nPick your Steam install folder, or a userdata\<id> folder inside it.",
            'Non-Steam Shortcuts')
        return $null
    }

    $picked = Select-SteamProfileInteractively $profiles
    if (-not $picked) { return $null }

    Set-Content -LiteralPath $configPath -Value $picked -Encoding UTF8
    return $picked
}

function Get-SelectedSteamUserdataFolder
{
    <#
        Select-SteamUserdataFolder talks to the user, and anything that leaks to
        the pipeline in there would ride along with its return value. Collapse
        the result to a single validated path, or $null.
    #>
    param([switch]$Force)

    $result = @(Select-SteamUserdataFolder -Force:$Force)
    foreach ($candidate in $result) {
        if ($candidate -is [string] -and (Test-SteamUserdataDir $candidate)) { return $candidate }
    }
    return $null
}

###############################################################################
# Playnite action resolution (Playnite 10 / SDK 6 game model)
###############################################################################

function Test-IsSteamShortcutAction
{
    param($Action)

    if ($Action.Name -eq $script:SteamActionName) { return $true }
    if ($Action.Path -and $Action.Path.StartsWith($script:RunGameIdPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $false
}

function Get-SourcePlayAction
{
    <#
        Find the action describing how the game really launches.

        The shortcut action this extension creates is excluded outright,
        otherwise a rerun after the user deleted "Launch without Steam" would
        resolve the game to its own steam://rungameid/ URL and build a shortcut
        that launches itself.
    #>
    param($Game)

    if (-not $Game.GameActions) { return $null }

    $candidates = @()
    foreach ($action in $Game.GameActions) {
        if (Test-IsSteamShortcutAction $action) { continue }
        $candidates += $action
    }
    if ($candidates.Count -eq 0) { return $null }

    # A play action the user has set since the last run takes priority, so
    # re-running picks up a corrected action instead of a stale stashed one.
    foreach ($action in $candidates) {
        if ($action.IsPlayAction) { return $action }
    }
    # Otherwise the action stashed by a previous run.
    foreach ($action in $candidates) {
        if ($action.Name -eq $script:LaunchWithoutSteamName) { return $action }
    }

    # Nothing here says how the game launches. Falling back to whatever happens
    # to be first would hand the shortcut a "Configure" or "Open save folder"
    # action the user added in Playnite, and because finding any action at all
    # stops the library plugin from being asked, the plugin's real launch
    # command would never be consulted. Better to answer "no idea" and let the
    # caller move on to the plugin and the install folder.
    $__logger.Info("Non-Steam: no play action on $($Game.Name), leaving it to the library plugin")
    return $null
}

# Executables that are never the game, and folders that only ever hold
# redistributables. Mirrors the exclusion list Playnite's own scanner uses.
$script:NonGameExeNames = @(
    'unins', 'uninstall', 'setup', 'dxsetup', 'vcredist', 'vc_redist', 'dotnet',
    'directx', 'crashreport', 'crashhandler', 'unitycrashhandler', 'zsync',
    'notification_helper', 'python', 'pythonw', 'launcher_helper', 'cleanup',
    'activation', 'touchup', 'redist', 'benchmark', 'installer', 'helper',
    'service', 'updater', 'errorreport', 'crashpad'
)
$script:NonGameDirNames = @(
    'directx', 'redist', '_commonredist', 'commonredist', 'vcredist', 'dotnet',
    'installer', 'support', 'prereq', 'prerequisites'
)

function Resolve-InstallDirLaunch
{
    <#
        Last resort, and the generic answer to a problem that is not specific to
        any one store: most library plugins (Ubisoft, EA, Battle.net, itch.io,
        Xbox) return their own PlayController rather than an
        AutomaticPlayController, so GetPlayActions gives us no command line at
        all. Rather than a bespoke resolver per store, find the game's
        executable inside the install folder Playnite already recorded.

        This is a heuristic. It is reported separately so the target can be
        checked, and it is only reached once every precise route has failed.
    #>
    param($Game)

    if (-not $Game.IsInstalled) { return $null }

    $dir = $Game.InstallDirectory
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
        return $null
    }

    $candidates = @()
    try {
        $candidates = @(Get-ChildItem -LiteralPath $dir -Filter '*.exe' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            Where-Object {
                $name = $_.BaseName.ToLowerInvariant()
                $parent = $_.Directory.Name.ToLowerInvariant()
                $badName = $false
                foreach ($bad in $script:NonGameExeNames) { if ($name -like "*$bad*") { $badName = $true; break } }
                $badDir = $false
                foreach ($bad in $script:NonGameDirNames) { if ($parent -eq $bad) { $badDir = $true; break } }
                (-not $badName) -and (-not $badDir)
            })
    } catch {
        $__logger.Warn("Non-Steam: could not scan $dir for $($Game.Name): $($_.Exception.Message)")
        return $null
    }

    if ($candidates.Count -eq 0) {
        # A store can report a game as installed when only a stub remains, so
        # this is a normal outcome rather than a failure.
        $__logger.Info("Non-Steam: no game executable under $dir for $($Game.Name); it may not really be installed")
        return $null
    }

    $chosen = $candidates[0]
    if ($candidates.Count -gt 1) {
        # Prefer a name resembling the game's over merely the biggest file: the
        # largest executable in a folder is often a redistributable installer.
        $key = ($Game.Name -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        $best = $null
        $bestScore = -1
        foreach ($exe in $candidates) {
            $name = ($exe.BaseName -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
            $score = 0
            if ($name -eq $key) { $score = 100 }
            elseif ($name.Length -ge 4 -and $key.StartsWith($name)) { $score = 80 }
            elseif ($key.Length -ge 4 -and $name.StartsWith($key)) { $score = 80 }
            elseif ($name.Length -ge 4 -and $key -like "*$name*") { $score = 60 }
            elseif ($key.Length -ge 4 -and $name -like "*$key*") { $score = 60 }

            if ($score -gt $bestScore -or ($score -eq $bestScore -and $best -and $exe.Length -gt $best.Length)) {
                $best = $exe
                $bestScore = $score
            }
        }
        if ($best) { $chosen = $best }
    }

    $__logger.Info("Non-Steam: picked $($chosen.FullName) for $($Game.Name) by scanning the install folder")
    return @{
        Exe        = $chosen.FullName
        Arguments  = ''
        WorkingDir = $chosen.Directory.FullName
        IsUrl      = $false
        Guessed    = $true
    }
}

function Resolve-MicrosoftStoreLaunch
{
    <#
        Microsoft Store / Xbox Game Pass games.

        The Xbox library plugin hands Playnite its own XboxPlayController rather
        than an AutomaticPlayController, so GetPlayActions yields no command
        line. It activates the package via
        "explorer.exe shell:AppsFolder\<PackageFamilyName>!<AppId>", reading the
        AppId out of the package's AppxManifest.xml. We reconstruct the same
        thing here.

        Titles declaring EntryPoint="Windows.FullTrustApplication" have a real
        .exe we can target directly, which gives Steam a process to track.
        Packaged UWP apps cannot be started that way at all, so those are
        activated through the shell instead.

        Either way the game runs inside the Microsoft app container, so the
        Steam overlay does not attach to Xbox / Game Pass titles. They launch
        and Steam tracks them as running; the overlay is the part that does not
        work, and that is a property of the sandbox rather than of the route
        used to start them.
    #>
    param($Game)

    $pfn = $Game.GameId
    if ([string]::IsNullOrWhiteSpace($pfn) -or $pfn -notmatch '^[A-Za-z0-9.\-]+_[a-z0-9]{13}$') {
        return $null
    }

    # Playnite usually records the package folder; otherwise ask Windows.
    $installDir = $Game.InstallDirectory
    if ([string]::IsNullOrWhiteSpace($installDir) -or -not (Test-Path -LiteralPath $installDir -PathType Container)) {
        try {
            $package = Get-AppxPackage -ErrorAction Stop | Where-Object { $_.PackageFamilyName -eq $pfn } | Select-Object -First 1
            if ($package) { $installDir = $package.InstallLocation }
        } catch {
            $__logger.Warn("Non-Steam: could not query the app package for $($Game.Name): $($_.Exception.Message)")
        }
    }
    if ([string]::IsNullOrWhiteSpace($installDir)) { return $null }

    $appId      = 'App'
    $executable = $null
    $fullTrust  = $false
    try {
        $manifest = [xml](Get-Content -LiteralPath (Join-Path $installDir 'AppxManifest.xml') -Raw -ErrorAction Stop)
        $app = @($manifest.Package.Applications.Application)[0]
        if ($app) {
            if ($app.Id)         { $appId      = $app.Id }
            if ($app.Executable) { $executable = $app.Executable }
            $fullTrust = ($app.EntryPoint -eq 'Windows.FullTrustApplication')
        }
    } catch {
        $__logger.Warn("Non-Steam: could not read AppxManifest.xml for $($Game.Name): $($_.Exception.Message)")
    }

    if ($fullTrust -and $executable) {
        $exePath = Join-Path $installDir $executable
        if (Test-Path -LiteralPath $exePath -PathType Leaf) {
            $__logger.Info("Non-Steam: resolved Microsoft Store game $($Game.Name) to its Win32 executable: $exePath")
            return @{
                Exe        = $exePath
                Arguments  = ''
                WorkingDir = $installDir
                IsUrl      = $false
            }
        }
        $__logger.Warn("Non-Steam: manifest executable not readable for $($Game.Name): $exePath")
    }

    # A packaged UWP app, or the executable could not be reached. Windows will
    # not launch a UWP executable directly, so activate the package the way the
    # Xbox plugin does. Verified working from Steam: the game starts and Steam
    # follows it as a running game.
    $shell = "shell:AppsFolder\$pfn!$appId"
    $__logger.Info("Non-Steam: falling back to shell activation for $($Game.Name): $shell")
    return @{
        Exe        = (Join-Path $env:WINDIR 'explorer.exe')
        Arguments  = $shell
        WorkingDir = $env:WINDIR
        IsUrl      = $false
        NoOverlay  = $true
    }
}

function Resolve-LibraryPluginLaunch
{
    <#
        Library plugins (Ubisoft Connect, Epic, GOG, Xbox, ...) usually store no
        play action in the database at all - they hand one to Playnite at launch
        time. Those games would otherwise all be skipped, so ask the owning
        plugin directly for what it would have run.
    #>
    param($Game)

    if ($Game.PluginId -eq [Guid]::Empty) { return $null }

    $plugin = $null
    foreach ($p in $PlayniteApi.Addons.Plugins) {
        if ($p.Id -eq $Game.PluginId -and $p -is [Playnite.SDK.Plugins.LibraryPlugin]) {
            $plugin = $p
            break
        }
    }
    if (-not $plugin) { return $null }

    # GetPlayActions is a C# iterator, so it returns without running anything and
    # the body only executes on enumeration. Forcing that enumeration here, with
    # @(), keeps it inside this try: otherwise a plugin that throws while
    # enumerating - the Epic plugin does exactly this for a game whose manifest
    # is missing - escapes as an unhandled error and aborts the whole run.
    $controllers = @()
    try {
        $playArgs = New-Object Playnite.SDK.Plugins.GetPlayActionsArgs
        $playArgs.Game = $Game
        $controllers = @($plugin.GetPlayActions($playArgs))
    } catch {
        $__logger.Error("Non-Steam: $($plugin.Name) could not supply a play action for $($Game.Name): $($_.Exception.Message)")
        return $null
    }
    if ($controllers.Count -eq 0) { return $null }

    $result = $null
    $seen   = 0
    foreach ($controller in $controllers) {
        $seen++
        if ($null -eq $result -and
            $controller -is [Playnite.SDK.Plugins.AutomaticPlayController] -and
            -not [string]::IsNullOrWhiteSpace($controller.Path)) {

            $isUrl = ($controller.Type -eq [Playnite.SDK.Plugins.AutomaticPlayActionType]::Url)
            $__logger.Info("Non-Steam: $($plugin.Name) supplied a $($controller.Type) play action for $($Game.Name): $($controller.Path)")
            $result = @{
                Exe        = $controller.Path
                Arguments  = if ($controller.Arguments) { $controller.Arguments } else { '' }
                WorkingDir = $controller.WorkingDir
                IsUrl      = $isUrl
            }
        }
        elseif ($null -eq $result) {
            # Not an AutomaticPlayController, so the plugin launches this game
            # with its own code and exposes no command line we can hand to Steam.
            # Log the concrete type so it is obvious why the game was skipped.
            $__logger.Warn("Non-Steam: $($plugin.Name) returned a $($controller.GetType().Name) for $($Game.Name), which carries no launch command")
        }
        # Controllers hold process handles; release them whether or not we used one.
        if ($controller -is [System.IDisposable]) {
            try { $controller.Dispose() } catch { }
        }
    }
    if ($seen -eq 0) {
        $__logger.Warn("Non-Steam: $($plugin.Name) returned no play controllers for $($Game.Name)")
    }
    return $result
}

function Resolve-EmulatorLaunch
{
    <#
        Playnite 9 replaced the old emulator model with custom profiles (which
        carry their own executable) and built-in profiles (which resolve against
        Playnite's bundled emulator definitions). Returns a hashtable with Exe,
        Arguments and WorkingDir, or $null if the launch cannot be reconstructed.
    #>
    param($Game, $Action)

    $emulator = $PlayniteApi.Database.Emulators.Get($Action.EmulatorId)
    if (-not $emulator) {
        $__logger.Error("Non-Steam: emulator $($Action.EmulatorId) not found for $($Game.Name)")
        return $null
    }

    $profile = $null
    foreach ($p in $emulator.AllProfiles) {
        if ($p.Id -eq $Action.EmulatorProfileId) { $profile = $p; break }
    }
    if (-not $profile) {
        $__logger.Error("Non-Steam: emulator profile $($Action.EmulatorProfileId) not found for $($Game.Name)")
        return $null
    }

    $emulatorDir = $emulator.InstallDir
    if ([string]::IsNullOrWhiteSpace($emulatorDir)) { $emulatorDir = '' }

    if ($profile -is [Playnite.SDK.Models.CustomEmulatorProfile]) {
        $exe       = $profile.Executable
        $arguments = $profile.Arguments
        $workDir   = $profile.WorkingDirectory
    }
    elseif ($profile -is [Playnite.SDK.Models.BuiltInEmulatorProfile]) {
        $definition = $null
        foreach ($d in $PlayniteApi.Emulation.Emulators) {
            if ($d.Id -eq $emulator.BuiltInConfigId) { $definition = $d; break }
        }
        if (-not $definition) {
            $__logger.Error("Non-Steam: built-in emulator definition '$($emulator.BuiltInConfigId)' not found for $($Game.Name)")
            return $null
        }

        $defProfile = $null
        foreach ($dp in $definition.Profiles) {
            if ($dp.Name -eq $profile.BuiltInProfileName) { $defProfile = $dp; break }
        }
        if (-not $defProfile) {
            $__logger.Error("Non-Steam: built-in profile '$($profile.BuiltInProfileName)' not found for $($Game.Name)")
            return $null
        }
        if ($defProfile.ScriptStartup) {
            # This emulator is launched by a Playnite script, there is no fixed
            # command line to hand to Steam.
            $__logger.Warn("Non-Steam: emulator profile '$($defProfile.Name)' uses a startup script, cannot create a shortcut for $($Game.Name)")
            return $null
        }

        $exe       = $defProfile.StartupExecutable
        $arguments = $defProfile.StartupArguments
        $workDir   = $emulatorDir

        if ($profile.OverrideDefaultArgs) {
            $arguments = $profile.CustomArguments
        }
        elseif (-not [string]::IsNullOrWhiteSpace($profile.CustomArguments)) {
            $arguments = ("$arguments " + $profile.CustomArguments).Trim()
        }
    }
    else {
        $__logger.Error("Non-Steam: unsupported emulator profile type for $($Game.Name)")
        return $null
    }

    $exe       = $PlayniteApi.ExpandGameVariables($Game, $exe, $emulatorDir)
    $arguments = $PlayniteApi.ExpandGameVariables($Game, $arguments, $emulatorDir)
    $workDir   = $PlayniteApi.ExpandGameVariables($Game, $workDir, $emulatorDir)

    if ($Action.AdditionalArguments) {
        $expanded = $PlayniteApi.ExpandGameVariables($Game, $Action.AdditionalArguments, $emulatorDir)
        $arguments = ("$arguments $expanded").Trim()
    }
    if ($Action.OverrideDefaultArgs) {
        $arguments = $PlayniteApi.ExpandGameVariables($Game, $Action.Arguments, $emulatorDir)
    }

    if ([string]::IsNullOrWhiteSpace($exe)) { return $null }

    return @{
        Exe        = $exe
        Arguments  = if ($arguments) { $arguments } else { '' }
        WorkingDir = $workDir
    }
}

function Resolve-GameLaunch
{
    <#
        Turn a Playnite game + action into the Exe / Arguments / StartDir that
        Steam needs. Returns $null when it cannot be done.
    #>
    param($Game, $Action)

    switch ($Action.Type) {

        ([Playnite.SDK.Models.GameActionType]::Emulator) {
            $launch = Resolve-EmulatorLaunch $Game $Action
            if (-not $launch) { return $null }
        }

        ([Playnite.SDK.Models.GameActionType]::File) {
            $expanded = $PlayniteApi.ExpandGameVariables($Game, $Action)
            $launch = @{
                Exe        = $expanded.Path
                Arguments  = if ($expanded.Arguments) { $expanded.Arguments } else { '' }
                WorkingDir = $expanded.WorkingDir
            }
        }

        ([Playnite.SDK.Models.GameActionType]::URL) {
            # Steam will still launch it, but cannot inject the overlay.
            # Complete-LaunchSpec rejects a steam://rungameid target.
            $expanded = $PlayniteApi.ExpandGameVariables($Game, $Action)
            $launch = @{
                Exe        = $expanded.Path
                Arguments  = ''
                WorkingDir = ''
                IsUrl      = $true
            }
        }

        default {
            # Script actions have no command line to hand to Steam.
            return $null
        }
    }

    return Complete-LaunchSpec $Game $launch
}

function Complete-LaunchSpec
{
    <#
        Turn a raw Exe/Arguments/WorkingDir triple into the final shape Steam
        wants, filling in a working directory and rooting the executable.
        Shared by the stored-action and library-plugin resolution paths.
    #>
    param($Game, $Launch)

    if (-not $Launch) { return $null }
    if ([string]::IsNullOrWhiteSpace($Launch.Exe)) { return $null }

    if ($Launch.IsUrl) {
        if ($Launch.Exe.StartsWith($script:RunGameIdPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $__logger.Error("Non-Steam: refusing to use a steam://rungameid URL as the launch target for $($Game.Name)")
            return $null
        }
        return @{
            Exe       = $Launch.Exe
            Arguments = ''
            StartDir  = ''
            IsUrl     = $true
        }
    }

    $exe     = $Launch.Exe
    $workDir = $Launch.WorkingDir

    if ([string]::IsNullOrWhiteSpace($workDir)) {
        # Only safe for a rooted path; a bare relative exe would otherwise
        # resolve against Playnite's own process directory.
        if ([System.IO.Path]::IsPathRooted($exe)) {
            try { $workDir = [System.IO.FileInfo]::new($exe).Directory.FullName } catch { $workDir = '' }
        } else {
            $__logger.Error("Non-Steam: relative launch path with no working directory for $($Game.Name): $exe")
            return $null
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($workDir)) {
        try { $exe = [System.IO.Path]::Combine($workDir, $exe) } catch { }
    }

    return @{
        Exe       = $exe
        Arguments = $Launch.Arguments
        StartDir  = $workDir
        IsUrl     = $false
    }
}


###############################################################################
# SteamGridDB
#
# Used only as a fallback, for games Playnite has no cover for. Needs a free
# API key from https://www.steamgriddb.com/profile/preferences/api, entered via
# "Extensions" -> "Non-Steam Shortcuts" -> "Set SteamGridDB API key...".
# Without a key nothing here runs and the game simply keeps Steam's plain tile.
###############################################################################

$script:SgdbApiBase   = 'https://www.steamgriddb.com/api/v2'
$script:SgdbKeyLoaded = $false
$script:SgdbKey       = $null
$script:SgdbGameIds   = $null   # name -> game id, cached per run

# The key is stored with DPAPI, so the file is tied to this Windows account on
# this machine and is useless if copied elsewhere. It is not a vault: anything
# already running as you can simply ask DPAPI to decrypt it too. The point is
# that the key is not sitting in a text file to be read over your shoulder,
# synced, backed up or committed by accident.
$script:SgdbEntropy = [System.Text.Encoding]::UTF8.GetBytes('NonSteamShortcuts.SteamGridDB.v1')

function Get-SteamGridDbKeyPath
{
    Restore-LegacyExtensionData
    if (-not (Test-Path -LiteralPath $CurrentExtensionDataPath -PathType Container)) {
        New-Item -ItemType Directory -Path $CurrentExtensionDataPath -Force | Out-Null
    }
    return (Join-Path $CurrentExtensionDataPath 'steamgriddb_api_key.dat')
}

function Get-SteamGridDbLegacyKeyPath
{
    # Plaintext file written by earlier versions, migrated on first read.
    return (Join-Path $CurrentExtensionDataPath 'steamgriddb_api_key.txt')
}

function Protect-SteamGridDbKey
{
    param([string]$Key)

    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $bytes     = [System.Text.Encoding]::UTF8.GetBytes($Key)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $script:SgdbEntropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($protected)
}

function Unprotect-SteamGridDbKey
{
    param([string]$Encoded)

    try {
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            [Convert]::FromBase64String($Encoded), $script:SgdbEntropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        # Wrong user, wrong machine, or a corrupted file.
        $__logger.Warn("Non-Steam: the stored SteamGridDB key could not be decrypted: $($_.Exception.Message)")
        return $null
    }
}

function Save-SteamGridDbApiKey
{
    param([string]$Key)

    Set-Content -LiteralPath (Get-SteamGridDbKeyPath) -Value (Protect-SteamGridDbKey $Key) -Encoding UTF8
    $script:SgdbKey = $Key
    $script:SgdbKeyLoaded = $true
}

function Remove-SteamGridDbApiKey
{
    foreach ($path in @((Get-SteamGridDbKeyPath), (Get-SteamGridDbLegacyKeyPath))) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    $script:SgdbKey = $null
    $script:SgdbKeyLoaded = $true
}

function Get-SteamGridDbApiKey
{
    if ($script:SgdbKeyLoaded) { return $script:SgdbKey }
    $script:SgdbKeyLoaded = $true

    $path = Get-SteamGridDbKeyPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $encoded = (Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)
        if ($encoded) { $encoded = $encoded.Trim() }
        if (-not [string]::IsNullOrWhiteSpace($encoded)) {
            $script:SgdbKey = Unprotect-SteamGridDbKey $encoded
        }
        # Deliberately no early return: a plaintext key from before encryption
        # has to be cleared away even once an encrypted one exists. The old
        # code only looked when the encrypted file was missing, so a delete
        # that failed the first time - a lock, a read-only flag, a restored
        # backup - left the key readable on disk for good, which is the one
        # thing the encryption is there to prevent.
    }

    Clear-SteamGridDbLegacyKey
    return $script:SgdbKey
}

function Clear-SteamGridDbLegacyKey
{
    <#
        Take over a plaintext key written by an earlier version, then delete
        it. Runs on every load, not just the first, because the delete can
        fail and a key left in the clear is worth retrying.
    #>
    $legacy = Get-SteamGridDbLegacyKeyPath
    if (-not (Test-Path -LiteralPath $legacy -PathType Leaf)) { return }

    $key = (Get-Content -LiteralPath $legacy -Raw -ErrorAction SilentlyContinue)
    if ($key) { $key = $key.Trim() }

    # Only adopt it if there is nothing encrypted yet; otherwise the encrypted
    # one wins and this file is simply stale.
    if (-not [string]::IsNullOrWhiteSpace($key) -and [string]::IsNullOrWhiteSpace($script:SgdbKey)) {
        Save-SteamGridDbApiKey $key
        $__logger.Info('Non-Steam: migrated the SteamGridDB key to encrypted storage')
    }

    try {
        # Overwrite before unlinking, so the key is not left recoverable in the
        # file's old blocks.
        [System.IO.File]::WriteAllText($legacy, (' ' * 64))
        Remove-Item -LiteralPath $legacy -Force -ErrorAction Stop
        $__logger.Info('Non-Steam: removed the old plaintext SteamGridDB key file')
    } catch {
        $__logger.Warn("Non-Steam: a plaintext SteamGridDB key is still on disk at $legacy and could not be removed: $($_.Exception.Message)")
    }
}

function Set-SteamGridDbApiKey
{
    param($scriptMainMenuItemActionArgs)

    $existing = Get-SteamGridDbApiKey
    if ($null -eq $existing) { $existing = '' }

    $answer = $PlayniteApi.Dialogs.SelectString(
        "Paste your SteamGridDB API key." + [Environment]::NewLine + [Environment]::NewLine +
        "Get one free at https://www.steamgriddb.com/profile/preferences/api" + [Environment]::NewLine +
        "Leave it empty to turn the SteamGridDB fallback off.",
        'Non-Steam Shortcuts',
        $existing)

    if (-not $answer.Result) { return }

    $key = "$($answer.SelectedString)".Trim()

    if ([string]::IsNullOrWhiteSpace($key)) {
        Remove-SteamGridDbApiKey
        [void]$PlayniteApi.Dialogs.ShowMessage('SteamGridDB key cleared. Artwork will only come from Playnite.', 'Non-Steam Shortcuts')
        return
    }

    # Kept only once it is known to work: a rejected key left in place made
    # every later run fail silently, and the summary then blamed a missing key.
    $previous = Get-SteamGridDbApiKey
    Save-SteamGridDbApiKey $key

    # Prove the key works now rather than failing silently mid-run. It is one
    # network round trip, which is long enough to look like a freeze between
    # the two dialogs, so say what is happening.
    $checking = New-ProgressWindow -Headline 'Checking the SteamGridDB key' -Maximum 0
    try {
        if ($checking) {
            $checking.HideCancel()
            $checking.Say('Asking SteamGridDB whether it accepts the key...')
        }
        $test = Invoke-SteamGridDbApi "search/autocomplete/$([uri]::EscapeDataString('portal'))" $key
    }
    finally {
        Close-ProgressWindow $checking
    }
    if ($null -eq $test) {
        # Put back whatever was there before rather than leaving a key that is
        # known not to work.
        if ([string]::IsNullOrWhiteSpace($previous)) {
            Remove-SteamGridDbApiKey
        } else {
            Save-SteamGridDbApiKey $previous
        }
        [void]$PlayniteApi.Dialogs.ShowErrorMessage(
            'SteamGridDB did not accept that key, so it has not been kept. Check it and try again.',
            'Non-Steam Shortcuts')
    } else {
        [void]$PlayniteApi.Dialogs.ShowMessage(
            'SteamGridDB key saved and working. It is encrypted with your Windows account, so the file is unreadable to other users and on other machines.',
            'Non-Steam Shortcuts')
    }
}

function Invoke-SteamGridDbApi
{
    <#
        Returns the "data" payload, or $null on any failure. Artwork is a
        nice-to-have, so nothing in here is allowed to break a run.
    #>
    param([string]$Path, [string]$Key)

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch { }

    # A mass run makes hundreds of requests, so back off and retry on 429 rather
    # than reporting a rate-limited game as having no artwork.
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $response = Invoke-RestMethod -Uri "$script:SgdbApiBase/$Path" `
                                          -Headers @{ Authorization = "Bearer $Key" } `
                                          -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            if ($response -and $response.success) { return $response.data }
            return $null
        } catch {
            $status = $null
            try { $status = $_.Exception.Response.StatusCode.value__ } catch { }

            if (($status -eq 429 -or $status -ge 500) -and $attempt -lt 4) {
                $wait = [Math]::Pow(2, $attempt)   # 2s, 4s, 8s
                $__logger.Warn("Non-Steam: SteamGridDB returned $status, waiting $wait s then retrying ($attempt of 3)")
                Start-Sleep -Seconds $wait
                continue
            }

            if ($status -eq 401 -or $status -eq 403) {
                # The key is bad. Stop asking for the rest of the run.
                $__logger.Error('Non-Steam: SteamGridDB rejected the API key; skipping it for the rest of this run')
                $script:SgdbKey = $null
                return $null
            }

            $__logger.Warn("Non-Steam: SteamGridDB request failed for '$Path': $($_.Exception.Message)")
            return $null
        }
    }
}

function Find-SteamGridDbGameId
{
    param([string]$Name, [string]$Key)

    if ($null -eq $script:SgdbGameIds) { $script:SgdbGameIds = @{} }
    if ($script:SgdbGameIds.ContainsKey($Name)) { return $script:SgdbGameIds[$Name] }

    $id = $null
    $results = Invoke-SteamGridDbApi "search/autocomplete/$([uri]::EscapeDataString($Name))" $Key
    if ($results) {
        $first = @($results)[0]
        if ($first -and $first.id) {
            $id = $first.id
            $__logger.Info("Non-Steam: SteamGridDB matched '$Name' to '$($first.name)' (id $id)")
        }
    }
    if ($null -eq $id) {
        $__logger.Info("Non-Steam: SteamGridDB has no match for '$Name'")
    }
    $script:SgdbGameIds[$Name] = $id
    return $id
}

function Save-SteamGridDbAsset
{
    <#
        Fetch one artwork kind and write it next to the other grid files.
        Returns $true if a file was written.
    #>
    param(
        [string]$GridDir,
        [long]$AppId,
        [int]$GameId,
        [string]$Kind,      # grids | heroes | logos
        [string]$Suffix,    # p | _hero | _logo
        [string]$Query,
        [string]$Key
    )

    $path = "$Kind/game/$GameId"
    if ($Query) { $path += "?$Query" }

    $assets = Invoke-SteamGridDbApi $path $Key
    if (-not $assets) { return $false }

    $asset = @($assets)[0]
    if (-not $asset -or [string]::IsNullOrWhiteSpace($asset.url)) { return $false }

    $extension = [System.IO.Path]::GetExtension(($asset.url -split '\?')[0])
    if ([string]::IsNullOrWhiteSpace($extension)) { $extension = '.png' }

    # Download beside the target first. Replacing the existing artwork before
    # knowing the download works would destroy good art whenever the network
    # drops mid-run, which is exactly when -Overwrite is most likely in use.
    # The temporary name deliberately does not start with the app id, so the
    # cleanup filter below cannot match it.
    $destination = Join-Path $GridDir "$AppId$Suffix$extension"
    $temporary   = Join-Path $GridDir ("nss_download_" + [guid]::NewGuid().ToString('N') + $extension)

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $asset.url -OutFile $temporary -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
    } catch {
        $__logger.Warn("Non-Steam: could not download $Kind artwork for app $AppId : $($_.Exception.Message)")
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        return $false
    }

    try {
        # Only now: clear other extensions for this slot so a stale file cannot
        # win, then move the finished download into place.
        foreach ($old in @(Get-ChildItem -LiteralPath $GridDir -Filter "$AppId$Suffix.*" -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
        }
        Move-Item -LiteralPath $temporary -Destination $destination -Force -ErrorAction Stop
        $__logger.Info("Non-Steam: SteamGridDB supplied $Kind artwork for app $AppId")
        return $true
    } catch {
        $__logger.Warn("Non-Steam: could not save $Kind artwork for app $AppId : $($_.Exception.Message)")
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Copy-SteamGridDbArt
{
    <#
        Fallback artwork for a game Playnite has no cover for. Only fills slots
        that are still empty unless -Overwrite is given. Returns how many files
        were written.
    #>
    param([string]$GridDir, [long]$AppId, [string]$Name, [switch]$Overwrite, $Progress)

    $key = Get-SteamGridDbApiKey
    if ([string]::IsNullOrWhiteSpace($key)) { return 0 }

    # Each of these is a separate network round trip taking a second or three,
    # so the caller's window is told about every one of them.
    if ($Progress) { $Progress.Say("$Name - searching SteamGridDB") }
    $gameId = Find-SteamGridDbGameId $Name $key
    if (-not $gameId) { return 0 }

    $wanted = @(
        @{ Kind = 'grids';  Suffix = 'p';     Query = 'dimensions=600x900'; Label = 'library capsule' },
        @{ Kind = 'heroes'; Suffix = '_hero'; Query = '';                   Label = 'hero banner' },
        @{ Kind = 'logos';  Suffix = '_logo'; Query = '';                   Label = 'logo' }
    )

    $written = 0
    foreach ($slot in $wanted) {
        $existing = @(Get-ChildItem -LiteralPath $GridDir -Filter "$AppId$($slot.Suffix).*" -File -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0 -and -not $Overwrite) { continue }

        if ($Progress) { $Progress.Say("$Name - downloading $($slot.Label) from SteamGridDB") }
        if (Save-SteamGridDbAsset $GridDir $AppId $gameId $slot.Kind $slot.Suffix $slot.Query $key) {
            $written++
        }
    }
    return $written
}

###############################################################################
# Tags and grid artwork
###############################################################################

function Merge-SteamTags
{
    <#
        Steam stores a non-Steam game's collection membership in the shortcut's
        tags map, so Playnite categories are merged in rather than assigned.
        Overwriting would drop the user's Steam collections, and a game with no
        categories would silently clear them.
    #>
    param($Shortcut, $Game)

    $tags = $null
    if ($Shortcut) { $tags = $Shortcut['tags'] }
    if (-not ($tags -is [System.Collections.IDictionary])) { $tags = [ordered]@{} }

    if (-not $Game.Categories) { return ,$tags }

    $have = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($v in $tags.Values) { [void]$have.Add([string]$v) }

    # Continue the numeric keys Steam uses rather than reusing an index.
    $next = 0
    foreach ($k in @($tags.Keys)) {
        $n = 0
        if ([int]::TryParse([string]$k, [ref]$n) -and $n -ge $next) { $next = $n + 1 }
    }

    foreach ($category in $Game.Categories) {
        if ($have.Add($category.Name)) {
            $tags[$next.ToString()] = $category.Name
            $next++
        }
    }
    return ,$tags
}

function Copy-SteamGridArt
{
    <#
        Steam reads non-Steam shortcut artwork from userdata\<id>\config\grid,
        named after the shortcut's 32 bit app id. Playnite covers are usually
        600x900 portraits (what SteamGridDB serves), which is exactly the shape
        Steam wants for the library capsule.
    #>
    param([string]$GridDir, [long]$AppId, $Game, [switch]$Overwrite)

    $copied = 0
    foreach ($property in $script:GridArtMap.Keys) {
        $suffix       = $script:GridArtMap[$property]
        $relativePath = $Game.$property
        if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }

        # Steam accepts several extensions per slot, so check for any of them.
        $existingArt = @(Get-ChildItem -LiteralPath $GridDir -Filter "$AppId$suffix.*" -File -ErrorAction SilentlyContinue)
        if ($existingArt.Count -gt 0 -and -not $Overwrite) {
            # Leave artwork that is already there alone (it may have come from
            # SteamGridDB, EmuDeck, or a previous manual choice). Use the
            # "replace artwork" menu entry to overwrite it.
            $__logger.Info("Non-Steam: keeping existing $suffix artwork for $($Game.Name)")
            continue
        }

        try {
            $source = $PlayniteApi.Database.GetFullFilePath($relativePath)
        } catch {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source -PathType Leaf)) {
            continue
        }

        $extension = [System.IO.Path]::GetExtension($source)
        if ([string]::IsNullOrWhiteSpace($extension)) { $extension = '.png' }

        # Clear other extensions for this slot so a stale .jpg does not win over
        # a new .png.
        foreach ($old in $existingArt) {
            if ($old.Extension -ne $extension) {
                Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
            }
        }

        $destination = Join-Path $GridDir "$AppId$suffix$extension"
        try {
            Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
            $copied++
        } catch {
            $__logger.Warn("Non-Steam: could not copy $property for $($Game.Name): $($_.Exception.Message)")
        }
    }
    return $copied
}


###############################################################################
# Ownership and sync
#
# A shortcut is "ours" if either of two things says so:
#
#   1. A record we keep ourselves, in owned_shortcuts.json under the extension's
#      data folder, mapping Steam app id -> Playnite game id. Steam cannot touch
#      this, so it is the authority.
#
#   2. A stamp in the shortcut's devkitgameid field, "playnite:<game id>". That
#      field is part of Steam's own shortcut schema and is meaningless for an
#      ordinary non-Steam shortcut, so it is a reasonable place to put it, and
#      it travels with the entry if the record is ever lost.
#
# Two signals rather than one because it is NOT established that Steam preserves
# a value written to devkitgameid when it rewrites shortcuts.vdf. If it strips
# it, the record still identifies our entries; if the record is lost, the stamp
# still does. Either one alone is enough to claim an entry.
#
# Nothing matched by neither is ever touched. Shortcuts added by hand, or by
# another tool, are not ours to remove.
###############################################################################

$script:LegacyDataFolder = 'bburky-playnite-non-steam-shortcuts'
$script:DataMigrationDone = $false

function Restore-LegacyExtensionData
{
    <#
        This started life under the upstream extension id, and Playnite names
        the data folder after that id. Changing it to our own would otherwise
        orphan the saved SteamGridDB key, the chosen Steam profile and the
        record of which Steam shortcuts belong to us - the last of which is
        what stops a cleanup deleting somebody else's shortcuts.

        Copies rather than moves, so downgrading keeps working, and never
        overwrites a file the new location already has.
    #>
    if ($script:DataMigrationDone) { return }
    $script:DataMigrationDone = $true

    try {
        $parent = Split-Path -Parent $CurrentExtensionDataPath
        if ([string]::IsNullOrWhiteSpace($parent)) { return }
        $legacy = Join-PathSafe $parent $script:LegacyDataFolder
        if (-not $legacy -or -not (Test-Path -LiteralPath $legacy -PathType Container)) { return }
        if ([System.IO.Path]::GetFullPath($legacy) -eq [System.IO.Path]::GetFullPath($CurrentExtensionDataPath)) { return }

        if (-not (Test-Path -LiteralPath $CurrentExtensionDataPath -PathType Container)) {
            New-Item -ItemType Directory -Path $CurrentExtensionDataPath -Force | Out-Null
        }

        foreach ($name in @('owned_shortcuts.json', 'steam_userdata_path.txt', 'steamgriddb_api_key.dat')) {
            $from = Join-PathSafe $legacy $name
            $to   = Join-PathSafe $CurrentExtensionDataPath $name
            if (-not $from -or -not $to) { continue }
            if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { continue }
            if (Test-Path -LiteralPath $to -PathType Leaf) { continue }
            try {
                Copy-Item -LiteralPath $from -Destination $to -ErrorAction Stop
                $__logger.Info("Non-Steam: carried $name over from the previous extension id")
            } catch {
                $__logger.Warn("Non-Steam: could not carry $name over: $($_.Exception.Message)")
            }
        }
    } catch {
        $__logger.Warn("Non-Steam: could not check for earlier extension data: $($_.Exception.Message)")
    }
}

function Get-OwnedShortcutsPath
{
    if (-not (Test-Path -LiteralPath $CurrentExtensionDataPath -PathType Container)) {
        New-Item -ItemType Directory -Path $CurrentExtensionDataPath -Force | Out-Null
    }
    return (Join-Path $CurrentExtensionDataPath 'owned_shortcuts.json')
}

function Get-OwnedShortcuts
{
    # appid (as a string) -> Playnite game id
    Restore-LegacyExtensionData
    $path = Get-OwnedShortcutsPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $owned = @{}
        foreach ($property in (ConvertFrom-Json $raw).PSObject.Properties) {
            $owned[$property.Name] = [string]$property.Value
        }
        return $owned
    } catch {
        $__logger.Warn("Non-Steam: could not read the owned shortcut record: $($_.Exception.Message)")
        return @{}
    }
}

function Save-OwnedShortcuts
{
    param($Owned)

    try {
        ($Owned | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath (Get-OwnedShortcutsPath) -Encoding UTF8
    } catch {
        $__logger.Warn("Non-Steam: could not save the owned shortcut record: $($_.Exception.Message)")
    }
}

function Get-ShortcutOwnerId
{
    <#
        The Playnite game id behind a shortcut, from our own record or from the
        devkitgameid stamp, or $null if the shortcut is not ours.
    #>
    param($Shortcut, $Owned)

    if (-not $Shortcut) { return $null }

    # Our own record first: Steam cannot have interfered with it.
    if ($Owned -and $Shortcut.Contains('appid')) {
        $appId = ConvertTo-UnsignedAppId ([long]$Shortcut['appid'])
        if ($Owned.ContainsKey("$appId")) { return $Owned["$appId"] }
    }

    # Then the stamp, which may or may not have survived Steam.
    if ($Shortcut.Contains('devkitgameid')) {
        $value = [string]$Shortcut['devkitgameid']
        if (-not [string]::IsNullOrWhiteSpace($value) -and
            $value.StartsWith($script:OwnerPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $id = $value.Substring($script:OwnerPrefix.Length).Trim()
            if (-not [string]::IsNullOrWhiteSpace($id)) { return $id }
        }
    }
    return $null
}

function Test-PlayniteGameExists
{
    param([string]$GameId)

    try {
        $guid = [Guid]::Parse($GameId)
    } catch {
        return $false
    }
    try {
        return ($null -ne $PlayniteApi.Database.Games.Get($guid))
    } catch {
        # If the database cannot answer, assume the game is there. Deleting a
        # shortcut is not worth a guess.
        $__logger.Warn("Non-Steam: could not look up game $GameId : $($_.Exception.Message)")
        return $true
    }
}

function Remove-SteamGridArt
{
    <#
        Delete the grid files belonging to one app id. Matched precisely rather
        than with "<appid>*", which would also hit an app id that merely starts
        with the same digits.
    #>
    param([string]$GridDir, [long]$AppId)

    if (-not (Test-Path -LiteralPath $GridDir -PathType Container)) { return 0 }

    $pattern = '^' + [regex]::Escape("$AppId") + '(p|_[A-Za-z]+)?\.[A-Za-z0-9]+$'
    $removed = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $GridDir -File -ErrorAction SilentlyContinue)) {
        if ($file.Name -match $pattern) {
            try {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $removed++
            } catch {
                $__logger.Warn("Non-Steam: could not delete $($file.Name): $($_.Exception.Message)")
            }
        }
    }
    return $removed
}

function Sync-NonSteamShortcuts
{
    <#
        Remove shortcuts this extension created for games that are no longer in
        the Playnite library.
    #>
    param($scriptMainMenuItemActionArgs)

    $steamUserdata = Get-SelectedSteamUserdataFolder
    if (-not (Test-SteamUserdataDir $steamUserdata)) { return }

    $shortcutsVdf = Join-Path $steamUserdata 'config\shortcuts.vdf'
    $gridDir      = Join-Path $steamUserdata 'config\grid'

    if (-not (Test-Path -LiteralPath $shortcutsVdf -PathType Leaf)) {
        [void]$PlayniteApi.Dialogs.ShowMessage('There is no shortcuts.vdf to sync yet.', 'Non-Steam Shortcuts')
        return
    }

    try {
        $entries = Read-ShortcutsVdf $shortcutsVdf
    } catch {
        [void]$PlayniteApi.Dialogs.ShowErrorMessage($_.Exception.ToString(), 'Error loading shortcuts.vdf')
        return
    }

    $owned   = Get-OwnedShortcuts
    $keep    = New-Object 'System.Collections.Generic.List[object]'
    $stale   = New-Object 'System.Collections.Generic.List[object]'
    $ourEntries = 0
    $foreign    = 0

    foreach ($entry in $entries) {
        $ownerId = Get-ShortcutOwnerId $entry $owned
        if ($null -eq $ownerId) {
            # Not ours. Keep it, always.
            $foreign++
            $keep.Add($entry)
            continue
        }
        $ourEntries++
        if (Test-PlayniteGameExists $ownerId) {
            $keep.Add($entry)
        } else {
            $__logger.Info("Non-Steam: '$($entry['appname'])' is no longer in Playnite")
            $stale.Add($entry)
        }
    }

    $nl = [Environment]::NewLine

    if ($stale.Count -eq 0) {
        $message  = 'Nothing to clean up.' + $nl + $nl
        $message += "Checked $ourEntries shortcut(s) created by this extension; every one still has a game in Playnite."
        if ($foreign -gt 0) {
            $message += $nl + $nl + "$foreign other shortcut(s) in Steam were left alone, because this extension did not create them."
        }
        if ($ourEntries -eq 0) {
            $message += $nl + $nl + 'Shortcuts created before this version are not stamped as ours yet. Run '
            $message += '"Create non-Steam shortcuts" over those games once and they will be picked up from then on.'
        }
        [void]$PlayniteApi.Dialogs.ShowMessage($message, 'Non-Steam Shortcuts')
        return
    }

    $names = @($stale | ForEach-Object { $_['appname'] })
    $shown = $names
    if ($shown.Count -gt 15) { $shown = $shown[0..14] + "[... and $($names.Count - 15) more]" }

    $message  = "$($stale.Count) Steam shortcut(s) no longer have a game in Playnite." + $nl + $nl
    $message += 'Remove them from Steam, along with their artwork?' + $nl + $nl
    $message += ($shown -join $nl)
    if ($foreign -gt 0) {
        $message += $nl + $nl + "$foreign shortcut(s) not created by this extension will be left alone."
    }

    $answer = $PlayniteApi.Dialogs.ShowMessage(
        $message, 'Non-Steam Shortcuts',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning)
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

    if (Get-Process -Name 'steam' -ErrorAction SilentlyContinue) {
        $running = $PlayniteApi.Dialogs.ShowMessage(
            'Steam is running and will rewrite shortcuts.vdf when it exits, undoing this. Continue anyway?',
            'Non-Steam Shortcuts',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning)
        if ($running -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }

    $backupPath = $null
    try {
        $backupPath = Backup-ShortcutsVdf $shortcutsVdf
    } catch {
        [void]$PlayniteApi.Dialogs.ShowErrorMessage($_.Exception.ToString(), 'Error backing up shortcuts.vdf')
        return
    }

    # Removing artwork rereads the grid folder per shortcut, so a big cleanup
    # is slow enough to need telling about.
    $progressWindow = New-ProgressWindow -Headline 'Removing shortcuts' -Maximum $stale.Count
    $artRemoved = 0
    $dropped    = New-Object 'System.Collections.Generic.List[object]'
    try {
        $removed = 0
        foreach ($entry in $stale) {
            # Cancelling has to mean something here: the artwork is already
            # gone for everything processed so far, so the rest is kept
            # intact rather than deleted anyway.
            if ($progressWindow -and $progressWindow.Cancelled) {
                $__logger.Info('Non-Steam: cleanup cancelled by the user')
                break
            }
            if ($progressWindow) {
                $progressWindow.Step(
                    "Removing shortcuts   ($($removed + 1) of $($stale.Count))",
                    "$($entry['appname']) - deleting its artwork",
                    $removed)
            }
            $removed++
            if ($entry.Contains('appid')) {
                $appId = ConvertTo-UnsignedAppId ([long]$entry['appid'])
                $artRemoved += Remove-SteamGridArt $gridDir $appId
            }
            $dropped.Add($entry)
        }
    }
    finally {
        Close-ProgressWindow $progressWindow
    }

    # Whatever was not reached stays in the file.
    $cancelledEarly = $dropped.Count -lt $stale.Count
    if ($cancelledEarly) {
        foreach ($entry in $stale) {
            if (-not $dropped.Contains($entry)) { $keep.Add($entry) }
        }
    }
    $stale = $dropped

    try {
        Write-ShortcutsVdf $shortcutsVdf $keep
    } catch {
        [void]$PlayniteApi.Dialogs.ShowErrorMessage($_.Exception.ToString(), 'Error saving shortcuts.vdf')
        if ($backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            try {
                Copy-Item -LiteralPath $backupPath -Destination $shortcutsVdf -Force -ErrorAction Stop
                [void]$PlayniteApi.Dialogs.ShowMessage(
                    'Successfully restored the shortcuts.vdf backup. Artwork for the shortcuts being removed has already been deleted, so run this again once the problem is fixed.',
                    'Non-Steam Shortcuts')
            } catch {
                [void]$PlayniteApi.Dialogs.ShowErrorMessage($_.Exception.ToString(), 'Error restoring shortcuts.vdf backup')
            }
        }
        return
    }

    # Drop the removed entries from our record too.
    foreach ($entry in $stale) {
        if ($entry.Contains('appid')) {
            $appId = ConvertTo-UnsignedAppId ([long]$entry['appid'])
            if ($owned.ContainsKey("$appId")) { $owned.Remove("$appId") }
        }
    }
    Save-OwnedShortcuts $owned

    $result  = "Removed $($stale.Count) shortcut(s) and $artRemoved artwork file(s)." + $nl + $nl
    if ($cancelledEarly) {
        $result = "Cancelled." + $nl + $nl + $result
    }
    $result += "$($keep.Count) shortcut(s) left in Steam."
    $result += $nl + $nl + 'Relaunch Steam to see the change.'
    [void]$PlayniteApi.Dialogs.ShowMessage($result, 'Non-Steam Shortcuts')
}

function Confirm-ReplaceAllShortcuts
{
    <#
        The destructive path, so it says plainly what will be lost and defaults
        to cancelling.
    #>
    param([string]$ShortcutsVdf, [int]$SelectedCount)

    $existing = 0
    try {
        $existing = (Read-ShortcutsVdf $ShortcutsVdf).Count
    } catch {
        $existing = 0
    }

    $nl = [Environment]::NewLine
    $message  = 'This will completely rewrite and overwrite your existing non-Steam shortcuts '
    $message += 'for your Steam account.' + $nl + $nl
    $message += "Steam currently has $existing non-Steam shortcut(s). All of them will be removed "
    $message += "and replaced with the $SelectedCount game(s) you have selected in Playnite." + $nl + $nl
    $message += 'If you have added shortcuts by hand, or with another tool such as EmuDeck or '
    $message += 'Steam ROM Manager, or changed any launch options or artwork outside Playnite, '
    $message += 'those changes will be lost.' + $nl + $nl
    $message += 'A timestamped backup of shortcuts.vdf has already been written next to it, so '
    $message += 'this can be undone by restoring that file.' + $nl + $nl
    $message += 'Continue?'

    $no  = New-Object Playnite.SDK.MessageBoxOption('No, leave my shortcuts alone', $true, $true)
    $yes = New-Object Playnite.SDK.MessageBoxOption('Yes, replace everything', $false, $false)
    $options = New-Object 'System.Collections.Generic.List[Playnite.SDK.MessageBoxOption]'
    $options.Add($no)
    $options.Add($yes)

    $chosen = $PlayniteApi.Dialogs.ShowMessage(
        $message, 'Non-Steam Shortcuts - replace everything',
        [System.Windows.MessageBoxImage]::Warning, $options)

    if ($null -eq $chosen -or $chosen.IsCancel -or $chosen.Title -ne $yes.Title) {
        $__logger.Info('Non-Steam: replace-everything cancelled')
        return $false
    }
    return $true
}

###############################################################################
# Main entry point
###############################################################################

function Add-NonSteamShortcuts
{
    param($scriptGameMenuItemActionArgs)

    Invoke-NonSteamShortcuts $scriptGameMenuItemActionArgs
}

function Add-NonSteamShortcutsFromPlaynite
{
    <#
        Push what Playnite has over whatever Steam is showing, and do not ask
        SteamGridDB for anything. This is the answer to a bad SteamGridDB
        match: fix the game's artwork in Playnite, run this, and Steam gets
        exactly that.
    #>
    param($scriptGameMenuItemActionArgs)

    Invoke-NonSteamShortcuts $scriptGameMenuItemActionArgs -ReplaceArt -PlayniteArtOnly
}

function Reset-NonSteamShortcuts
{
    <#
        Throw away every non-Steam shortcut and rebuild the list from the games
        selected in Playnite.

        This is the blunt alternative to the sync: it needs no way of telling
        which shortcuts are ours, because it keeps none of them. Select the
        games you want in Steam, confirm, and Steam ends up with exactly those.
    #>
    param($scriptGameMenuItemActionArgs)

    Invoke-NonSteamShortcuts $scriptGameMenuItemActionArgs -ReplaceArt -ReplaceAll
}

function Reset-NonSteamShortcutsFromPlaynite
{
    <#
        The rebuild, with artwork taken only from Playnite. Same reasoning as
        Add-NonSteamShortcutsFromPlaynite.
    #>
    param($scriptGameMenuItemActionArgs)

    Invoke-NonSteamShortcuts $scriptGameMenuItemActionArgs -ReplaceArt -ReplaceAll -PlayniteArtOnly
}

###############################################################################
# Progress window
#
# Playnite's own ActivateGlobalProgress cannot be used from a PowerShell
# extension. It takes Action<T> and Func<T,Task> overloads that a scriptblock
# matches equally well, so the call is rejected as ambiguous; casting past that
# only reaches the real problem, which is that Playnite runs the action on a
# worker thread. A scriptblock has no runspace there, and lending it the
# calling runspace deadlocks, because that runspace is still busy running the
# menu action that opened the dialog.
#
# So the window below lives on the UI thread with the rest of this script, and
# the message queue is pumped by hand between games to let it repaint. The
# whole thing is C#: handing PowerShell scriptblocks to WPF as event handlers
# runs into the same runspace trouble.
###############################################################################

$script:ProgressSource = @'
using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

public class NonSteamShortcutsProgress
{
    // Playnite's main window is disabled while a run is in progress, and more
    // than one window can be open at once if anything re-enters. Counting is
    // used rather than each window remembering the owner's previous state,
    // because the second window would remember "disabled" and restore that.
    private static int _disableDepth;

    private Window _win;
    private Window _owner;
    private TextBlock _headline;
    private TextBlock _detail;
    private ProgressBar _bar;
    private Button _cancel;
    private bool _disabledOwner;

    public bool Cancelled;
    public bool IsOpen { get { return _win != null; } }

    public void Start(string headline, double max, Window owner)
    {
        try {
            Build(headline, max, owner);
        } catch {
            // Never leave Playnite disabled or a half-built window on screen
            // because of a failure in here. The caller only learns that it has
            // no progress window, which every caller already copes with.
            Finish();
            throw;
        }
    }

    private void Build(string headline, double max, Window owner)
    {
        _owner = owner;

        _headline = new TextBlock {
            Text = headline,
            FontSize = 15,
            TextWrapping = TextWrapping.Wrap
        };
        _bar = new ProgressBar {
            Height = 6,
            Minimum = 0,
            Maximum = max > 0 ? max : 1,
            IsIndeterminate = max <= 0,
            Margin = new Thickness(0, 14, 0, 0)
        };
        // Two lines' worth of room, so the window does not jump about as the
        // running commentary changes length.
        _detail = new TextBlock {
            FontSize = 12,
            Opacity = 0.75,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 32,
            Margin = new Thickness(0, 10, 0, 0)
        };
        _cancel = new Button {
            Content = "Cancel",
            Width = 90,
            Padding = new Thickness(6, 3, 6, 3),
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 12, 0, 0)
        };
        _cancel.Click += OnCancel;

        var panel = new StackPanel { Margin = new Thickness(22, 20, 22, 18) };
        panel.Children.Add(_headline);
        panel.Children.Add(_bar);
        panel.Children.Add(_detail);
        panel.Children.Add(_cancel);

        _win = new Window {
            Title = "Non-Steam Shortcuts",
            Content = panel,
            Width = 540,
            SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize,
            WindowStyle = WindowStyle.ToolWindow,
            ShowInTaskbar = false
        };
        if (owner != null) {
            _win.Owner = owner;
            _win.WindowStartupLocation = WindowStartupLocation.CenterOwner;
        } else {
            _win.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        }
        _win.Closing += OnClosing;
        _win.Closed  += OnClosed;

        ApplyTheme();
        _win.Show();

        // Keep Playnite itself from taking input while we work, which is what a
        // modal dialog would do. Our own window stays live so Cancel works.
        //
        // This disables the WPF element tree, not the Win32 window: the title
        // bar stays live and Playnite can still be closed from it. That is why
        // the owner's own Closing is watched too, so a run stops instead of
        // carrying on writing while the app tears down.
        if (_owner != null) {
            if (_disableDepth == 0) { _owner.IsEnabled = false; }
            _disableDepth++;
            _disabledOwner = true;
            _owner.Closing += OnOwnerClosing;
            _owner.Closed  += OnOwnerClosed;
        }
        Pump();
    }

    private void OnCancel(object sender, RoutedEventArgs e)
    {
        RequestCancel("Stopping after the game in progress...");
    }

    private void OnClosing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        // Closing the window means the same thing as pressing Cancel. The close
        // is allowed to go ahead, and Finish (via OnClosed) puts Playnite back
        // rather than leaving it disabled behind an empty screen.
        Cancelled = true;
    }

    private void OnClosed(object sender, EventArgs e)
    {
        // However the window went away - our Finish, the user's X, or WPF
        // tearing it down with its owner - stop claiming to be open and give
        // Playnite back.
        _win = null;
        ReleaseOwner();
    }

    private void OnOwnerClosing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        // Playnite is shutting down. Nothing here blocks that; the run just has
        // to know, or it would carry on writing to a database being torn down.
        RequestCancel("Playnite is closing, stopping...");
    }

    private void OnOwnerClosed(object sender, EventArgs e)
    {
        Cancelled = true;
        _win = null;
        ReleaseOwner();
    }

    private void RequestCancel(string message)
    {
        Cancelled = true;
        try {
            if (_cancel != null) { _cancel.IsEnabled = false; }
            if (_headline != null) { _headline.Text = message; }
        } catch { }
    }

    private void ReleaseOwner()
    {
        if (!_disabledOwner) { return; }
        _disabledOwner = false;
        try {
            _disableDepth--;
            if (_disableDepth < 0) { _disableDepth = 0; }
            if (_owner != null) {
                _owner.Closing -= OnOwnerClosing;
                _owner.Closed  -= OnOwnerClosed;
                if (_disableDepth == 0) { _owner.IsEnabled = true; }
            }
        } catch { }
        _owner = null;
    }

    // Playnite themes are just resource dictionaries, so borrow their colours
    // when they are there and fall back to WPF's defaults when they are not.
    private void ApplyTheme()
    {
        Brush bg = FindBrush("WindowBackgourndBrush");   // Playnite's own spelling
        if (bg == null) { bg = FindBrush("WindowBackgroundBrush"); }
        if (bg == null) { bg = FindBrush("ControlBackgroundBrush"); }
        Brush fg = FindBrush("TextBrush");
        if (fg == null) { fg = FindBrush("NormalTextBrush"); }

        if (bg == null) { return; }   // no theme background: leave everything default

        // A theme that names its background but not its text brush would
        // otherwise give black text on a black window, so pick a readable
        // colour rather than applying half a theme.
        if (fg == null) { fg = ContrastingBrush(bg); }

        _win.Background = bg;
        _headline.Foreground = fg;
        _detail.Foreground = fg;
    }

    private Brush ContrastingBrush(Brush background)
    {
        var solid = background as SolidColorBrush;
        if (solid == null) { return Brushes.White; }
        var c = solid.Color;
        // Rec. 601 luma, the usual quick test for "is this dark".
        double luma = (0.299 * c.R + 0.587 * c.G + 0.114 * c.B) / 255.0;
        return luma < 0.5 ? Brushes.White : Brushes.Black;
    }

    private Brush FindBrush(string key)
    {
        try {
            if (Application.Current == null) { return null; }
            return Application.Current.TryFindResource(key) as Brush;
        } catch { return null; }
    }

    /// <summary>Headline plus bar position, for moving on to the next item.</summary>
    public void Step(string headline, string detail, double value)
    {
        if (_win == null) { return; }
        if (headline != null && !Cancelled) { _headline.Text = headline; }
        if (detail != null) { _detail.Text = detail; }
        if (value >= 0) { _bar.Value = value; }
        Pump();
    }

    /// <summary>Just the running commentary, for steps within one item.</summary>
    public void Say(string detail)
    {
        if (_win == null) { return; }
        if (detail != null) { _detail.Text = detail; }
        Pump();
    }

    /// <summary>For work too short to be worth interrupting, where an enabled
    /// Cancel button would just be a button that does nothing.</summary>
    public void HideCancel()
    {
        if (_win == null) { return; }
        _cancel.Visibility = Visibility.Collapsed;
        Pump();
    }

    public void SetMaximum(double max)
    {
        if (_win == null) { return; }
        _bar.IsIndeterminate = max <= 0;
        _bar.Maximum = max > 0 ? max : 1;
        _bar.Value = 0;
        Pump();
    }

    /// <summary>
    /// WPF's DoEvents: drain everything queued above Background priority, which
    /// includes layout, rendering and the Cancel click, then carry on.
    /// </summary>
    public void Pump()
    {
        var win = _win;
        if (win == null) { return; }
        // PushFrame pumps the calling thread's dispatcher while the frame-exit
        // callback is posted to the window's. Off the UI thread those are two
        // different dispatchers and PushFrame would never return, so do not
        // pump at all from anywhere but the thread that owns the window.
        if (!win.Dispatcher.CheckAccess()) { return; }
        try {
            var frame = new DispatcherFrame();
            win.Dispatcher.BeginInvoke(
                DispatcherPriority.Background,
                new DispatcherOperationCallback(f => { ((DispatcherFrame)f).Continue = false; return null; }),
                frame);
            Dispatcher.PushFrame(frame);
        } catch {
            // Dispatcher suspended or shutting down. Losing a repaint is not
            // worth failing the run that is drawing it.
        }
    }

    public void Finish()
    {
        var win = _win;
        _win = null;
        try {
            if (win != null) {
                win.Closing -= OnClosing;
                win.Closed  -= OnClosed;
                win.Close();
            }
        } catch { }
        // Last, and outside that try, because giving Playnite back matters more
        // than closing tidily.
        ReleaseOwner();
    }
}
'@

$script:ProgressTypeState = $null

function Initialize-ProgressWindowType
{
    <#
        Compiling costs a second or so, so it happens on first use rather than
        at module load, where it would show up as Playnite starting slowly.
    #>
    if ($null -ne $script:ProgressTypeState) { return $script:ProgressTypeState }
    $script:ProgressTypeState = $false
    try {
        if (-not ([System.Management.Automation.PSTypeName]'NonSteamShortcutsProgress').Type) {
            Add-Type -TypeDefinition $script:ProgressSource -ReferencedAssemblies @(
                'PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml'
            ) -ErrorAction Stop
        }
        $script:ProgressTypeState = $true
    } catch {
        $__logger.Warn("Non-Steam: progress window unavailable, continuing without it: $($_.Exception.Message)")
    }
    return $script:ProgressTypeState
}

function New-ProgressWindow
{
    <#
        Returns a progress window, or $null if one cannot be shown. Every caller
        has to cope with $null anyway, because this also runs under test with no
        WPF application around it.
    #>
    param([string]$Headline, [int]$Maximum)

    if (-not (Initialize-ProgressWindowType)) { return $null }
    try {
        $owner = $null
        if ([System.Windows.Application]::Current) {
            $owner = [System.Windows.Application]::Current.MainWindow
        }
        $window = New-Object NonSteamShortcutsProgress
        $window.Start($Headline, [double]$Maximum, $owner)
        return $window
    } catch {
        $__logger.Warn("Non-Steam: could not open the progress window: $($_.Exception.Message)")
        return $null
    }
}

function Close-ProgressWindow
{
    param($Window)
    if ($Window) {
        try { $Window.Finish() } catch { }
    }
}

function Invoke-ShortcutBuild
{
    <#
        Walks the selected games and builds their shortcut entries. Pulled out
        of Invoke-NonSteamShortcuts so it can report as it goes: looking a game
        up on SteamGridDB is a network round trip, and a bulk run over a whole
        library spends minutes in here.

        $Progress is a progress window from New-ProgressWindow, or $null to run
        without any UI at all.
    #>
    param($Games, [string]$GridDir, $SteamShortcuts, [switch]$ReplaceArt, [switch]$PlayniteArtOnly, $Progress)

    $cancelled = $false
    $gamesUpdated        = 0
    $gamesNew            = 0
    $artCopied           = 0
    $skippedNoAction     = New-Object 'System.Collections.Generic.List[string]'
    $skippedSteamNative  = New-Object 'System.Collections.Generic.List[string]'
    $skippedUnresolvable = New-Object 'System.Collections.Generic.List[string]'
    $skippedNotInstalled = New-Object 'System.Collections.Generic.List[string]'
    $noOverlayGames      = New-Object 'System.Collections.Generic.List[string]'
    $noArtworkGames      = New-Object 'System.Collections.Generic.List[string]'
    $guessedGames        = New-Object 'System.Collections.Generic.List[string]'
    $skippedDuplicate    = New-Object 'System.Collections.Generic.List[string]'
    $urlGames            = New-Object 'System.Collections.Generic.List[string]'
    $gamesToUpdate       = New-Object 'System.Collections.Generic.List[object]'
    $skippedForeign      = New-Object 'System.Collections.Generic.List[string]'
    $unreadableTargets   = New-Object 'System.Collections.Generic.List[string]'
    $namesThisRun        = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    # Read once: every game consults it, and it is written back by the caller
    # only after shortcuts.vdf has actually been saved.
    $owned = Get-OwnedShortcuts

    $processed = 0
    foreach ($game in $games) {

        if ($Progress) {
            if ($Progress.Cancelled) {
                $__logger.Info('Non-Steam: cancelled by the user')
                $cancelled = $true
                break
            }
            $Progress.Step(
                "Creating non-Steam shortcuts   ($($processed + 1) of $($games.Count))",
                "$($game.Name) - working out how to launch it",
                $processed)
        }
        $processed++

        if ($game.PluginId -eq $script:SteamPluginId) {
            $__logger.Warn("Non-Steam: game is already a Steam game: $($game.Name)")
            $skippedSteamNative.Add($game.Name)
            continue
        }

        # Two selected games sharing a name would collapse onto one shortcut and
        # end up cross-linked to the same rungameid.
        if (-not $namesThisRun.Add($game.Name)) {
            $__logger.Warn("Non-Steam: another selected game is already named '$($game.Name)', skipping the duplicate")
            $skippedDuplicate.Add($game.Name)
            continue
        }

        # A plugin can throw from anywhere in here. One unresolvable game must
        # not take the rest of the selection down with it.
        try {

        $sourceAction = Get-SourcePlayAction $game

        if ($sourceAction) {
            $launch = Resolve-GameLaunch $game $sourceAction
        } else {
            # No stored action. Library plugins supply theirs at launch time,
            # so ask the owning plugin rather than skipping the game.
            $raw = Resolve-LibraryPluginLaunch $game
            if (-not $raw) {
                # Most plugins use their own PlayController and expose no command
                # line at all: Ubisoft, EA, Battle.net, itch.io and Xbox all do.
                # Microsoft Store packages can be reconstructed exactly.
                $raw = Resolve-MicrosoftStoreLaunch $game
            }
            if (-not $raw) {
                # Everything else falls back to finding the executable inside the
                # install folder Playnite recorded.
                $raw = Resolve-InstallDirLaunch $game
            }
            $launch = Complete-LaunchSpec $game $raw
            if ($launch -and $raw.NoOverlay) { $launch.NoOverlay = $true }
            if ($launch -and $raw.Guessed)   { $launch.Guessed   = $true }
        }

        if (-not $launch) {
            if (-not $game.IsInstalled) {
                $__logger.Warn("Non-Steam: game is not installed, nothing to launch: $($game.Name)")
                $skippedNotInstalled.Add($game.Name)
            } elseif (-not $sourceAction) {
                $__logger.Error("Non-Steam: no play action and its library plugin supplied none: $($game.Name)")
                $skippedNoAction.Add($game.Name)
            } else {
                $__logger.Error("Non-Steam: could not resolve a launch command for: $($game.Name)")
                $skippedUnresolvable.Add($game.Name)
            }
            continue
        }

        # A stale action can outlive the install, which would produce a shortcut
        # pointing at a path that no longer exists. Verify before writing one.
        if (-not $launch.IsUrl) {
            $exeExists = $false
            try { $exeExists = Test-Path -LiteralPath $launch.Exe -PathType Leaf } catch { }
            if (-not $exeExists) {
                if (-not $game.IsInstalled) {
                    $__logger.Warn("Non-Steam: not installed, and its launch path is gone: $($game.Name)")
                    $skippedNotInstalled.Add($game.Name)
                    continue
                }
                # Marked installed but unreadable: could be ACLs or a drive that
                # is offline rather than a genuinely bad path, so warn and go on.
                # Reported as well as logged: the shortcut may well be
                # dead, and the user is the only one who can tell whether the
                # drive is merely offline.
                $__logger.Warn("Non-Steam: launch path is not readable for $($game.Name), creating the shortcut anyway: $($launch.Exe)")
                $unreadableTargets.Add($game.Name)
            }
        }

        if ($launch.IsUrl) {
            $__logger.Warn("Non-Steam: game launches via URL, Steam overlay will not work: $($game.Name)")
            $urlGames.Add($game.Name)
        }
        if ($launch.Guessed) {
            $guessedGames.Add($game.Name)
        }
        if ($launch.NoOverlay) {
            $__logger.Warn("Non-Steam: game is shell-activated, Steam overlay will not attach: $($game.Name)")
            $noOverlayGames.Add($game.Name)
        }

        $icon = ''
        if ($game.Icon) {
            try { $icon = $PlayniteApi.Database.GetFullFilePath($game.Icon) } catch { $icon = '' }
        }

        # Steam stores Exe and StartDir with their quotes included.
        $quotedExe      = '"{0}"' -f $launch.Exe
        $quotedStartDir = '"{0}"' -f $launch.StartDir

        # Find our own entry by the identity stamped into it. Matching on the
        # name would rename-orphan a shortcut, and would quietly overwrite one
        # that belongs to somebody else.
        $existing = Find-OwnedShortcutEntry $SteamShortcuts ([string]$game.Id) $owned
        if (-not $existing) {
            $byName = Find-ShortcutEntry $SteamShortcuts $game.Name
            if ($byName) {
                if ($null -eq (Get-ShortcutOwnerId $byName $owned)) {
                    # Someone else's shortcut under the same name: EmuDeck,
                    # Steam ROM Manager, or one made by hand. Overwriting it
                    # would destroy its command line, and claiming it would let
                    # a later cleanup delete it as though it were ours.
                    $__logger.Warn("Non-Steam: '$($game.Name)' is already in Steam and was not created by this extension, leaving it alone")
                    $skippedForeign.Add($game.Name)
                    continue
                }
                # Ours, but recorded against a different Playnite game. Steam
                # keys shortcuts by name, so this is still the one to update.
                $existing = $byName
            }
        }

        # Reuse whatever app id this shortcut already has. Steam names grid
        # artwork after the appid field, so replacing it with our own would
        # orphan any art already sitting in the grid folder. Only derive a new
        # id (from the CRC of Exe+AppName, the way Steam does) for brand new
        # shortcuts.
        $appId = $null
        if ($existing -and $existing.Contains('appid') -and $existing['appid'] -ne 0) {
            $appId = ConvertTo-UnsignedAppId ([long]$existing['appid'])
        }
        if ($null -eq $appId) {
            $appId = Get-ShortcutAppId $quotedExe $game.Name
        }

        $fields = [ordered]@{
            'appid'         = ConvertTo-SignedAppId $appId
            'appname'       = $game.Name
            'exe'           = $quotedExe
            'startdir'      = $quotedStartDir
            'icon'          = $icon
            'launchoptions' = $launch.Arguments
            # Marks the entry as ours, and carries the Playnite game id so a
            # later sync can tell whether the game still exists.
            'devkitgameid'  = "$($script:OwnerPrefix)$($game.Id)"
        }

        # Artwork is best effort and touches the network and the disk, so it
        # runs before anything is committed and cannot fail the game. Letting it
        # throw here would report a game that resolved perfectly well as one
        # whose launch command could not be worked out.
        try {
            $artCopied += Copy-SteamGridArt $GridDir $appId $game -Overwrite:$ReplaceArt

            # Steam falls back to a plain name tile when there is no library
            # capsule. That is usually because Playnite has no cover for the
            # game, which is worth saying rather than leaving to be noticed.
            $portrait = @(Get-ChildItem -LiteralPath $GridDir -Filter "${appId}p.*" -File -ErrorAction SilentlyContinue)
            if (-not $PlayniteArtOnly -and ($portrait.Count -eq 0 -or $ReplaceArt)) {
                # Playnite had nothing to copy (or we were told to replace), so
                # try SteamGridDB. Does nothing unless an API key has been set.
                # Skipped entirely when the caller asked for Playnite's artwork:
                # SteamGridDB matches on the name and can pick the wrong game,
                # which is the very thing that menu entry exists to overrule.
                $artCopied += Copy-SteamGridDbArt $GridDir $appId $game.Name -Overwrite:$ReplaceArt -Progress $Progress
                $portrait = @(Get-ChildItem -LiteralPath $GridDir -Filter "${appId}p.*" -File -ErrorAction SilentlyContinue)
            }
            if ($portrait.Count -eq 0) {
                $__logger.Info("Non-Steam: no library artwork for $($game.Name)")
                $noArtworkGames.Add($game.Name)
            }
        } catch {
            $__logger.Warn("Non-Steam: artwork failed for $($game.Name): $($_.Exception.Message)")
            $noArtworkGames.Add($game.Name)
        }

        # Worked out before the commit below, because it reads the existing
        # entry and must not leave it half-merged if it throws.
        $tags = Merge-SteamTags $existing $game

        #######################################################################
        # Commit. Counting the game, putting it in the file and queueing its
        # Playnite rewrite happen together and nothing between them may throw:
        # a game in shortcuts.vdf whose play action was never repointed still
        # launches outside Steam, while being reported as created.
        #######################################################################
        if ($existing) {
            $gamesUpdated++
            $shortcut = $existing
            foreach ($k in $fields.Keys) { $shortcut[$k] = $fields[$k] }
        } else {
            $gamesNew++
            $shortcut = $fields
            # Defaults fill in the fields Steam expects, but must not
            # overwrite the ones just worked out. 'devkitgameid' defaults to
            # empty, and applying it blindly wiped the ownership stamp off
            # every newly created shortcut, leaving only the separate json
            # record to identify our own entries.
            foreach ($k in $script:ShortcutDefaults.Keys) {
                if (-not $shortcut.Contains($k)) {
                    $shortcut[$k] = $script:ShortcutDefaults[$k]
                }
            }
            $SteamShortcuts.Add($shortcut)
        }
        $shortcut['tags'] = $tags
        $gamesToUpdate.Add([pscustomobject]@{
            Game         = $game
            SourceAction = $sourceAction
            SteamUrl     = Get-SteamRunGameUrl $appId
        })

        # Our own record of what we own, which Steam cannot alter. Held in
        # memory and written once the vdf is saved: writing it per game cost a
        # re-read and re-serialise of the whole file every time, and left the
        # record claiming shortcuts that a cancelled run never wrote.
        $owned["$appId"] = [string]$game.Id

        }
        catch {
            $__logger.Error("Non-Steam: failed while processing $($game.Name): $($_.Exception.Message)")
            $skippedUnresolvable.Add($game.Name)
            continue
        }
    }


    return @{
        GamesNew            = $gamesNew
        GamesUpdated        = $gamesUpdated
        ArtCopied           = $artCopied
        SkippedNoAction     = $skippedNoAction
        SkippedSteamNative  = $skippedSteamNative
        SkippedUnresolvable = $skippedUnresolvable
        SkippedNotInstalled = $skippedNotInstalled
        NoOverlayGames      = $noOverlayGames
        NoArtworkGames      = $noArtworkGames
        GuessedGames        = $guessedGames
        SkippedDuplicate    = $skippedDuplicate
        SkippedForeign      = $skippedForeign
        UnreadableTargets   = $unreadableTargets
        Owned               = $owned
        UrlGames            = $urlGames
        GamesToUpdate       = $gamesToUpdate
        Shortcuts           = $SteamShortcuts
        Cancelled           = $cancelled
    }
}

function Invoke-NonSteamShortcuts
{
    param($scriptGameMenuItemActionArgs, [switch]$ReplaceArt, [switch]$ReplaceAll, [switch]$PlayniteArtOnly)

    $games = $scriptGameMenuItemActionArgs.Games
    if (-not $games -or $games.Count -eq 0) {
        [void]$PlayniteApi.Dialogs.ShowMessage('No games selected.', 'Non-Steam Shortcuts')
        return
    }

    $steamUserdata = Get-SelectedSteamUserdataFolder
    if (-not (Test-SteamUserdataDir $steamUserdata)) { return }

    if (Get-Process -Name 'steam' -ErrorAction SilentlyContinue) {
        $answer = $PlayniteApi.Dialogs.ShowMessage(
            "Steam is running. It rewrites shortcuts.vdf when it exits, which would discard these shortcuts." +
            [Environment]::NewLine + [Environment]::NewLine +
            "Close Steam first, then run this again." +
            [Environment]::NewLine + [Environment]::NewLine +
            "Continue anyway?",
            'Non-Steam Shortcuts',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }

    $shortcutsVdf = Join-Path $steamUserdata 'config\shortcuts.vdf'
    $gridDir      = Join-Path $steamUserdata 'config\grid'
    $backupPath   = $null

    if (-not (Test-Path -LiteralPath $gridDir -PathType Container)) {
        New-Item -ItemType Directory -Path $gridDir -Force | Out-Null
    }

    # Load existing shortcuts
    if (Test-Path -LiteralPath $shortcutsVdf -PathType Leaf) {
        # Ask first, back up second. A backup slot is a scarce resource - only
        # ten are kept - so taking one before the user has agreed to anything
        # means changing your mind repeatedly discards the oldest backup, which
        # is the pristine one from before this extension ever ran.
        if ($ReplaceAll) {
            if (-not (Confirm-ReplaceAllShortcuts $shortcutsVdf $games.Count)) { return }
        }

        try {
            $backupPath = Backup-ShortcutsVdf $shortcutsVdf
        } catch {
            [void]$PlayniteApi.Dialogs.ShowErrorMessage($_.Exception.ToString(), 'Error backing up shortcuts.vdf')
            return
        }

        if ($ReplaceAll) {
            # Deliberately do NOT read the existing file: the whole point is to
            # discard it and rebuild the list from the selection.
            $steamShortcuts = New-Object 'System.Collections.Generic.List[object]'
            $__logger.Warn("Non-Steam: replacing every non-Steam shortcut with $($games.Count) selected game(s)")
        }
        else {
            try {
                $steamShortcuts = Read-ShortcutsVdf $shortcutsVdf
            } catch {
                [void]$PlayniteApi.Dialogs.ShowErrorMessage($_.Exception.ToString(), 'Error loading shortcuts.vdf')
                return
            }
        }
    } else {
        $steamShortcuts = New-Object 'System.Collections.Generic.List[object]'
    }

    # Our own progress window, on this thread. Playnite's ActivateGlobalProgress
    # cannot be driven from PowerShell at all; the reasoning is with
    # New-ProgressWindow.
    $progressWindow = New-ProgressWindow -Headline 'Creating non-Steam shortcuts' -Maximum $games.Count
    $build        = $null
    $writeError   = $null
    $updateFailed = @()

    try {
        $build = Invoke-ShortcutBuild `
            -Games $games -GridDir $gridDir -SteamShortcuts $steamShortcuts `
            -ReplaceArt:$ReplaceArt -PlayniteArtOnly:$PlayniteArtOnly -Progress $progressWindow

        # A cancelled run leaves shortcuts.vdf alone, so there is nothing to
        # save and nothing to undo.
        if (-not $build.Cancelled -and $build.GamesToUpdate.Count -gt 0) {
            if ($progressWindow) {
                $progressWindow.Step('Saving', 'Writing shortcuts.vdf...', $games.Count)
            }
            try {
                Write-ShortcutsVdf $shortcutsVdf $build.Shortcuts
            } catch {
                $writeError = $_
            }
            if (-not $writeError) {
                # Only once the file is really on disk. Drop records for app ids
                # that are no longer in it, so the record cannot accumulate rows
                # for shortcuts that no longer exist.
                $live = New-Object 'System.Collections.Generic.HashSet[string]'
                foreach ($entry in $build.Shortcuts) {
                    if ($entry.Contains('appid')) {
                        [void]$live.Add("$(ConvertTo-UnsignedAppId ([long]$entry['appid']))")
                    }
                }
                $keepOwned = @{}
                foreach ($key in $build.Owned.Keys) {
                    if ($live.Contains($key)) { $keepOwned[$key] = $build.Owned[$key] }
                }
                Save-OwnedShortcuts $keepOwned

                $updateFailed = Update-PlayniteGameActions -Items $build.GamesToUpdate -Progress $progressWindow
            }
        }
    }
    finally {
        # Before any dialog: the window disables Playnite's main window while it
        # is up, and leaving it open behind a message box would look stuck.
        Close-ProgressWindow $progressWindow
    }

    if ($writeError) {
        [void]$PlayniteApi.Dialogs.ShowErrorMessage($writeError.Exception.ToString(), 'Error saving shortcuts.vdf')
        if ($backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            try {
                Copy-Item -LiteralPath $backupPath -Destination $shortcutsVdf -Force -ErrorAction Stop
                [void]$PlayniteApi.Dialogs.ShowMessage('Successfully restored the shortcuts.vdf backup.', 'Non-Steam Shortcuts')
            } catch {
                [void]$PlayniteApi.Dialogs.ShowErrorMessage($_.Exception.ToString(), 'Error restoring shortcuts.vdf backup')
            }
        }
        return
    }

    if ($build.Cancelled) {
        # Steam is untouched, but artwork already fetched has been written to
        # the grid folder, so saying "nothing happened" would not be true.
        $__logger.Info('Non-Steam: run cancelled, shortcuts.vdf left untouched')
        $message  = 'Cancelled. No shortcuts were added to or changed in Steam.' + [Environment]::NewLine + [Environment]::NewLine
        if ($build.ArtCopied -gt 0) {
            $message += "$($build.ArtCopied) artwork file(s) had already been written to Steam's grid folder before you cancelled. "
            $message += 'They are harmless and will be reused if you run this again.' + [Environment]::NewLine + [Environment]::NewLine
        }
        $message += 'Run it again to pick up where this left off.'
        [void]$PlayniteApi.Dialogs.ShowMessage($message, 'Non-Steam Shortcuts')
        return
    }

    if ($build.GamesToUpdate.Count -eq 0) {
        # Nothing resolved, so nothing was written.
        Show-ResultMessage -GamesNew 0 -GamesUpdated 0 -ArtCopied 0 `
            -SkippedSteamNative $build.SkippedSteamNative -SkippedNoAction $build.SkippedNoAction `
            -SkippedUnresolvable $build.SkippedUnresolvable -SkippedDuplicate $build.SkippedDuplicate `
            -SkippedForeign $build.SkippedForeign -UnreadableTargets $build.UnreadableTargets `
            -SkippedNotInstalled $build.SkippedNotInstalled -NoOverlayGames $build.NoOverlayGames `
            -NoArtworkGames $build.NoArtworkGames -GuessedGames $build.GuessedGames -UrlGames $build.UrlGames -PlayniteArtOnly:$PlayniteArtOnly -NothingWritten
        return
    }

    Show-ResultMessage -GamesNew $build.GamesNew -GamesUpdated $build.GamesUpdated -ArtCopied $build.ArtCopied `
        -SkippedSteamNative $build.SkippedSteamNative -SkippedNoAction $build.SkippedNoAction `
        -SkippedUnresolvable $build.SkippedUnresolvable -SkippedDuplicate $build.SkippedDuplicate `
            -SkippedForeign $build.SkippedForeign -UnreadableTargets $build.UnreadableTargets `
        -SkippedNotInstalled $build.SkippedNotInstalled -NoOverlayGames $build.NoOverlayGames `
        -NoArtworkGames $build.NoArtworkGames -GuessedGames $build.GuessedGames -UrlGames $build.UrlGames -PlayniteArtOnly:$PlayniteArtOnly `
        -UpdateFailed $updateFailed
}

function Update-PlayniteGameActions
{
    <#
        Point each game's play action at Steam, now that shortcuts.vdf holds the
        matching entries. Separate from the build so the progress window can
        keep moving through what is, for a whole library, hundreds of database
        writes.
    #>
    param($Items, $Progress)

    $failed = New-Object 'System.Collections.Generic.List[string]'
    $done = 0
    if ($Progress) {
        $Progress.SetMaximum($Items.Count)
        # shortcuts.vdf is already written by this point. Stopping half way
        # would leave games in Steam that still launch outside it, so this
        # phase is deliberately not interruptible.
        $Progress.HideCancel()
    }

    foreach ($item in $Items) {
        $game         = $item.Game
        $sourceAction = $item.SourceAction

        if ($Progress) {
            $Progress.Step(
                "Updating Playnite   ($($done + 1) of $($Items.Count))",
                "$($game.Name) - pointing its play action at Steam",
                $done)
        }
        $done++

        # A library-plugin game may have no GameActions collection at all.
        if (-not $game.GameActions) {
            $game.GameActions = New-Object 'System.Collections.ObjectModel.ObservableCollection[Playnite.SDK.Models.GameAction]'
        }

        $steamAction = $null
        foreach ($action in $game.GameActions) {
            if ($action.Name -eq $script:SteamActionName) { $steamAction = $action; break }
        }

        if ($steamAction) {
            # Rerun: just refresh the URL, which changes if the exe or name did.
            $steamAction.Path         = $item.SteamUrl
            $steamAction.IsPlayAction = $true
        }
        else {
            $steamAction = New-Object Playnite.SDK.Models.GameAction
            $steamAction.Name         = $script:SteamActionName
            $steamAction.Type         = [Playnite.SDK.Models.GameActionType]::URL
            $steamAction.Path         = $item.SteamUrl
            $steamAction.IsPlayAction = $true
            $game.GameActions.Insert(0, $steamAction)
        }

        # Label the original so a rerun can find it, unless a previous run
        # already stashed a different action under that name. Games whose action
        # came from their library plugin have nothing stored to rename; the
        # plugin keeps supplying it, so a rerun resolves them the same way.
        if ($sourceAction) {
            $nameTaken = $false
            foreach ($action in $game.GameActions) {
                if (-not [object]::ReferenceEquals($action, $sourceAction) -and
                    $action.Name -eq $script:LaunchWithoutSteamName) {
                    $nameTaken = $true
                    break
                }
            }
            if (-not $nameTaken) { $sourceAction.Name = $script:LaunchWithoutSteamName }
        }

        # Only the Steam action should be the play action
        foreach ($action in $game.GameActions) {
            if (-not [object]::ReferenceEquals($action, $steamAction)) { $action.IsPlayAction = $false }
        }

        try {
            $PlayniteApi.Database.Games.Update($game)
        } catch {
            # One game that cannot be saved must not abandon the rest, and must
            # not escape as a raw script error that hides the summary entirely.
            $__logger.Error("Non-Steam: could not update $($game.Name) in Playnite: $($_.Exception.Message)")
            $failed.Add($game.Name)
        }
    }
    return ,([string[]]$failed.ToArray())
}

function Show-ResultMessage
{
    param(
        [int]$GamesNew,
        [int]$GamesUpdated,
        [int]$ArtCopied,
        $SkippedSteamNative,
        $SkippedNoAction,
        $SkippedUnresolvable,
        $SkippedDuplicate,
        $SkippedNotInstalled,
        $NoOverlayGames,
        $NoArtworkGames,
        $GuessedGames,
        $UrlGames,
        $SkippedForeign,
        $UnreadableTargets,
        $UpdateFailed,
        [switch]$PlayniteArtOnly,
        [switch]$NothingWritten
    )

    if ($null -eq $UpdateFailed) { $UpdateFailed = @() }
    if ($null -eq $SkippedForeign) { $SkippedForeign = @() }
    if ($null -eq $UnreadableTargets) { $UnreadableTargets = @() }

    function Format-GameList($list) {
        if ($list.Count -gt 10) {
            return (($list[0..9] + "[... and $($list.Count - 10) more, all named in playnite.log]") -join [Environment]::NewLine)
        }
        return ($list -join [Environment]::NewLine)
    }

    $nl = [Environment]::NewLine

    if ($NothingWritten) {
        $message = 'Nothing to do - shortcuts.vdf was left untouched.' + $nl
    } else {
        $message  = 'Please relaunch Steam to pick up the new non-Steam shortcuts.' + $nl + $nl
        $message += "Created $GamesNew new non-Steam shortcut(s)" + $nl
        $message += "Updated $GamesUpdated existing non-Steam shortcut(s)" + $nl
        $message += "Copied $ArtCopied artwork file(s) into Steam's grid folder"
    }

    $errors = $false

    if ($SkippedSteamNative.Count -gt 0) {
        $message += $nl + $nl + "Skipped $($SkippedSteamNative.Count) native Steam game(s):" + $nl
        $message += Format-GameList $SkippedSteamNative
        $errors = $true
    }
    if ($SkippedDuplicate.Count -gt 0) {
        $message += $nl + $nl + "Skipped $($SkippedDuplicate.Count) game(s) sharing a name with another selected game (Steam identifies shortcuts by name):" + $nl
        $message += Format-GameList $SkippedDuplicate
        $errors = $true
    }
    if ($SkippedForeign.Count -gt 0) {
        $message += $nl + $nl + "Left $($SkippedForeign.Count) existing Steam shortcut(s) alone, because something else created them and Steam identifies shortcuts by name:" + $nl
        $message += Format-GameList $SkippedForeign
        $message += $nl + 'Delete them in Steam first if you want this extension to manage them instead.'
        $errors = $true
    }
    if ($UnreadableTargets.Count -gt 0) {
        $message += $nl + $nl + "$($UnreadableTargets.Count) game(s) are marked installed but their file could not be read, so the shortcut may not launch:" + $nl
        $message += Format-GameList $UnreadableTargets
        $message += $nl + 'That is expected if they live on a drive that is currently offline. Otherwise check them in Playnite.'
        $errors = $true
    }
    if ($UpdateFailed.Count -gt 0) {
        $message += $nl + $nl + "$($UpdateFailed.Count) game(s) are in Steam, but Playnite could not save the change that makes them launch through it:" + $nl
        $message += Format-GameList $UpdateFailed
        $message += $nl + 'They will still launch directly from Playnite. Run this again to retry.'
        $errors = $true
    }
    if ($SkippedNotInstalled.Count -gt 0) {
        $message += $nl + $nl + "Skipped $($SkippedNotInstalled.Count) game(s) that are not installed:" + $nl
        $message += Format-GameList $SkippedNotInstalled
        $message += $nl + 'Install them, then run this again - a shortcut needs a real executable to point at.'
        $errors = $true
    }
    if ($SkippedNoAction.Count -gt 0) {
        $message += $nl + $nl + "Skipped $($SkippedNoAction.Count) game(s) with no play action, whose library plugin also supplied none:" + $nl
        $message += Format-GameList $SkippedNoAction
        $message += $nl + $nl + 'The log records what each library plugin returned for these.'
        $errors = $true
    }
    if ($SkippedUnresolvable.Count -gt 0) {
        $message += $nl + $nl + "Skipped $($SkippedUnresolvable.Count) game(s) whose launch command could not be resolved (bad emulator profile, or a script action):" + $nl
        $message += Format-GameList $SkippedUnresolvable
        $errors = $true
    }
    if ($NoArtworkGames.Count -gt 0) {
        $message += $nl + $nl + "$($NoArtworkGames.Count) game(s) have no library artwork in Steam."
        if ($PlayniteArtOnly) {
            # SteamGridDB was skipped on purpose here, so suggesting a key
            # would be beside the point.
            $message += ' You asked for Playnite''s artwork, and Playnite has no cover for these, so Steam'
            $message += ' shows a plain name tile. Give them a cover in Playnite and run this again:' + $nl
        }
        elseif ([string]::IsNullOrWhiteSpace((Get-SteamGridDbApiKey))) {
            $message += ' Playnite has no cover for them and no SteamGridDB key is set, so there was nothing'
            $message += ' to copy. Set a key under "Extensions" -> "Non-Steam Shortcuts" -> "Set SteamGridDB'
            $message += ' API key..." to pull fan-made art automatically, or give them a cover in Playnite:' + $nl
        } else {
            $message += ' Neither Playnite nor SteamGridDB had anything for them, so Steam shows a plain name'
            $message += ' tile. Give them a cover in Playnite and run "use Playnite artwork" to push it across:' + $nl
        }
        $message += Format-GameList $NoArtworkGames
    }
    if ($GuessedGames.Count -gt 0) {
        $message += $nl + $nl + "$($GuessedGames.Count) game(s) had no launch command from their store, so the"
        $message += ' executable was found by scanning the install folder. Worth checking these actually start'
        $message += ' from Steam; the log records which file was picked:' + $nl
        $message += Format-GameList $GuessedGames
    }
    if ($NoOverlayGames.Count -gt 0) {
        $message += $nl + $nl + "$($NoOverlayGames.Count) of these are packaged Microsoft Store apps,"
        $message += ' activated through the shell because Windows will not start them any other way:' + $nl
        $message += Format-GameList $NoOverlayGames
    }
    if ($UrlGames.Count -gt 0) {
        $message += $nl + $nl + 'Note: Xbox / Game Pass titles run inside the Microsoft app container, so they '
        $message += 'launch and are tracked by Steam but the Steam overlay will not attach to them.'
        $message += $nl + $nl + 'Warning: some games launch via a URL (typically managed by a library plugin). '
        $message += 'Steam will still launch them, but the Steam overlay will not work. '
        $message += 'You may want to give them a direct file action and rerun this.'
        $message += $nl + $nl + "The following $($UrlGames.Count) game(s) had URL launch actions:" + $nl
        $message += Format-GameList $UrlGames
        $errors = $true
    }

    if ($errors) {
        $message += $nl + $nl + 'Open playnite.log for the full list?'
        $answer = $PlayniteApi.Dialogs.ShowMessage(
            $message,
            'Non-Steam Shortcuts',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning)
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
            Invoke-Item (Join-Path $PlayniteApi.Paths.ConfigurationPath 'playnite.log')
        }
    } else {
        [void]$PlayniteApi.Dialogs.ShowMessage($message, 'Non-Steam Shortcuts')
    }
}

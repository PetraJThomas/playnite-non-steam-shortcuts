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

    $replace = New-Object Playnite.SDK.Plugins.ScriptGameMenuItem
    $replace.Description  = 'Create non-Steam shortcuts (replace Steam artwork)'
    $replace.FunctionName = 'Add-NonSteamShortcutsReplacingArt'
    $replace.MenuSection  = '@Non-Steam Shortcuts'

    return @($create, $replace)
}

function GetMainMenuItems
{
    param($getMainMenuItemsArgs)

    $item = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $item.Description  = 'Set Steam userdata folder...'
    $item.FunctionName = 'Set-SteamUserdataFolder'
    $item.MenuSection  = '@Non-Steam Shortcuts'
    return $item
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

    $backupPath = '{0}.{1}.bak' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force -ErrorAction Stop

    $old = @(Get-ChildItem -LiteralPath (Split-Path -Parent $Path) -Filter '*.bak' -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -Skip $script:BackupsToKeep)
    foreach ($f in $old) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    }
    return $backupPath
}


###############################################################################
# Steam userdata folder discovery
###############################################################################

function Test-SteamUserdataDir
{
    param([string]$Folder)

    return (-not [string]::IsNullOrWhiteSpace($Folder)) -and
           (Test-Path -LiteralPath (Join-Path $Folder 'config') -PathType Container)
}

function Get-SteamUserdataConfigPath
{
    if (-not (Test-Path -LiteralPath $CurrentExtensionDataPath -PathType Container)) {
        New-Item -ItemType Directory -Path $CurrentExtensionDataPath -Force | Out-Null
    }
    return (Join-Path $CurrentExtensionDataPath 'steam_userdata_path.txt')
}

function Find-SteamUserdataDirs
{
    <#
        Locate candidate userdata\<steamid> folders from the Steam install
        recorded in the registry, falling back to the usual install locations.
    #>
    $steamRoots = New-Object 'System.Collections.Generic.List[string]'

    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($name in @('SteamPath', 'InstallPath')) {
                $value = $props.$name
                if (-not [string]::IsNullOrWhiteSpace($value)) { $steamRoots.Add($value) }
            }
        } catch { }
    }

    $steamRoots.Add("${env:ProgramFiles(x86)}\Steam")
    $steamRoots.Add("$env:ProgramFiles\Steam")

    # Steam writes SteamPath lowercased and with forward slashes, while the
    # fallbacks are proper-cased with backslashes, so compare normalised paths
    # case insensitively or the same folder gets offered twice.
    $seen  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $found = New-Object 'System.Collections.Generic.List[string]'

    foreach ($root in $steamRoots) {
        $userdata = Join-Path $root 'userdata'
        if (-not (Test-Path -LiteralPath $userdata -PathType Container)) { continue }
        foreach ($dir in (Get-ChildItem -LiteralPath $userdata -Directory -ErrorAction SilentlyContinue)) {
            # "0" and "anonymous" are not real accounts
            if ($dir.Name -eq '0' -or $dir.Name -eq 'anonymous') { continue }
            if (-not (Test-SteamUserdataDir $dir.FullName)) { continue }

            $normalised = $dir.FullName
            try { $normalised = [System.IO.Path]::GetFullPath($normalised).TrimEnd('\') } catch { }
            if ($seen.Add($normalised)) { $found.Add($normalised) }
        }
    }

    # Returned as a string[] rather than a List, and wrapped with a comma so a
    # single result is not unrolled into a bare string that the caller would
    # then index one character at a time.
    return ,([string[]]$found.ToArray())
}

function Set-SteamUserdataFolder
{
    param($scriptMainMenuItemActionArgs)

    $folder = Select-SteamUserdataFolder -Force
    if ($folder) {
        $PlayniteApi.Dialogs.ShowMessage("Steam userdata folder set to:`n$folder", 'Non-Steam Shortcuts')
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
    }

    # Assigned directly: the function already returns a string[], and wrapping
    # it in @() would produce a one-element array holding the array itself,
    # which then renders as its type name instead of the paths.
    $candidates = Find-SteamUserdataDirs

    if (-not $Force -and $candidates.Count -eq 1 -and (Test-SteamUserdataDir $candidates[0])) {
        Set-Content -LiteralPath $configPath -Value $candidates[0] -Encoding UTF8
        $__logger.Info("Non-Steam: auto-detected Steam userdata folder: $($candidates[0])")
        return $candidates[0]
    }

    $message = 'Select your Steam profile''s userdata folder.' + [Environment]::NewLine + [Environment]::NewLine
    if ($candidates.Count -gt 0) {
        $message += 'Detected the following on this machine:' + [Environment]::NewLine
        $message += ($candidates -join [Environment]::NewLine) + [Environment]::NewLine + [Environment]::NewLine
        $message += 'Pick the one matching your Steam account in the next dialog.'
    } else {
        $message += 'It is usually at C:\Program Files (x86)\Steam\userdata\<your steam id>.'
    }
    $PlayniteApi.Dialogs.ShowMessage($message, 'Non-Steam Shortcuts')

    $folder = $PlayniteApi.Dialogs.SelectFolder()
    if (Test-SteamUserdataDir $folder) {
        Set-Content -LiteralPath $configPath -Value $folder -Encoding UTF8
        return $folder
    }

    if (-not [string]::IsNullOrWhiteSpace($folder)) {
        $PlayniteApi.Dialogs.ShowErrorMessage(
            "That folder has no 'config' subfolder, so it is not a Steam userdata profile folder.",
            'Non-Steam Shortcuts')
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
    return $candidates[0]
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

        Most Game Pass PC titles declare EntryPoint="Windows.FullTrustApplication",
        i.e. they are ordinary Win32 games in WindowsApps with a real .exe. For
        those we target the executable directly, which keeps Steam attached to
        the process so the overlay works. Genuine sandboxed UWP apps fall back to
        shell activation, which launches but cannot carry the overlay.
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

    # Sandboxed UWP, or the executable could not be reached: shell-activate it
    # the same way the Xbox plugin does. Steam will launch it, but explorer.exe
    # exits immediately so the overlay cannot attach.
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

    $controllers = $null
    try {
        $playArgs = New-Object Playnite.SDK.Plugins.GetPlayActionsArgs
        $playArgs.Game = $Game
        $controllers = $plugin.GetPlayActions($playArgs)
    } catch {
        $__logger.Error("Non-Steam: $($plugin.Name) could not supply a play action for $($Game.Name): $($_.Exception.Message)")
        return $null
    }
    if (-not $controllers) { return $null }

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

    $tags = $Shortcut['tags']
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
# Main entry point
###############################################################################

function Add-NonSteamShortcuts
{
    param($scriptGameMenuItemActionArgs)

    Invoke-NonSteamShortcuts $scriptGameMenuItemActionArgs
}

function Add-NonSteamShortcutsReplacingArt
{
    param($scriptGameMenuItemActionArgs)

    Invoke-NonSteamShortcuts $scriptGameMenuItemActionArgs -ReplaceArt
}

function Invoke-NonSteamShortcuts
{
    param($scriptGameMenuItemActionArgs, [switch]$ReplaceArt)

    $games = $scriptGameMenuItemActionArgs.Games
    if (-not $games -or $games.Count -eq 0) {
        $PlayniteApi.Dialogs.ShowMessage('No games selected.', 'Non-Steam Shortcuts')
        return
    }

    $steamUserdata = Select-SteamUserdataFolder
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
        try {
            $backupPath = Backup-ShortcutsVdf $shortcutsVdf
        } catch {
            $PlayniteApi.Dialogs.ShowErrorMessage($_.Exception.ToString(), 'Error backing up shortcuts.vdf')
            return
        }
        try {
            $steamShortcuts = Read-ShortcutsVdf $shortcutsVdf
        } catch {
            $PlayniteApi.Dialogs.ShowErrorMessage($_.Exception.ToString(), 'Error loading shortcuts.vdf')
            return
        }
    } else {
        $steamShortcuts = New-Object 'System.Collections.Generic.List[object]'
    }

    $gamesUpdated        = 0
    $gamesNew            = 0
    $artCopied           = 0
    $skippedNoAction     = New-Object 'System.Collections.Generic.List[string]'
    $skippedSteamNative  = New-Object 'System.Collections.Generic.List[string]'
    $skippedUnresolvable = New-Object 'System.Collections.Generic.List[string]'
    $skippedNotInstalled = New-Object 'System.Collections.Generic.List[string]'
    $noOverlayGames      = New-Object 'System.Collections.Generic.List[string]'
    $skippedDuplicate    = New-Object 'System.Collections.Generic.List[string]'
    $urlGames            = New-Object 'System.Collections.Generic.List[string]'
    $gamesToUpdate       = New-Object 'System.Collections.Generic.List[object]'
    $namesThisRun        = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($game in $games) {

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

        $sourceAction = Get-SourcePlayAction $game

        if ($sourceAction) {
            $launch = Resolve-GameLaunch $game $sourceAction
        } else {
            # No stored action. Library plugins supply theirs at launch time,
            # so ask the owning plugin rather than skipping the game.
            $raw = Resolve-LibraryPluginLaunch $game
            if (-not $raw) {
                # Some plugins (notably Xbox) use their own PlayController and
                # expose no command line at all, so rebuild it ourselves.
                $raw = Resolve-MicrosoftStoreLaunch $game
            }
            $launch = Complete-LaunchSpec $game $raw
            if ($launch -and $raw.NoOverlay) { $launch.NoOverlay = $true }
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

        if ($launch.IsUrl) {
            $__logger.Warn("Non-Steam: game launches via URL, Steam overlay will not work: $($game.Name)")
            $urlGames.Add($game.Name)
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

        $existing = Find-ShortcutEntry $steamShortcuts $game.Name

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
        }

        if ($existing) {
            $gamesUpdated++
            $shortcut = $existing
            foreach ($k in $fields.Keys) { $shortcut[$k] = $fields[$k] }
        } else {
            $gamesNew++
            $shortcut = $fields
            foreach ($k in $script:ShortcutDefaults.Keys) {
                $shortcut[$k] = $script:ShortcutDefaults[$k]
            }
            $steamShortcuts.Add($shortcut)
        }

        $shortcut['tags'] = Merge-SteamTags $shortcut $game

        $artCopied += Copy-SteamGridArt $gridDir $appId $game -Overwrite:$ReplaceArt

        # Remember the Playnite-side rewrite, applied only once the vdf is saved.
        $gamesToUpdate.Add([pscustomobject]@{
            Game         = $game
            SourceAction = $sourceAction
            SteamUrl     = Get-SteamRunGameUrl $appId
        })
    }

    if ($gamesToUpdate.Count -eq 0) {
        # Nothing resolved, so do not rewrite a file we have no changes for.
        Show-ResultMessage -GamesNew 0 -GamesUpdated 0 -ArtCopied 0 `
            -SkippedSteamNative $skippedSteamNative -SkippedNoAction $skippedNoAction `
            -SkippedUnresolvable $skippedUnresolvable -SkippedDuplicate $skippedDuplicate `
            -SkippedNotInstalled $skippedNotInstalled -NoOverlayGames $noOverlayGames -UrlGames $urlGames -NothingWritten
        return
    }

    # Save shortcuts.vdf
    try {
        Write-ShortcutsVdf $shortcutsVdf $steamShortcuts
    } catch {
        $PlayniteApi.Dialogs.ShowErrorMessage($_.Exception.ToString(), 'Error saving shortcuts.vdf')
        if ($backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            try {
                Copy-Item -LiteralPath $backupPath -Destination $shortcutsVdf -Force -ErrorAction Stop
                $PlayniteApi.Dialogs.ShowMessage('Successfully restored the shortcuts.vdf backup.', 'Non-Steam Shortcuts')
            } catch {
                $PlayniteApi.Dialogs.ShowErrorMessage($_.Exception.ToString(), 'Error restoring shortcuts.vdf backup')
            }
        }
        return
    }

    # Rewrite the Playnite actions so the game launches through Steam
    foreach ($item in $gamesToUpdate) {
        $game         = $item.Game
        $sourceAction = $item.SourceAction

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

        $PlayniteApi.Database.Games.Update($game)
    }

    Show-ResultMessage -GamesNew $gamesNew -GamesUpdated $gamesUpdated -ArtCopied $artCopied `
        -SkippedSteamNative $skippedSteamNative -SkippedNoAction $skippedNoAction `
        -SkippedUnresolvable $skippedUnresolvable -SkippedDuplicate $skippedDuplicate `
            -SkippedNotInstalled $skippedNotInstalled -NoOverlayGames $noOverlayGames -UrlGames $urlGames
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
        $UrlGames,
        [switch]$NothingWritten
    )

    function Format-GameList($list) {
        if ($list.Count -gt 10) {
            return (($list[0..9] + '[...]') -join [Environment]::NewLine)
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
    if ($SkippedNotInstalled.Count -gt 0) {
        $message += $nl + $nl + "Skipped $($SkippedNotInstalled.Count) game(s) that are not installed:" + $nl
        $message += Format-GameList $SkippedNotInstalled
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
    if ($NoOverlayGames.Count -gt 0) {
        $message += $nl + $nl + "Created $($NoOverlayGames.Count) shortcut(s) that launch through the Microsoft Store."
        $message += ' Steam will start them, but because they are shell-activated the overlay will not attach:' + $nl
        $message += Format-GameList $NoOverlayGames
        $errors = $true
    }
    if ($UrlGames.Count -gt 0) {
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
        $PlayniteApi.Dialogs.ShowMessage($message, 'Non-Steam Shortcuts')
    }
}

. "$PSScriptRoot\common.ps1"
$mod = $ModulePath
# Regressions for the QA round: the defects below were all reproduced against
# the previous version, so each test here is a bug that actually happened.

$global:__logger = New-Module -AsCustomObject -ScriptBlock {
    function Info([string]$m){}; function Warn([string]$m){}; function Error([string]$m){}
    Export-ModuleMember -Function Info,Warn,Error
}
$root = Join-Path $env:TEMP "nss_qa_$([guid]::NewGuid().ToString('N'))"
$global:CurrentExtensionDataPath = Join-Path $root 'data'
$grid = Join-Path $root 'grid'
New-Item -ItemType Directory -Path $global:CurrentExtensionDataPath,$grid -Force | Out-Null
# Minimal PlayniteApi: the build loop expands variables and resolves media paths.
$global:PlayniteApi = New-Module -AsCustomObject -ScriptBlock {
    function ExpandGameVariables { param($game, $action) return $action }
    $Database = New-Module -AsCustomObject -ScriptBlock {
        function GetFullFilePath { param($p) return $p }
        Export-ModuleMember -Function GetFullFilePath
    }
    $Addons = New-Module -AsCustomObject -ScriptBlock {
        $Plugins = @()
        Export-ModuleMember -Variable Plugins
    }
    Export-ModuleMember -Function ExpandGameVariables -Variable Database,Addons
}

Import-Module $mod -Force -DisableNameChecking
$m = Get-Module NonSteamShortcuts

function New-Game($name, $exe) {
    $act = [pscustomobject]@{ Name='Play'; Path=$exe; Arguments=''; WorkingDir=(Split-Path -Parent $exe); IsPlayAction=$true; Type=[Playnite.SDK.Models.GameActionType]::File }
    [pscustomobject]@{
        Name=$name; Id=[guid]::NewGuid(); GameId='x'; PluginId=[Guid]::Empty; IsInstalled=$true
        InstallDirectory=(Split-Path -Parent $exe); Icon=$null; CoverImage=$null; BackgroundImage=$null
        Categories=$null; GameActions=@($act)
    }
}
$exe = Join-Path $env:WINDIR 'explorer.exe'

'=== a foreign shortcut with the same name is NOT overwritten ==='
# Exactly the EmuDeck case: someone else made "Sonic Mania" with a RetroArch
# command line, and no ownership stamp.
$foreign = [ordered]@{
    'appid'='123456'; 'appname'='Sonic Mania'
    'exe'='"D:\EmuDeck\retroarch.exe"'; 'startdir'='"D:\EmuDeck"'
    'launchoptions'='-L cores\genesis.dll "D:\roms\sonic.bin"'; 'devkitgameid'=''
}
$list = New-Object 'System.Collections.Generic.List[object]'
$list.Add($foreign)
$game = New-Game 'Sonic Mania' $exe
$r = & $m { param($g,$gd,$sc) Invoke-ShortcutBuild -Games $g -GridDir $gd -SteamShortcuts $sc -Progress $null } @($game) $grid $list

Check 'exe untouched'            $foreign['exe'] '"D:\EmuDeck\retroarch.exe"'
Check 'command line untouched'   $foreign['launchoptions'] '-L cores\genesis.dll "D:\roms\sonic.bin"'
Check 'not claimed as ours'      $foreign['devkitgameid'] ''
Check 'no second entry added'    $list.Count 1
Check 'reported as left alone'   ($r.SkippedForeign -contains 'Sonic Mania') 'True'
Check 'not counted as created'   $r.GamesNew 0
Check 'not counted as updated'   $r.GamesUpdated 0
Check 'not queued for Playnite'  $r.GamesToUpdate.Count 0
Check 'not claimed in the record' ($r.Owned.Count) 0

'=== our own shortcut IS updated, and only once ==='
$list2 = New-Object 'System.Collections.Generic.List[object]'
$g2 = New-Game 'Celeste' $exe
$r2 = & $m { param($g,$gd,$sc) Invoke-ShortcutBuild -Games $g -GridDir $gd -SteamShortcuts $sc -Progress $null } @($g2) $grid $list2
Check 'created'                  $r2.GamesNew 1
Check 'stamped as ours'          ($list2[0]['devkitgameid'] -like "*$($g2.Id)*") 'True'
$appIdFirst = $list2[0]['appid']

$r3 = & $m { param($g,$gd,$sc,$o) Invoke-ShortcutBuild -Games $g -GridDir $gd -SteamShortcuts $sc -Progress $null } @($g2) $grid $list2 $r2.Owned
Check 'rerun updates, not adds'  $list2.Count 1
Check 'counted as updated'       $r3.GamesUpdated 1
Check 'appid is stable'          $list2[0]['appid'] $appIdFirst

'=== renaming a game updates its shortcut instead of duplicating it ==='
# The old code matched on name only, so a rename orphaned the old entry
# forever and Sync would never remove it.
$g2renamed = [pscustomobject]@{
    Name='Celeste Classic'; Id=$g2.Id; GameId='x'; PluginId=[Guid]::Empty; IsInstalled=$true
    InstallDirectory=(Split-Path -Parent $exe); Icon=$null; CoverImage=$null; BackgroundImage=$null
    Categories=$null; GameActions=$g2.GameActions
}
$r4 = & $m { param($g,$gd,$sc) Invoke-ShortcutBuild -Games $g -GridDir $gd -SteamShortcuts $sc -Progress $null } @($g2renamed) $grid $list2
Check 'still one entry'          $list2.Count 1
Check 'name was updated'         $list2[0]['appname'] 'Celeste Classic'
Check 'appid kept, so art stays' $list2[0]['appid'] $appIdFirst
Check 'no duplicate reported'    $r4.GamesNew 0

'=== a failed SteamGridDB download does not destroy existing artwork ==='
$art = Join-Path $grid '999888777p.png'
[IO.File]::WriteAllBytes($art, (New-Object byte[] 64))
$before = (Get-Item $art).Length
$saved = & $m {
    param($gd)
    # Force the lookup to succeed and the download to fail, which is the
    # transient case: the API host answers, the CDN does not.
    function Invoke-SteamGridDbApi { param($p,$k) return @([pscustomobject]@{ id=1; name='X'; url='https://nonexistent.invalid/x.png' }) }
    function Get-SteamGridDbApiKey { return 'dummy' }
    Save-SteamGridDbAsset $gd 999888777 1 'grids' 'p' '' 'dummy'
} $grid
Check 'download reported failed' $saved 'False'
Check 'existing artwork survived' (Test-Path -LiteralPath $art) 'True'
Check 'and is unchanged'          (Get-Item $art).Length $before
Check 'no .part left behind'      (@(Get-ChildItem $grid -Filter 'nss_download_*').Count) 0

'=== backup pruning keeps the OLDEST backup, not the newest ten by mtime ==='
$bdir = Join-Path $root 'steamcfg'
New-Item -ItemType Directory -Path $bdir | Out-Null
$vdf = Join-Path $bdir 'shortcuts.vdf'
[IO.File]::WriteAllText($vdf, 'PRISTINE')
# The pristine file is old; every later version is newer, which is what made
# the old sort delete the pristine backup first.
$pristine = & $m { param($p) Backup-ShortcutsVdf $p } $vdf
(Get-Item $pristine).LastWriteTime = (Get-Date).AddDays(-30)
for ($i=1; $i -le 12; $i++) {
    [IO.File]::WriteAllText($vdf, "RUN-$i")
    [void](& $m { param($p) Backup-ShortcutsVdf $p } $vdf)
}
# The very first backup is the only copy of the file as it was before this
# extension ever ran, which is what undoing a "replace ALL" needs.
Check 'pristine backup survived'  (Test-Path -LiteralPath $pristine) 'True'
Check 'pristine still pristine'   ([IO.File]::ReadAllText($pristine)) 'PRISTINE'
$kept = @(Get-ChildItem $bdir -File | Where-Object { $_.Name -match '^shortcuts\.vdf\.\d{8}-\d{6}(\d{3})?(-\d+)?\.bak$' })
Check 'kept the cap'              ($kept.Count -le 10) 'True'
# and the most recent run is still recoverable too
$newest = ($kept | Sort-Object Name | Select-Object -Last 1)
Check 'newest backup is the last run' ([IO.File]::ReadAllText($newest.FullName)) 'RUN-12'

'=== pruning ignores files that merely start with .bak ==='
$decoy = Join-Path $bdir 'notes.bakery'
[IO.File]::WriteAllText($decoy, 'not mine')
[IO.File]::WriteAllText($vdf, 'again')
[void](& $m { param($p) Backup-ShortcutsVdf $p } $vdf)
Check 'unrelated .bakery untouched' (Test-Path -LiteralPath $decoy) 'True'

'=== a null field is written as a string, not an int ==='
$tmp = Join-Path $root 'null.vdf'
$e = [ordered]@{ 'appid'=1; 'appname'='X'; 'icon'=$null }
$l = New-Object 'System.Collections.Generic.List[object]'; $l.Add($e)
& $m { param($p,$x) Write-ShortcutsVdf $p $x } $tmp $l
$back = & $m { param($p) Read-ShortcutsVdf $p } $tmp
Check 'null round-trips as string' ($back[0]['icon'] -is [string]) 'True'
Check 'and is empty'               "$($back[0]['icon'])" ''

Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests

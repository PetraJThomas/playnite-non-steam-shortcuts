. "$PSScriptRoot\common.ps1"
$mod = $ModulePath
$global:__logger = New-Module -AsCustomObject -ScriptBlock { function Info($m){}; function Warn($m){}; function Error($m){}; Export-ModuleMember -Function Info,Warn,Error }
$global:CurrentExtensionDataPath = Join-Path $env:TEMP "nss_sync_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $global:CurrentExtensionDataPath | Out-Null
Import-Module $mod -Force -DisableNameChecking
$m=Get-Module NonSteamShortcuts

$liveId  = [Guid]::NewGuid().ToString()
$deadId  = [Guid]::NewGuid().ToString()

function New-Entry($name, $appid, $devkit) {
    $h=[ordered]@{ 'appid'=[int]$appid; 'appname'=$name; 'exe'='"x.exe"'; 'startdir'='""'; 'icon'=''
                   'launchoptions'=''; 'devkitgameid'=$devkit; 'tags'=[ordered]@{} }
    return ,$h
}

'--- ownership: neither signal means NOT ours (never delete) ---'
$foreign = New-Entry 'EmuDeck Thing' -1000 ''
Check 'no stamp, no record -> not ours' ($null -eq (& $m { param($e,$o) Get-ShortcutOwnerId $e $o } $foreign @{})) 'True'
$otherTool = New-Entry 'Other Tool' -1001 'boilr:12345'
Check 'someone else''s stamp -> not ours' ($null -eq (& $m { param($e,$o) Get-ShortcutOwnerId $e $o } $otherTool @{})) 'True'

'--- ownership via the stamp alone ---'
$stamped = New-Entry 'Stamped Game' -1002 "playnite:$liveId"
Check 'stamp recognised' (& $m { param($e,$o) Get-ShortcutOwnerId $e $o } $stamped @{}) $liveId

'--- ownership via our record alone (stamp stripped by Steam) ---'
$stripped = New-Entry 'Stripped Game' -1003 ''
$appid3 = & $m { param($v) ConvertTo-UnsignedAppId $v } ([long]-1003)
$record = @{ "$appid3" = $liveId }
Check 'record recognised when stamp is gone' (& $m { param($e,$o) Get-ShortcutOwnerId $e $o } $stripped $record) $liveId

'--- the record survives a round trip to disk ---'
# The record is built in memory during a run and saved once, after
# shortcuts.vdf is on disk, so that a cancelled run cannot leave it claiming
# shortcuts that were never written.
$owned = @{ '4164523112' = $liveId; '2633555618' = $deadId }
& $m { param($o) Save-OwnedShortcuts $o } $owned
$back = & $m { Get-OwnedShortcuts }
Check 'two entries recorded'  $back.Count 2
Check 'first maps correctly'  $back['4164523112'] $liveId
Check 'second maps correctly' $back['2633555618'] $deadId
Check 'stored as json'        (Test-Path (& $m { Get-OwnedShortcutsPath })) 'True'

'--- grid art removal matches exactly, not by prefix ---'
$grid = Join-Path $env:TEMP "nss_grid_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $grid | Out-Null
foreach($f in '123.png','123p.jpg','123_hero.png','123_logo.png','1234.png','1234p.png','99123.png'){
  Set-Content -LiteralPath (Join-Path $grid $f) -Value 'x'
}
$removed = & $m { param($g,$a) Remove-SteamGridArt $g $a } $grid 123
Check 'removed exactly the four for 123' $removed 4
$left = @(Get-ChildItem $grid -File | Select-Object -ExpandProperty Name | Sort-Object)
"  left behind: $($left -join ', ')"
Check 'did NOT eat 1234.png'  ($left -contains '1234.png') 'True'
Check 'did NOT eat 1234p.png' ($left -contains '1234p.png') 'True'
Check 'did NOT eat 99123.png' ($left -contains '99123.png') 'True'

'--- the stamp is written onto new shortcuts ---'
$src = Get-Content -LiteralPath $mod -Raw
Check 'devkitgameid is stamped'   ($src -like "*'devkitgameid'  = `"`$(`$script:OwnerPrefix)`$(`$game.Id)`"*") 'True'
# .Contains, not -like: [string] would be read as a wildcard character class.
Check 'ownership is recorded'     ($src.Contains('$owned["$appId"] = [string]$game.Id')) 'True'
Check 'and saved after the write' ($src -like '*Save-OwnedShortcuts $keepOwned*') 'True'
Check 'defaults cannot wipe it'   ($src -like '*if (-not $shortcut.Contains($k))*') 'True'

'--- menu now has three main entries ---'
$items = @(& $m { GetMainMenuItems $null })
Check 'three main menu items' $items.Count 3
Check 'has the sync entry'    ($items.Description -contains 'Remove shortcuts for games deleted from Playnite') 'True'

'--- regression: the real vdf is still readable and untouched ---'
$realVdf = Get-RealShortcutsVdf
if ($realVdf) {
    $before=(Get-FileHash -LiteralPath $realVdf).Hash
    $e2 = & $m { param($p) Read-ShortcutsVdf $p } $realVdf
    Check 'real vdf still parses' ($e2.Count -ge 1) 'True'
    Check 'real vdf untouched'    (Get-FileHash -LiteralPath $realVdf).Hash $before
} else {
    '  SKIP no real shortcuts.vdf on this machine'
}

Remove-Item $grid -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $global:CurrentExtensionDataPath -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests

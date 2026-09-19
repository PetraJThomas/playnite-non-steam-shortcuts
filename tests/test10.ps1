. "$PSScriptRoot\common.ps1"
$mod = $ModulePath
$global:__logger = New-Module -AsCustomObject -ScriptBlock {
    function Info([string]$m){ Write-Host "      [log] $m" -ForegroundColor DarkGray }
    function Warn([string]$m){ Write-Host "      [warn] $m" -ForegroundColor DarkYellow }
    function Error([string]$m){}
    Export-ModuleMember -Function Info,Warn,Error
}
# isolated extension data dir so we never touch the real key/config
$global:CurrentExtensionDataPath = Join-Path $env:TEMP "nss_sgdb_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $global:CurrentExtensionDataPath | Out-Null

# Playnite's runspace has the SDK loaded; a bare shell does not.
Import-Module $mod -Force -DisableNameChecking
$m=Get-Module NonSteamShortcuts

'--- no key configured: everything is a no-op, nothing throws ---'
Check 'key is null'            ($null -eq (& $m { Get-SteamGridDbApiKey })) 'True'
$grid = Join-Path $env:TEMP "nss_grid_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $grid | Out-Null
$n = & $m { param($g,$a,$nm) Copy-SteamGridDbArt $g $a $nm } $grid 2760952396 'Forza Horizon 4 Demo'
Check 'copies nothing without a key' $n 0
Check 'writes no files'              (Get-ChildItem $grid -File).Count 0

'--- bad key: fails gracefully, returns 0, does not throw ---'
& $m { Save-SteamGridDbApiKey 'not-a-real-key' }   # stored encrypted, like the real setter does
Import-Module $mod -Force -DisableNameChecking   # reset cached key
$m=Get-Module NonSteamShortcuts
Check 'bad key is read' (& $m { Get-SteamGridDbApiKey }) 'not-a-real-key'
$n2 = & $m { param($g,$a,$nm) Copy-SteamGridDbArt $g $a $nm } $grid 2760952396 'Forza Horizon 4 Demo'
Check 'bad key copies nothing' $n2 0
Check 'still no files'         (Get-ChildItem $grid -File).Count 0

'--- API wrapper returns $null rather than throwing on 401 ---'
$r = & $m { param($k) Invoke-SteamGridDbApi 'search/autocomplete/portal' $k } 'not-a-real-key'
Check 'unauthorised -> null' ($null -eq $r) 'True'

'--- game id lookup caches misses so one bad name is not retried ---'
$id1 = & $m { param($k) Find-SteamGridDbGameId 'Totally Fake Game 99999' $k } 'not-a-real-key'
$id2 = & $m { param($k) Find-SteamGridDbGameId 'Totally Fake Game 99999' $k } 'not-a-real-key'
Check 'miss returns null'  ($null -eq $id1) 'True'
Check 'miss is cached'     ($null -eq $id2) 'True'

'--- menu now offers both main-menu items ---'
$items = @(& $m { GetMainMenuItems $null })
Check 'main menu is populated' ($items.Count -ge 2) 'True'
Check 'has folder finder'   ($items.Description -contains 'Find Steam Install Folder') 'True'
Check 'has key setter'      ($items.Description -contains 'Set SteamGridDB API key...') 'True'
$game = @(& $m { GetGameMenuItems $null })
Check 'game menu is populated' ($game.Count -ge 2) 'True'

'--- existing artwork is respected unless -Overwrite ---'
Set-Content -LiteralPath (Join-Path $grid '2760952396p.png') -Value 'x'
$before = (Get-Item (Join-Path $grid '2760952396p.png')).LastWriteTime
$n3 = & $m { param($g,$a,$nm) Copy-SteamGridDbArt $g $a $nm } $grid 2760952396 'Forza Horizon 4 Demo'
Check 'existing portrait untouched' ((Get-Item (Join-Path $grid '2760952396p.png')).LastWriteTime) $before

Remove-Item $grid -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $global:CurrentExtensionDataPath -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests

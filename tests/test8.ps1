. "$PSScriptRoot\common.ps1"
$mod = $ModulePath

# These check the module against a genuine Steam install, so there is nothing
# to assert without one. Read-only throughout: nothing here writes to Steam.
$realProfilePath = Get-RealSteamProfile
if (-not $realProfilePath) {
    Write-Host 'SKIP: no Steam userdata profile on this machine' -ForegroundColor Yellow
    exit 0
}
$steamRootPath = Split-Path -Parent (Split-Path -Parent $realProfilePath)
$global:__logger = New-Module -AsCustomObject -ScriptBlock { function Info($m){}; function Warn($m){}; function Error($m){}; Export-ModuleMember -Function Info,Warn,Error }
Import-Module $mod -Force -DisableNameChecking
$m=Get-Module NonSteamShortcuts

$root=$steamRootPath
$prof=$realProfilePath

'--- THE BUG: Steam root must be rejected as a profile ---'
Check 'Steam root rejected'      (& $m { param($p) Test-SteamUserdataDir $p } $root) 'False'
Check 'real profile accepted'    (& $m { param($p) Test-SteamUserdataDir $p } $prof) 'True'
Check 'userdata dir rejected'    (& $m { param($p) Test-SteamUserdataDir $p } (Join-Path $root 'userdata')) 'False'
Check 'windows dir rejected'     (& $m { param($p) Test-SteamUserdataDir $p } 'C:\Windows') 'False'
Check 'empty rejected'           (& $m { param($p) Test-SteamUserdataDir $p } '') 'False'

'--- Steam root now RESOLVES to the profile inside it ---'
$fromRoot = & $m { param($p) Get-SteamProfilesUnder $p } $root
"  from root     -> $($fromRoot -join ', ')"
Check 'root resolves to 1 profile' $fromRoot.Count 1
Check 'and it is the right one'    $fromRoot[0] $prof

$fromUserdata = & $m { param($p) Get-SteamProfilesUnder $p } (Join-Path $root 'userdata')
Check 'userdata dir resolves too'  $fromUserdata[0] $prof

$fromProfile = & $m { param($p) Get-SteamProfilesUnder $p } $prof
Check 'profile resolves to itself' $fromProfile[0] $prof

$fromJunk = & $m { param($p) Get-SteamProfilesUnder $p } 'C:\Windows'
Check 'junk resolves to nothing'   $fromJunk.Count 0

'--- lowercase/forward-slash registry form still works ---'
$reg='c:/program files (x86)/steam'
$fromReg = & $m { param($p) Get-SteamProfilesUnder $p } $reg
Check 'registry-form root resolves' $fromReg.Count 1

'--- auto-detect still de-duplicates to one ---'
$all = & $m { Find-SteamUserdataDirs }
"  detected: $($all -join ', ')"
Check 'is string[]'        ($all -is [string[]]) 'True'
Check 'exactly one profile' $all.Count 1

'--- persona name lookup for the picker label ---'
$names = & $m { param($r) Get-SteamPersonaNames $r } $root
"  account -> persona: " + (($names.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')
# Whichever account this machine has: assert the parse worked, not a
# particular person's name.
$profileId = Split-Path -Leaf $realProfilePath
Check 'personas parsed'            ($names -is [hashtable]) 'True'
Check 'this profile has a persona' (-not [string]::IsNullOrWhiteSpace($names[$profileId])) 'True'

'--- single profile must NOT pop a chooser (returns it directly) ---'
$one = & $m { param($p) Select-SteamProfileInteractively $p } ([string[]]@($prof))
Check 'single profile returned as-is' $one $prof
$none = & $m { param($p) Select-SteamProfileInteractively $p } ([string[]]@())
Check 'empty -> null' ($null -eq $none) 'True'

'--- regressions ---'
Check 'crc32 vector' ('0x{0:X8}' -f (& $m { Get-Crc32 ([Text.Encoding]::ASCII.GetBytes('123456789')) })) '0xCBF43926'
$ddv=[pscustomobject]@{Name='DDV';GameId='A278AB0D.DisneyDreamlightValley_h6adky7gbf63m';InstallDirectory=$null;IsInstalled=$true}
Check 'store resolution intact' ((& $m { param($g) Resolve-MicrosoftStoreLaunch $g } $ddv).Exe -like '*GameLaunchHelper.exe') 'True'

Complete-Tests

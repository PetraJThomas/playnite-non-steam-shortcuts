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

# Fake PlayniteApi. ShowMessage RETURNS MessageBoxResult.OK, exactly like the real
# one - that returned value is what leaked into the output and became "OK".
Add-Type -AssemblyName PresentationFramework
$global:selectFolderReturns = ''
$global:PlayniteApi = New-Module -AsCustomObject -ScriptBlock {
    $Dialogs = New-Module -AsCustomObject -ScriptBlock {
        function ShowMessage { param($a,$b,$c,$d) return [System.Windows.MessageBoxResult]::OK }
        function ShowErrorMessage { param($a,$b) return [System.Windows.MessageBoxResult]::OK }
        function SelectFolder { return $global:selectFolderReturns }
        Export-ModuleMember -Function ShowMessage,ShowErrorMessage,SelectFolder
    }
    Export-ModuleMember -Variable Dialogs
}
$global:CurrentExtensionDataPath = Join-Path $env:TEMP "nss_cfg_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $global:CurrentExtensionDataPath | Out-Null

Import-Module $mod -Force -DisableNameChecking
$m=Get-Module NonSteamShortcuts

'--- THE BUG: browse, then press Cancel (SelectFolder returns empty) ---'
$global:selectFolderReturns = ''
$r = & $m { Get-SelectedSteamUserdataFolder -Force }
"  returned: '$r'   type=$(if($null -eq $r){'null'}else{$r.GetType().Name})"
Check 'cancel returns null, not "OK"' ($null -eq $r) 'True'
Check 'definitely not the string OK'  ($r -eq 'OK') 'False'

'--- cancel via SelectFolder returning $null ---'
$global:selectFolderReturns = $null
$r2 = & $m { Get-SelectedSteamUserdataFolder -Force }
Check 'null from picker -> null' ($null -eq $r2) 'True'

'--- picking a junk folder ---'
$global:selectFolderReturns = 'C:\Windows'
$r3 = & $m { Get-SelectedSteamUserdataFolder -Force }
Check 'junk folder -> null' ($null -eq $r3) 'True'

'--- picking the Steam ROOT resolves to the profile ---'
$global:selectFolderReturns = $steamRootPath
$r4 = & $m { Get-SelectedSteamUserdataFolder -Force }
Check 'root -> real profile' $r4 $realProfilePath
Check 'and it validates'     (& $m { param($p) Test-SteamUserdataDir $p } $r4) 'True'

'--- picking the profile directly ---'
$global:selectFolderReturns = $realProfilePath
$r5 = & $m { Get-SelectedSteamUserdataFolder -Force }
Check 'profile -> itself' $r5 $realProfilePath

'--- the saved config was written only on success ---'
$saved = Join-Path $global:CurrentExtensionDataPath 'steam_userdata_path.txt'
Check 'config written' (Test-Path $saved) 'True'
Check 'config holds the profile' ((Get-Content -LiteralPath $saved -Raw).Trim()) $realProfilePath

'--- raw function still leaks nothing now ---'
$global:selectFolderReturns = ''
$raw = @(& $m { Select-SteamUserdataFolder -Force })
"  raw output count = $($raw.Count)"
Check 'no stray MessageBoxResult in output' (($raw | Where-Object { $_ -is [System.Windows.MessageBoxResult] }).Count) 0

Remove-Item $global:CurrentExtensionDataPath -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests

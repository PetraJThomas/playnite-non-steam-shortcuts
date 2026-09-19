. "$PSScriptRoot\common.ps1"
$mod = $ModulePath
$global:__logger = New-Module -AsCustomObject -ScriptBlock {
    function Info([string]$m){}; function Warn([string]$m){ Write-Host "      [warn] $m" -ForegroundColor DarkYellow }
    function Error([string]$m){ Write-Host "      [err] $m" -ForegroundColor Red }
    Export-ModuleMember -Function Info,Warn,Error
}
$global:CurrentExtensionDataPath = Join-Path $env:TEMP "nss_prog_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $global:CurrentExtensionDataPath | Out-Null
Add-Type -AssemblyName PresentationFramework
Import-Module $mod -Force -DisableNameChecking
$m = Get-Module NonSteamShortcuts

'--- the old broken call is gone ---'
$src = Get-Content -LiteralPath $mod -Raw
# The name still appears in the comments explaining why it is not used, so
# look for an actual call rather than a mention.
Check 'no call to it'              ($src -like '*Dialogs.ActivateGlobalProgress*') 'False'
Check 'no GlobalProgressOptions'   ($src -like '*GlobalProgressOptions*') 'False'
Check 'no CancelToken use'         ($src -like '*CancelToken*') 'False'
Check 'no $script:BuildInput hop'  ($src -like '*$script:BuildInput*') 'False'

'--- the type compiles ---'
$ok = & $m { Initialize-ProgressWindowType }
Check 'Add-Type succeeded' $ok 'True'
Check 'type is loaded'     ([bool]([System.Management.Automation.PSTypeName]'NonSteamShortcutsProgress').Type) 'True'

'--- a real window opens, pumps and closes on this thread ---'
$w = New-Object NonSteamShortcutsProgress
$threadBefore = [Threading.Thread]::CurrentThread.ManagedThreadId
$w.Start('Creating non-Steam shortcuts', 10, $null)
Check 'window reports open' $w.IsOpen 'True'
Check 'not cancelled yet'   $w.Cancelled 'False'

$sw = [Diagnostics.Stopwatch]::StartNew()
for ($i = 1; $i -le 10; $i++) {
    $w.Step("Creating non-Steam shortcuts   ($i of 10)", "Test Game $i - working out how to launch it", $i)
    $w.Say("Test Game $i - downloading library capsule from SteamGridDB")
}
$sw.Stop()
Check 'still on the same thread' ([Threading.Thread]::CurrentThread.ManagedThreadId) $threadBefore
Check 'pumping is cheap (<3s for 20)' ($sw.Elapsed.TotalSeconds -lt 3) 'True'
"       20 pumps took $([math]::Round($sw.Elapsed.TotalMilliseconds)) ms"

'--- SetMaximum restarts the bar for the second phase ---'
$w.SetMaximum(5)
$w.Step('Updating Playnite   (1 of 5)', 'Test Game - pointing its play action at Steam', 1)
Check 'still open after phase change' $w.IsOpen 'True'

'--- closing the X counts as cancel, and Finish is idempotent ---'
$w.Finish()
Check 'closed'              $w.IsOpen 'False'
$w.Finish()
Check 'second Finish is safe' $w.IsOpen 'False'
$w.Step('x','y',1)
$w.Say('z')
$w.Pump()
Check 'calls after Finish are no-ops' $w.IsOpen 'False'

'--- HideCancel, for work too short to interrupt ---'
$w3 = New-Object NonSteamShortcutsProgress
$w3.Start('Checking the SteamGridDB key', 0, $null)
$w3.HideCancel()
$w3.Say('Asking SteamGridDB whether it accepts the key...')
Check 'indeterminate window open' $w3.IsOpen 'True'
$w3.Finish()
Check 'closed again' $w3.IsOpen 'False'
$w3.HideCancel()
'  OK   HideCancel after Finish is safe'

'--- New-ProgressWindow and Close-ProgressWindow round-trip ---'
$w2 = & $m { New-ProgressWindow -Headline 'Removing shortcuts' -Maximum 3 }
Check 'factory returned a window' ($null -ne $w2) 'True'
if ($w2) {
    $w2.Step('Removing shortcuts   (1 of 3)', 'Old Game - deleting its artwork', 1)
    Check 'factory window is open' $w2.IsOpen 'True'
}
& $m { param($x) Close-ProgressWindow $x } $w2
if ($w2) { Check 'factory window closed' $w2.IsOpen 'False' }
& $m { param($x) Close-ProgressWindow $x } $null
'  OK   Close-ProgressWindow $null is safe'

'--- callers tolerate a $null window (headless) ---'
$r = & $m { param($g,$d) Invoke-ShortcutBuild -Games $g -GridDir $d -SteamShortcuts (New-Object 'System.Collections.Generic.List[object]') -Progress $null } @() $global:CurrentExtensionDataPath
Check 'build with no window, no games' $r.Cancelled 'False'
Check 'build returned a result'        ($null -ne $r.GamesToUpdate) 'True'

'--- cancel short-circuits the build ---'
$fakeCancelled = New-Object NonSteamShortcutsProgress   # never Started, so IsOpen=false
$fakeCancelled.Cancelled = $true
$games = @([pscustomobject]@{ Name='A'; PluginId=[Guid]::Empty }, [pscustomobject]@{ Name='B'; PluginId=[Guid]::Empty })
$r2 = & $m { param($g,$d,$p) Invoke-ShortcutBuild -Games $g -GridDir $d -SteamShortcuts (New-Object 'System.Collections.Generic.List[object]') -Progress $p } $games $global:CurrentExtensionDataPath $fakeCancelled
Check 'cancelled before any game'  $r2.Cancelled 'True'
Check 'nothing was queued'         $r2.GamesToUpdate.Count '0'

'--- the wiring is in place ---'
Check 'build takes the window'    ($src -like '*-Progress $progressWindow*') 'True'
Check 'window closed in finally'  ($src -like '*finally {*Close-ProgressWindow $progressWindow*') 'True'
Check 'db loop reports'           ($src -like '*Updating Playnite   (*') 'True'
Check 'griddb reports per asset'  ($src -like '*downloading $($slot.Label) from SteamGridDB*') 'True'
Check 'cleanup reports'           ($src -like '*deleting its artwork*') 'True'
Check 'key check reports'         ($src -like '*Checking the SteamGridDB key*') 'True'
Check 'key check hides cancel'    ($src -like '*$checking.HideCancel()*') 'True'
Check 'key check always closes'   ($src -like '*Close-ProgressWindow $checking*') 'True'

Remove-Item $global:CurrentExtensionDataPath -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests

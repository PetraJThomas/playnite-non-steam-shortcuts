. "$PSScriptRoot\common.ps1"
$mod = $ModulePath
# Why this extension does not use Playnite's ActivateGlobalProgress.
#
# It looked like the obvious API and was used at first. Every run logged
# "Multiple ambiguous overloads found" and fell through to a synchronous path
# that froze Playnite with no window at all. These assertions pin down both
# reasons so the API is not reached for again.


'--- reason 1: the SDK really does declare two scriptblock-compatible overloads ---'
$overloads = @([Playnite.SDK.IDialogsFactory].GetMethods() | Where-Object { $_.Name -eq 'ActivateGlobalProgress' })
Check 'two overloads exist' $overloads.Count 2
$shapes = @($overloads | ForEach-Object { $_.GetParameters()[0].ParameterType.Name })
Check 'one takes Action`1' ($shapes -contains 'Action`1') 'True'
Check 'one takes Func`2'   ($shapes -contains 'Func`2') 'True'

Add-Type -ReferencedAssemblies $SdkPath,'WindowsBase' -TypeDefinition @'
using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
using Playnite.SDK;

// Stands in for Playnite: same two overloads, and the action runs on a worker
// thread, which is the part that matters.
public class FakeDialogs {
    public string Taken = "none";
    public Exception Failure = null;
    public bool Ran = false;
    public GlobalProgressResult ActivateGlobalProgress(Action<GlobalProgressActionArgs> a, GlobalProgressOptions o) {
        Taken = "Action";
        var args = new GlobalProgressActionArgs(SynchronizationContext.Current, Dispatcher.CurrentDispatcher, CancellationToken.None);
        Task.Run(() => { try { a(args); Ran = true; } catch (Exception ex) { Failure = ex; } }).Wait();
        return null;
    }
    public GlobalProgressResult ActivateGlobalProgress(Func<GlobalProgressActionArgs, Task> a, GlobalProgressOptions o) {
        Taken = "Func"; return null;
    }
}
'@ -ErrorAction SilentlyContinue

$opts = New-Object Playnite.SDK.GlobalProgressOptions('x', $true)

'--- a bare scriptblock matches both, so the call is rejected ---'
$d = New-Object FakeDialogs
$msg = ''
try { $null = $d.ActivateGlobalProgress({ param($p) }, $opts) } catch { $msg = $_.Exception.Message }
Check 'call is refused as ambiguous' ($msg -like '*ambiguous*') 'True'
"       -> $msg"
Check 'nothing ran' $d.Ran 'False'

'--- reason 2: casting past that only reaches the real problem ---'
$d2 = New-Object FakeDialogs
$act = [Action[Playnite.SDK.GlobalProgressActionArgs]]{ param($p) $global:ran = $true }
$msg2 = ''
try { $null = $d2.ActivateGlobalProgress($act, $opts) } catch { $msg2 = $_.Exception.Message }
Check 'the cast does disambiguate' ($msg2 -eq '') 'True'
Check 'Action overload is chosen'  $d2.Taken 'Action'
Check 'but the body still cannot run' $d2.Ran 'False'
Check 'because the worker thread has no runspace' ($d2.Failure.Message -like '*no Runspace available*') 'True'
"       -> $($d2.Failure.Message.Split([char]10)[0])"

# Lending the worker the caller's runspace is the remaining option, and it
# deadlocks: that runspace is still busy running the menu action. Not asserted
# here, because a test that hangs forever is worse than no test.

'--- so the module uses its own window instead ---'
$mod = $ModulePath
$src = Get-Content -LiteralPath $mod -Raw
Check 'no call to the SDK progress' ($src -like '*Dialogs.ActivateGlobalProgress*') 'False'
Check 'no GlobalProgressOptions'    ($src -like '*GlobalProgressOptions*') 'False'
Check 'own window instead'          ($src -like '*function New-ProgressWindow*') 'True'
Check 'runs on the calling thread'  ($src -like '*Dispatcher.PushFrame(frame)*') 'True'
Check 'reason is written down'      ($src -like '*cannot be used from a PowerShell*') 'True'

Complete-Tests

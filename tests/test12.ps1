. "$PSScriptRoot\common.ps1"
$mod = $ModulePath
$global:__logger = New-Module -AsCustomObject -ScriptBlock {
    function Info([string]$m){}; function Warn([string]$m){}; function Error([string]$m){}
    Export-ModuleMember -Function Info,Warn,Error
}
$global:CurrentExtensionDataPath = Join-Path $env:TEMP "nss_prog_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $global:CurrentExtensionDataPath | Out-Null
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
$m=Get-Module NonSteamShortcuts

$grid = Join-Path $env:TEMP "nss_g_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $grid | Out-Null

# A fake GlobalProgressActionArgs: records Text updates and can request cancel.
$global:progressLog = New-Object System.Collections.Generic.List[string]
Add-Type -TypeDefinition @'
using System.Threading;
// Same surface as NonSteamShortcutsProgress, minus the WPF window, so the
// build can be driven headlessly and every status line captured.
public class FakeProgress {
    public bool Cancelled;
    public double Maximum;
    public double CurrentProgressValue;
    public System.Collections.Generic.List<string> Seen = new System.Collections.Generic.List<string>();
    public System.Collections.Generic.List<string> Details = new System.Collections.Generic.List<string>();
    public void Step(string headline, string detail, double value) {
        if (headline != null) { Seen.Add(headline); }
        if (detail != null) { Details.Add(detail); }
        if (value >= 0) { CurrentProgressValue = value; }
    }
    public void Say(string detail) { if (detail != null) { Details.Add(detail); } }
    public void SetMaximum(double max) { Maximum = max; CurrentProgressValue = 0; }
}
'@ -ErrorAction SilentlyContinue

# Two games that resolve without touching the network: a plain File action.
function New-FakeGame($name, $exe) {
    $act = [pscustomobject]@{ Name='Play'; Path=$exe; Arguments=''; WorkingDir=(Split-Path -Parent $exe); IsPlayAction=$true; Type=[Playnite.SDK.Models.GameActionType]::File }
    return [pscustomobject]@{
        Name=$name; GameId='x'; PluginId=[Guid]::Empty; IsInstalled=$true
        InstallDirectory=(Split-Path -Parent $exe); Icon=$null; CoverImage=$null; BackgroundImage=$null
        Categories=$null; GameActions=@($act)
    }
}
$exe = Join-Path $env:WINDIR 'explorer.exe'
$games = @((New-FakeGame 'Alpha Game' $exe), (New-FakeGame 'Beta Game' $exe))

'--- runs with NO progress object (the synchronous fallback path) ---'
$shortcuts = New-Object 'System.Collections.Generic.List[object]'
$r = & $m { param($g,$gd,$sc) Invoke-ShortcutBuild -Games $g -GridDir $gd -SteamShortcuts $sc -Progress $null } $games $grid $shortcuts
Check 'returns a result'   ($null -ne $r) 'True'
Check 'not cancelled'      ([bool]$r.Cancelled) 'False'
Check 'two new shortcuts'  $r.GamesNew 2
Check 'two queued updates' $r.GamesToUpdate.Count 2
Check 'shortcuts built'    $r.Shortcuts.Count 2

'--- runs WITH a progress object and reports live text ---'
$p = New-Object FakeProgress
$shortcuts2 = New-Object 'System.Collections.Generic.List[object]'
$r2 = & $m { param($g,$gd,$sc,$pr) Invoke-ShortcutBuild -Games $g -GridDir $gd -SteamShortcuts $sc -Progress $pr } $games $grid $shortcuts2 $p
Check 'still builds both'      $r2.GamesNew 2
Check 'headline was set'       ($p.Seen.Count -ge 2) 'True'
Check 'detail was set'         ($p.Details.Count -ge 2) 'True'
"  status lines seen:"
$p.Seen    | Select-Object -First 2 | ForEach-Object { "     headline '$_'" }
$p.Details | Select-Object -First 2 | ForEach-Object { "     detail   '$_'" }
Check 'shows a running count'  ($p.Seen[0] -like '*1 of 2*') 'True'
Check 'names the game'         ($p.Details[0] -like '*Alpha Game*') 'True'
Check 'counter advanced'       ($p.CurrentProgressValue -ge 1) 'True'

'--- cancellation stops the walk and is reported ---'
$p2 = New-Object FakeProgress
$p2.Cancelled = $true
$shortcuts3 = New-Object 'System.Collections.Generic.List[object]'
$r3 = & $m { param($g,$gd,$sc,$pr) Invoke-ShortcutBuild -Games $g -GridDir $gd -SteamShortcuts $sc -Progress $pr } $games $grid $shortcuts3 $p2
Check 'reports cancelled'      ([bool]$r3.Cancelled) 'True'
Check 'built nothing'          $r3.GamesToUpdate.Count 0
Check 'left shortcuts alone'   $r3.Shortcuts.Count 0

'--- the progress-dialog wiring exists in the caller ---'
$src = Get-Content -LiteralPath $mod -Raw
Check 'opens our own window'        ($src -like '*New-ProgressWindow -Headline*') 'True'
Check 'always closes it'            ($src -like '*Close-ProgressWindow $progressWindow*') 'True'
Check 'checks the Cancelled flag'   ($src -like '*if ($Progress.Cancelled)*') 'True'

Remove-Item $grid -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $global:CurrentExtensionDataPath -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests

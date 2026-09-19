. "$PSScriptRoot\common.ps1"
$mod = $ModulePath
$global:__logger = New-Module -AsCustomObject -ScriptBlock {
    function Info([string]$m){}; function Warn([string]$m){}
    function Error([string]$m){ Write-Host "      [err] $m" -ForegroundColor DarkYellow }
    Export-ModuleMember -Function Info,Warn,Error
}
$global:CurrentExtensionDataPath = Join-Path $env:TEMP "nss_lazy_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $global:CurrentExtensionDataPath | Out-Null

# A plugin whose GetPlayActions is a LAZY iterator that throws on enumeration,
# exactly like the Epic plugin does when a game's manifest is missing.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public class ThrowingPlugin {
    public Guid Id = Guid.Empty;
    public string Name = "Throwing Store";
    public IEnumerable<string> GetPlayActions(object args) {
        // Nothing here runs until the caller enumerates.
        return Iterate();
    }
    private IEnumerable<string> Iterate() {
        throw new Exception("Can't start Epic game, installation data manifest not found.");
#pragma warning disable 0162
        yield break;
#pragma warning restore 0162
    }
}
'@ -ErrorAction SilentlyContinue

'--- proving the trap is real: calling does not throw, enumerating does ---'
$p = New-Object ThrowingPlugin
$threwOnCall = $false
try { $null = $p.GetPlayActions($null) } catch { $threwOnCall = $true }
Check 'calling it is safe'  $threwOnCall 'False'
$threwOnEnum = $false
try { foreach($x in $p.GetPlayActions($null)) { } } catch { $threwOnEnum = $true }
Check 'enumerating throws'  $threwOnEnum 'True'
$threwOnArray = $false
try { $null = @($p.GetPlayActions($null)) } catch { $threwOnArray = $true }
Check '@() forces it, so a try around @() catches it' $threwOnArray 'True'

Import-Module $mod -Force -DisableNameChecking
$m=Get-Module NonSteamShortcuts

'--- the module now forces enumeration inside the try ---'
$src = Get-Content -LiteralPath $mod -Raw
Check 'uses @() on GetPlayActions' ($src -like '*@($plugin.GetPlayActions($playArgs))*') 'True'
Check 'explains why'               ($src -like '*C# iterator*') 'True'
Check 'counts instead of truthiness' ($src -like '*if ($controllers.Count -eq 0) { return $null }*') 'True'

'--- per-game processing is isolated so one bad game cannot abort the run ---'
Check 'per-game try exists'   ($src -like '*One unresolvable game must*') 'True'
Check 'failure is bucketed'   ($src -like '*failed while processing*') 'True'

'--- Resolve-LibraryPluginLaunch survives a throwing plugin ---'
$global:PlayniteApi = New-Module -AsCustomObject -ScriptBlock {
    $Addons = New-Module -AsCustomObject -ScriptBlock {
        $Plugins = @()
        Export-ModuleMember -Variable Plugins
    }
    Export-ModuleMember -Variable Addons
}
$game = [pscustomobject]@{ Name='Broken Epic Game'; PluginId=[Guid]::Empty }
$r = & $m { param($g) Resolve-LibraryPluginLaunch $g } $game
Check 'empty plugin id -> null, no throw' ($null -eq $r) 'True'

Remove-Item $global:CurrentExtensionDataPath -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests

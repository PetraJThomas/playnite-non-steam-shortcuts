# Shared setup for the test suite.
#
# Dot-source this from the top of every test:
#
#     . "$PSScriptRoot\common.ps1"
#
# Tests must run from any checkout, so nothing here hardcodes a path to one
# person's machine. Anything that genuinely needs real local state - a Steam
# install, a game folder - asks for it through the Skip-* helpers below and
# reports a skip rather than a failure when it is not there.

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- locations
$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ModulePath = Join-Path $RepoRoot 'NonSteamShortcuts.psm1'

if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) {
    throw "Could not find NonSteamShortcuts.psm1 next to the tests (looked in $RepoRoot)"
}

function Find-PlayniteSdk
{
    <#
        Playnite.SDK.dll is x86, which is why these tests have to run under
        x86 PowerShell. Set NONSTEAM_PLAYNITE_SDK to point somewhere else.
    #>
    if ($env:NONSTEAM_PLAYNITE_SDK -and (Test-Path -LiteralPath $env:NONSTEAM_PLAYNITE_SDK -PathType Leaf)) {
        return $env:NONSTEAM_PLAYNITE_SDK
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.SDK.dll'),
        (Join-Path ${env:ProgramFiles(x86)} 'Playnite\Playnite.SDK.dll'),
        (Join-Path $env:ProgramFiles 'Playnite\Playnite.SDK.dll')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    return $null
}

$SdkPath = Find-PlayniteSdk
if (-not $SdkPath) {
    Write-Host 'SKIP: Playnite.SDK.dll not found. Set NONSTEAM_PLAYNITE_SDK to its path.' -ForegroundColor Yellow
    exit 0
}
if ([IntPtr]::Size -ne 4) {
    Write-Host 'SKIP: run these under x86 PowerShell - C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe' -ForegroundColor Yellow
    exit 0
}
[void][Reflection.Assembly]::LoadFrom($SdkPath)

# ------------------------------------------------------------- assertions
$script:FailCount = 0

function Check($name, $actual, $expected)
{
    if ("$actual" -eq "$expected") {
        "  OK   $name = $actual"
    } else {
        $script:FailCount++
        "  FAIL $name`n       got      $actual`n       expected $expected"
    }
}

function Complete-Tests
{
    ''
    if ($script:FailCount -eq 0) { 'ALL TESTS PASSED' }
    else { "$($script:FailCount) TEST(S) FAILED"; exit 1 }
}

# ------------------------------------------------------------------ stubs
function New-TestLogger
{
    param([switch]$Verbose)
    if ($Verbose) {
        return New-Module -AsCustomObject -ScriptBlock {
            function Info([string]$m){ Write-Host "      [log]  $m" -ForegroundColor DarkGray }
            function Warn([string]$m){ Write-Host "      [warn] $m" -ForegroundColor DarkYellow }
            function Error([string]$m){ Write-Host "      [err]  $m" -ForegroundColor Red }
            Export-ModuleMember -Function Info,Warn,Error
        }
    }
    return New-Module -AsCustomObject -ScriptBlock {
        function Info([string]$m){}; function Warn([string]$m){}; function Error([string]$m){}
        Export-ModuleMember -Function Info,Warn,Error
    }
}

function New-TestPlayniteApi
{
    # Enough of the API for the build loop: variable expansion and media paths.
    return New-Module -AsCustomObject -ScriptBlock {
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
}

function New-TestRoot
{
    # A throwaway directory, plus the extension data path the module expects.
    param([string]$Label = 'nss')
    $root = Join-Path $env:TEMP "$Label`_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $global:CurrentExtensionDataPath = Join-Path $root 'data'
    New-Item -ItemType Directory -Path $global:CurrentExtensionDataPath -Force | Out-Null
    return $root
}

function Remove-TestRoot
{
    param([string]$Root)
    if ($Root) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------- optional real-world state
function Get-RealSteamProfile
{
    <#
        A real Steam userdata profile on this machine, or $null. Used only by
        tests that check the module can read a genuine shortcuts.vdf; they
        skip when there is not one. Read-only, always.
    #>
    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Steam'),
        (Join-Path $env:ProgramFiles 'Steam')
    )
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        try {
            $p = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).SteamPath
            if ($p) { $roots = @($p) + $roots }
        } catch { }
    }
    foreach ($root in $roots) {
        if (-not $root) { continue }
        $userdata = Join-Path $root 'userdata'
        if (-not (Test-Path -LiteralPath $userdata -PathType Container)) { continue }
        foreach ($dir in (Get-ChildItem -LiteralPath $userdata -Directory -ErrorAction SilentlyContinue)) {
            if ($dir.Name -notmatch '^\d+$' -or $dir.Name -eq '0') { continue }
            if (Test-Path -LiteralPath (Join-Path $dir.FullName 'config\shortcuts.vdf') -PathType Leaf) {
                return $dir.FullName
            }
        }
    }
    return $null
}

function Get-RealShortcutsVdf
{
    $profileDir = Get-RealSteamProfile
    if (-not $profileDir) { return $null }
    return (Join-Path $profileDir 'config\shortcuts.vdf')
}

<#
    Runs the whole suite and reports a single pass/fail.

    Must be run under x86 PowerShell, because Playnite.SDK.dll is x86, and with
    -STA for the tests that create real WPF windows:

        C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -STA -ExecutionPolicy Bypass -File tests\run-all.ps1

    Tests needing local state that may not exist - a Steam install, a game
    folder, a Microsoft Store package - report SKIP rather than failing.
#>
param(
    # Run only tests whose name matches, e.g. -Filter test2*
    [string]$Filter = 'test*'
)

$ErrorActionPreference = 'Stop'

if ([IntPtr]::Size -ne 4) {
    Write-Host 'These tests need x86 PowerShell, because Playnite.SDK.dll is x86.' -ForegroundColor Red
    Write-Host 'Run: C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -STA -ExecutionPolicy Bypass -File tests\run-all.ps1' -ForegroundColor Red
    exit 2
}

$files = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter "$Filter.ps1" -File |
           Where-Object { $_.Name -ne 'common.ps1' -and $_.Name -ne 'run-all.ps1' } |
           Sort-Object { [int]($_.BaseName -replace '\D', '') })

$passed = 0
$failed = @()
$skipped = @()

foreach ($f in $files) {
    $output = & "$PSHOME\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File $f.FullName 2>&1
    $text = ($output | Out-String)

    if ($text -match 'ALL TESTS PASSED') {
        $passed++
        Write-Host ('PASS  {0}' -f $f.BaseName) -ForegroundColor Green
    }
    elseif ($text -match '^SKIP:') {
        $skipped += $f.BaseName
        Write-Host ('SKIP  {0}' -f $f.BaseName) -ForegroundColor Yellow
    }
    else {
        $failed += $f.BaseName
        Write-Host ('FAIL  {0}' -f $f.BaseName) -ForegroundColor Red
        $text -split "`r?`n" | Where-Object { $_ -match 'FAIL|Exception|SKIP' } |
            Select-Object -First 8 | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
    }
}

''
"$passed passed, $($failed.Count) failed, $($skipped.Count) skipped"
if ($skipped.Count) { "skipped: $($skipped -join ', ')" }
if ($failed.Count) {
    "failed:  $($failed -join ', ')"
    exit 1
}

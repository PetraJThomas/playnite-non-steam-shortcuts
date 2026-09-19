. "$PSScriptRoot\common.ps1"
$mod = $ModulePath

# A real Microsoft Store package to read an AppxManifest.xml out of. Any
# FullTrust package will do; without one there is nothing to parse.
# Get-AppxPackage rather than listing Program Files\WindowsApps, which is
# ACL'd and comes back empty without elevation.
#
# The two cases this resolver has to tell apart are a package declaring
# Windows.FullTrustApplication, which has a real .exe to point at, and a
# sandboxed UWP one, which can only be shell-activated. Find one of each if
# this machine has them and assert whichever are available, rather than
# pinning the test to one person's installed game.
$fullTrustPkg = $null
$uwpPkg       = $null
try {
    foreach ($pkg in (Get-AppxPackage -ErrorAction Stop)) {
        if (-not $pkg.InstallLocation) { continue }
        $manifest = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
        try { $xml = [xml](Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop) } catch { continue }
        $isFullTrust = $xml.Package.Applications.Application.EntryPoint -contains 'Windows.FullTrustApplication'
        if ($isFullTrust -and -not $fullTrustPkg) { $fullTrustPkg = $pkg }
        elseif (-not $isFullTrust -and -not $uwpPkg) { $uwpPkg = $pkg }
        if ($fullTrustPkg -and $uwpPkg) { break }
    }
} catch { }

$storePackageDir = if ($fullTrustPkg) { $fullTrustPkg.InstallLocation } elseif ($uwpPkg) { $uwpPkg.InstallLocation } else { $null }
if (-not $storePackageDir) {
    Write-Host 'SKIP: no readable Microsoft Store package on this machine' -ForegroundColor Yellow
    exit 0
}
$global:__logger = New-Module -AsCustomObject -ScriptBlock {
    function Info([string]$m){ Write-Host "      [log] $m" -ForegroundColor DarkGray }
    function Warn([string]$m){ Write-Host "      [warn] $m" -ForegroundColor DarkYellow }
    function Error([string]$m){ Write-Host "      [err] $m" -ForegroundColor DarkRed }
    Export-ModuleMember -Function Info,Warn,Error
}
# Snapshot the real shortcuts.vdf so we can prove THIS test did not touch it.
# Pinning a literal hash rots the moment the user legitimately adds a game.
$realVdf  = Get-RealShortcutsVdf
$realHash = if ($realVdf) { (Get-FileHash -LiteralPath $realVdf).Hash } else { $null }
Import-Module $mod -Force -DisableNameChecking
$m=Get-Module NonSteamShortcuts

'--- a FullTrust package resolves to its real Win32 exe ---'
$r = $null
if ($fullTrustPkg) {
    $g = [pscustomobject]@{
        Name             = $fullTrustPkg.Name
        GameId           = $fullTrustPkg.PackageFamilyName
        InstallDirectory = $null      # force the Get-AppxPackage path
        IsInstalled      = $true
    }
    $r = & $m { param($x) Resolve-MicrosoftStoreLaunch $x } $g
    "  package    = $($fullTrustPkg.PackageFamilyName)"
    if ($null -eq $r) { $script:FailCount++; '  FAIL returned null' } else {
        "  Exe        = $($r.Exe)"
        "  WorkingDir = $($r.WorkingDir)"
        Check 'resolved to a real .exe'           ($r.Exe -like '*.exe') 'True'
        Check 'exe actually exists'               (Test-Path -LiteralPath $r.Exe) 'True'
        Check 'not shell activation'              ($r.Exe -like '*explorer.exe') 'False'
        Check 'overlay NOT disabled (full trust)' ([bool]$r.NoOverlay) 'False'
    }

    '--- with InstallDirectory supplied by Playnite (no Appx query) ---'
    $g2 = [pscustomobject]@{
        Name=$fullTrustPkg.Name; GameId=$fullTrustPkg.PackageFamilyName
        InstallDirectory=$fullTrustPkg.InstallLocation; IsInstalled=$true
    }
    $r2 = & $m { param($x) Resolve-MicrosoftStoreLaunch $x } $g2
    Check 'same exe via InstallDirectory' $r2.Exe $r.Exe

    '--- end-to-end through Complete-LaunchSpec ---'
    $spec = & $m { param($x,$l) Complete-LaunchSpec $x $l } $g2 $r2
    Check 'not a url'  $spec.IsUrl 'False'
    $quoted = '"{0}"' -f $spec.Exe
    $appId = & $m { param($e,$n) Get-ShortcutAppId $e $n } $quoted $g2.Name
    Check 'appid in valid range' ($appId -ge 2147483648 -and $appId -le 4294967295) 'True'
} else {
    '  SKIP no FullTrust Store package installed'
}

'--- a sandboxed UWP package is shell-activated, with no overlay ---'
if ($uwpPkg) {
    $g3 = [pscustomobject]@{
        Name=$uwpPkg.Name; GameId=$uwpPkg.PackageFamilyName
        InstallDirectory=$null; IsInstalled=$true
    }
    $r3 = & $m { param($x) Resolve-MicrosoftStoreLaunch $x } $g3
    "  package    = $($uwpPkg.PackageFamilyName)"
    if ($null -eq $r3) { $script:FailCount++; '  FAIL returned null' } else {
        "  Exe        = $($r3.Exe)"
        "  Arguments  = '$($r3.Arguments)'"
        Check 'activated via explorer'   ($r3.Exe -like '*explorer.exe') 'True'
        Check 'uses the AppsFolder verb' ($r3.Arguments -like '*shell:AppsFolder\*') 'True'
        Check 'overlay disabled'         ([bool]$r3.NoOverlay) 'True'
    }
} else {
    '  SKIP no sandboxed UWP package installed'
}

'--- non-Store game is ignored by this resolver ---'
$pc=[pscustomobject]@{ Name='Some PC Game'; GameId='12345'; InstallDirectory='C:\Games'; IsInstalled=$true }
Check 'plain GameId -> null' ($null -eq (& $m { param($g) Resolve-MicrosoftStoreLaunch $g } $pc)) 'True'
$steamish=[pscustomobject]@{ Name='S'; GameId='805550'; InstallDirectory=''; IsInstalled=$true }
Check 'steam appid -> null'  ($null -eq (& $m { param($g) Resolve-MicrosoftStoreLaunch $g } $steamish)) 'True'

'--- fake UWP (no full-trust exe) falls back to shell activation ---'
$fake=[pscustomobject]@{ Name='Fake UWP'; GameId='Contoso.FakeApp_0abcdefghijkl'; InstallDirectory=$null; IsInstalled=$true }
$r3 = & $m { param($g) Resolve-MicrosoftStoreLaunch $g } $fake
Check 'unknown package -> null (not a crash)' ($null -eq $r3) 'True'

'--- regressions ---'
Check 'crc32 vector' ('0x{0:X8}' -f (& $m { Get-Crc32 ([Text.Encoding]::ASCII.GetBytes('123456789')) })) '0xCBF43926'
if ($realVdf) {
    Check 'real vdf untouched by this test' (Get-FileHash -LiteralPath $realVdf).Hash $realHash
} else {
    '  SKIP no real shortcuts.vdf to compare against'
}

Complete-Tests

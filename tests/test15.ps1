. "$PSScriptRoot\common.ps1"
$mod = $ModulePath

# Scans real game folders. NONSTEAM_TEST_GAMEDIR overrides where to look; the
# synthetic cases below run regardless.
$gameRoot = $env:NONSTEAM_TEST_GAMEDIR
if (-not $gameRoot) { $gameRoot = 'G:/Ubisoft' }
$haveRealGames = Test-Path -LiteralPath $gameRoot -PathType Container
if (-not $haveRealGames) {
    "  NOTE no real game folder at $gameRoot - running the synthetic cases only"
}
$global:__logger = New-Module -AsCustomObject -ScriptBlock {
    function Info([string]$m){ Write-Host "      [log] $m" -ForegroundColor DarkGray }
    function Warn([string]$m){}; function Error([string]$m){}
    Export-ModuleMember -Function Info,Warn,Error
}
$global:CurrentExtensionDataPath = Join-Path $env:TEMP "nss_id_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $global:CurrentExtensionDataPath | Out-Null
Import-Module $mod -Force -DisableNameChecking
$m=Get-Module NonSteamShortcuts

function G($name,$dir,$installed=$true){ [pscustomobject]@{ Name=$name; InstallDirectory=$dir; IsInstalled=$installed } }

'--- REAL: Watch Dogs Legion must pick the game, not DXSETUP.exe ---'
$r = $null
if ($haveRealGames) { $r = & $m { param($g) Resolve-InstallDirLaunch $g } (G 'Watch Dogs: Legion' (Join-Path $gameRoot 'Watch Dogs Legion')) }
if (-not $haveRealGames) { '  SKIP no real install folder' }
elseif($null -eq $r){ $script:FailCount++; '  FAIL returned null' } else {
  "  picked: $($r.Exe)"
  Check 'picked the game exe'    ($r.Exe -like '*WatchDogsLegion.exe') 'True'
  Check 'did NOT pick DXSETUP'   ($r.Exe -like '*DXSETUP*') 'False'
  Check 'workdir is the exe dir' ($r.WorkingDir -like '*\bin') 'True'
  Check 'flagged as a guess'     ([bool]$r.Guessed) 'True'
}

'--- REAL Ubisoft installs: picks a game, never an installer ---'
# Whether any given game is installed changes over time, so assert the
# behaviour rather than a snapshot: if the folder holds a real executable we
# must pick a plausible one; if it is only a stub we must pick nothing.
$installerish = 'install','setup','redist','dxsetup','unins','crash','helper'
foreach($n in 'Far Cry 4','Rayman Origins','Watch_Dogs','WATCH_DOGS 2','The Crew 2','Far Cry 3 Blood Dragon'){
  $dir = $gameRoot + '/' + ($n -replace ':','' -replace 'WATCH_DOGS 2','WATCH_DOGS2')
  if(-not (Test-Path -LiteralPath $dir)){ "  skip '$n' (folder absent)"; continue }
  $real = @(Get-ChildItem -LiteralPath $dir -Filter *.exe -Recurse -Depth 3 -ErrorAction SilentlyContinue)
  $res  = & $m { param($g) Resolve-InstallDirLaunch $g } (G $n $dir)
  if($real.Count -eq 0){
    Check "stub '$n' -> null" ($null -eq $res) 'True'
  } else {
    $leaf = if($res){ (Split-Path -Leaf $res.Exe).ToLowerInvariant() } else { '' }
    $bad  = $false
    foreach($w in $installerish){ if($leaf -like "*$w*"){ $bad = $true } }
    Check "'$n' resolved"               ($null -ne $res) 'True'
    Check "'$n' is not an installer"    $bad 'False'
    "        -> $leaf"
  }
}

'--- not installed is refused outright ---'
Check 'IsInstalled=false -> null' ($null -eq (& $m { param($g) Resolve-InstallDirLaunch $g } (G 'X' (Join-Path $gameRoot 'Watch Dogs Legion') $false))) 'True'
Check 'no install dir -> null'    ($null -eq (& $m { param($g) Resolve-InstallDirLaunch $g } (G 'X' ''))) 'True'
Check 'missing dir -> null'       ($null -eq (& $m { param($g) Resolve-InstallDirLaunch $g } (G 'X' 'Q:\nope\nope'))) 'True'

'--- synthetic: name match beats a bigger redistributable ---'
$t = Join-Path $env:TEMP "nss_fake_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path (Join-Path $t 'bin') | Out-Null
New-Item -ItemType Directory -Path (Join-Path $t 'DirectX') | Out-Null
# the "game" is small, the installer is large
[IO.File]::WriteAllBytes((Join-Path $t 'bin\CoolGame.exe'), (New-Object byte[] 1000))
[IO.File]::WriteAllBytes((Join-Path $t 'DirectX\DXSETUP.exe'), (New-Object byte[] 900000))
[IO.File]::WriteAllBytes((Join-Path $t 'vcredist_x64.exe'), (New-Object byte[] 800000))
[IO.File]::WriteAllBytes((Join-Path $t 'UnityCrashHandler64.exe'), (New-Object byte[] 500000))
$r2 = & $m { param($g) Resolve-InstallDirLaunch $g } (G 'Cool Game' $t)
"  picked: $(Split-Path -Leaf $r2.Exe)"
Check 'name match wins over size' (Split-Path -Leaf $r2.Exe) 'CoolGame.exe'

'--- synthetic: only junk present -> null, not a bad guess ---'
$t2 = Join-Path $env:TEMP "nss_junk_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $t2 | Out-Null
[IO.File]::WriteAllBytes((Join-Path $t2 'unins000.exe'), (New-Object byte[] 100))
[IO.File]::WriteAllBytes((Join-Path $t2 'vc_redist.x86.exe'), (New-Object byte[] 100))
Check 'only excluded exes -> null' ($null -eq (& $m { param($g) Resolve-InstallDirLaunch $g } (G 'Junk' $t2))) 'True'

'--- single non-excluded exe is taken even if the name differs ---'
$t3 = Join-Path $env:TEMP "nss_one_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $t3 | Out-Null
[IO.File]::WriteAllBytes((Join-Path $t3 'Totally Different.exe'), (New-Object byte[] 100))
Check 'lone exe is used' (Split-Path -Leaf (& $m { param($g) Resolve-InstallDirLaunch $g } (G 'Some Game' $t3)).Exe) 'Totally Different.exe'

'--- the chain and reporting are wired ---'
$src = Get-Content -LiteralPath $mod -Raw
Check 'in the resolution chain' ($src -like '*$raw = Resolve-InstallDirLaunch $game*') 'True'
Check 'guessed games reported'  ($src -like '*found by scanning the install folder*') 'True'

Remove-Item $t,$t2,$t3 -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $global:CurrentExtensionDataPath -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests

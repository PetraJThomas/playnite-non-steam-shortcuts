. "$PSScriptRoot\common.ps1"
$mod = $ModulePath
$global:__logger = New-Module -AsCustomObject -ScriptBlock {
    function Info([string]$m){}; function Warn([string]$m){}; function Error([string]$m){}
    Export-ModuleMember -Function Info,Warn,Error
}
$root = Join-Path $env:TEMP "nss_t22_$([guid]::NewGuid().ToString('N'))"
$global:CurrentExtensionDataPath = Join-Path $root 'data'
New-Item -ItemType Directory -Path $global:CurrentExtensionDataPath -Force | Out-Null
Import-Module $mod -Force -DisableNameChecking
$m = Get-Module NonSteamShortcuts

function New-Action($name, $path, $isPlay) {
    [pscustomobject]@{ Name=$name; Path=$path; Arguments=''; WorkingDir='C:\g'; IsPlayAction=$isPlay; Type=[Playnite.SDK.Models.GameActionType]::File }
}
function New-Game($acts) { [pscustomobject]@{ Name='A Game'; Id=[guid]::NewGuid(); GameActions=$acts } }

'=== a secondary action must never become the launch target ==='
# The real case: an Epic/GOG game whose play action comes from the plugin at
# launch, where the user has added a "Configure" entry in Playnite. Taking it
# would point the Steam shortcut at the config tool AND stop the plugin from
# ever being asked.
$configOnly = New-Game @((New-Action 'Configure' 'C:\Games\MyGame\settings\Config.exe' $false))
$picked = & $m { param($g) Get-SourcePlayAction $g } $configOnly
Check 'a lone Configure is refused' ($null -eq $picked) 'True'

$saveFolder = New-Game @((New-Action 'Open save folder' 'C:\Users\x\Saves' $false))
Check 'a lone folder action refused' ($null -eq (& $m { param($g) Get-SourcePlayAction $g } $saveFolder)) 'True'

'=== but a real play action is still used ==='
$withPlay = New-Game @(
    (New-Action 'Configure' 'C:\Games\MyGame\settings\Config.exe' $false),
    (New-Action 'Play' 'C:\Games\MyGame\game.exe' $true)
)
$picked2 = & $m { param($g) Get-SourcePlayAction $g } $withPlay
Check 'the play action wins'     $picked2.Path 'C:\Games\MyGame\game.exe'

'=== and so is the action stashed by a previous run ==='
$stashed = New-Game @(
    (New-Action 'Configure' 'C:\Games\MyGame\settings\Config.exe' $false),
    (New-Action 'Launch without Steam' 'C:\Games\MyGame\game.exe' $false)
)
$picked3 = & $m { param($g) Get-SourcePlayAction $g } $stashed
Check 'the stashed action wins'  $picked3.Path 'C:\Games\MyGame\game.exe'

'=== a game with no actions at all is still null ==='
Check 'no actions -> null' ($null -eq (& $m { param($g) Get-SourcePlayAction $g } (New-Game @()))) 'True'

'=== a plaintext key is cleared even when an encrypted one exists ==='
# The old code only looked for the legacy file when the encrypted one was
# missing, so a delete that failed once left the key readable forever.
$legacy = & $m { Get-SteamGridDbLegacyKeyPath }
$enc    = & $m { Get-SteamGridDbKeyPath }
& $m { param($k) Save-SteamGridDbApiKey $k } 'ENCRYPTED-KEY'
[IO.File]::WriteAllText($legacy, 'PLAINTEXT-KEY-FROM-OLD-VERSION')
Check 'both files present to start' ((Test-Path $legacy) -and (Test-Path $enc)) 'True'

# Force a fresh load, the way a module reload would.
& $m { $script:SgdbKeyLoaded = $false; $script:SgdbKey = $null }
$got = & $m { Get-SteamGridDbApiKey }
Check 'encrypted key still wins'    $got 'ENCRYPTED-KEY'
Check 'plaintext file was removed'  (Test-Path -LiteralPath $legacy) 'False'

'=== and is adopted when there is no encrypted key yet ==='
Remove-Item -LiteralPath $enc -Force -ErrorAction SilentlyContinue
[IO.File]::WriteAllText($legacy, 'ONLY-PLAINTEXT')
& $m { $script:SgdbKeyLoaded = $false; $script:SgdbKey = $null }
$got2 = & $m { Get-SteamGridDbApiKey }
Check 'adopted the plaintext key'   $got2 'ONLY-PLAINTEXT'
Check 'now stored encrypted'        (Test-Path -LiteralPath $enc) 'True'
Check 'plaintext gone'              (Test-Path -LiteralPath $legacy) 'False'
Check 'and it is not readable'      ([IO.File]::ReadAllText($enc).Contains('ONLY-PLAINTEXT')) 'False'

'=== an unreadable launch target is reported, not just logged ==='
$src = Get-Content -LiteralPath $mod -Raw
Check 'bucket exists'      ($src -like '*$unreadableTargets.Add($game.Name)*') 'True'
Check 'and is reported'    ($src -like '*their file could not be read*') 'True'

'=== the pext ships only what Playnite needs ==='
$attrs = Get-Content -LiteralPath (Join-Path $RepoRoot '.gitattributes') -Raw
foreach ($d in '.github','legacy') {
    Check "  $d is export-ignored" ($attrs -like "*$d*export-ignore*") 'True'
}

Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests

. "$PSScriptRoot\common.ps1"
$mod = $ModulePath
# The "use Playnite artwork" entries exist because SteamGridDB matches on the
# game's name and sometimes picks the wrong game. If they consulted it at all
# they would not solve the problem they were added for.

$global:__logger = New-Module -AsCustomObject -ScriptBlock {
    function Info([string]$m){}; function Warn([string]$m){}; function Error([string]$m){}
    Export-ModuleMember -Function Info,Warn,Error
}
$root = Join-Path $env:TEMP "nss_art_$([guid]::NewGuid().ToString('N'))"
$global:CurrentExtensionDataPath = Join-Path $root 'data'
$grid = Join-Path $root 'grid'
$media = Join-Path $root 'media'
New-Item -ItemType Directory -Path $global:CurrentExtensionDataPath,$grid,$media -Force | Out-Null
$global:PlayniteApi = New-Module -AsCustomObject -ScriptBlock {
    function ExpandGameVariables { param($game, $action) return $action }
    $Database = New-Module -AsCustomObject -ScriptBlock {
        function GetFullFilePath { param($p) return $p }
        Export-ModuleMember -Function GetFullFilePath
    }
    $Addons = New-Module -AsCustomObject -ScriptBlock { $Plugins = @(); Export-ModuleMember -Variable Plugins }
    Export-ModuleMember -Function ExpandGameVariables -Variable Database,Addons
}
Import-Module $mod -Force -DisableNameChecking
$m = Get-Module NonSteamShortcuts

$exe = Join-Path $env:WINDIR 'explorer.exe'
function New-Game($name, $cover) {
    $act = [pscustomobject]@{ Name='Play'; Path=$exe; Arguments=''; WorkingDir=(Split-Path -Parent $exe); IsPlayAction=$true; Type=[Playnite.SDK.Models.GameActionType]::File }
    [pscustomobject]@{
        Name=$name; Id=[guid]::NewGuid(); GameId='x'; PluginId=[Guid]::Empty; IsInstalled=$true
        InstallDirectory=(Split-Path -Parent $exe); Icon=$null; CoverImage=$cover; BackgroundImage=$null
        Categories=$null; GameActions=@($act)
    }
}

'--- the menu offers the four entries, in order ---'
$items = @(& $m { GetGameMenuItems $null })
Check 'four game menu items' $items.Count 4
$i = 0
foreach ($it in $items) { "     $i. $($it.Description)"; $i++ }
Check '1 is the plain create'   ($items[0].Description) 'Create non-Steam shortcuts'
Check '2 is playnite artwork'   ($items[1].Description -like '*Playnite artwork*') 'True'
Check '3 is the rebuild'        ($items[2].Description) 'Replace ALL non-Steam shortcuts with the selected games'
Check '4 is rebuild + playnite' ($items[3].Description -like '*Playnite artwork*') 'True'
Check 'all in one section'      (@($items | Where-Object { $_.MenuSection -eq '@Non-Steam Shortcuts' }).Count) 4

'--- every entry points at a function that exists ---'
foreach ($it in $items) {
    $fn = & $m { param($n) Get-Command $n -ErrorAction SilentlyContinue } $it.FunctionName
    Check "  $($it.FunctionName) exists" ($null -ne $fn) 'True'
}

'--- the Playnite-only wrappers ask for exactly the right flags ---'
$src = Get-Content -LiteralPath $mod -Raw
Check 'create uses ReplaceArt+PlayniteArtOnly' ($src -like '*$scriptGameMenuItemActionArgs -ReplaceArt -PlayniteArtOnly*') 'True'
Check 'rebuild adds ReplaceAll'                ($src -like '*$scriptGameMenuItemActionArgs -ReplaceArt -ReplaceAll -PlayniteArtOnly*') 'True'

'--- SteamGridDB is never called when Playnite artwork was asked for ---'
# A cover Playnite does have, so there is something to copy.
$cover = Join-Path $media 'cover.png'
[IO.File]::WriteAllBytes($cover, (New-Object byte[] 128))
$withCover = New-Game 'Has A Cover' $cover
# And one it does not, which is the case that would otherwise fall through.
$without  = New-Game 'No Cover At All' $null

$calls = 0
$r = & $m {
    param($games, $gd)
    # Fail loudly if the SteamGridDB path is entered at all.
    function Copy-SteamGridDbArt {
        param([string]$GridDir, [long]$AppId, [string]$Name, [switch]$Overwrite, $Progress)
        throw "SteamGridDB was consulted for '$Name' despite -PlayniteArtOnly"
    }
    Invoke-ShortcutBuild -Games $games -GridDir $gd `
        -SteamShortcuts (New-Object 'System.Collections.Generic.List[object]') `
        -ReplaceArt -PlayniteArtOnly -Progress $null
} @($withCover, $without) $grid

Check 'both games built'            $r.GamesNew 2
Check 'nothing was misreported'     $r.SkippedUnresolvable.Count 0
Check 'the covered game got art'    ($r.ArtCopied -ge 1) 'True'
Check 'the bare one is reported'    ($r.NoArtworkGames -contains 'No Cover At All') 'True'
Check 'the covered one is not'      ($r.NoArtworkGames -contains 'Has A Cover') 'False'

'--- without the switch, SteamGridDB IS consulted ---'
$grid2 = Join-Path $root 'grid2'
New-Item -ItemType Directory -Path $grid2 | Out-Null
$reached = $false
$r2 = & $m {
    param($games, $gd)
    function Copy-SteamGridDbArt {
        param([string]$GridDir, [long]$AppId, [string]$Name, [switch]$Overwrite, $Progress)
        $global:sgdbReached = $true
        return 0
    }
    Invoke-ShortcutBuild -Games $games -GridDir $gd `
        -SteamShortcuts (New-Object 'System.Collections.Generic.List[object]') -Progress $null
} @($without) $grid2
Check 'fallback still happens normally' ([bool]$global:sgdbReached) 'True'

'--- the summary does not suggest a key when the user chose Playnite ---'
Check 'advice is conditional' ($src -like '*if ($PlayniteArtOnly) {*') 'True'
Check 'and says what to do'   ($src -like "*Give them a cover in Playnite and run this again*") 'True'

Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests

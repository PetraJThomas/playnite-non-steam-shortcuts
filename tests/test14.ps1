. "$PSScriptRoot\common.ps1"
$mod = $ModulePath
$global:__logger = New-Module -AsCustomObject -ScriptBlock { function Info($m){}; function Warn($m){}; function Error($m){}; Export-ModuleMember -Function Info,Warn,Error }
$global:CurrentExtensionDataPath = Join-Path $env:TEMP "nss_ra_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $global:CurrentExtensionDataPath | Out-Null

# Fake dialogs. Records the warning text and returns whichever option we choose.
$global:chooseTitle = ''
$global:lastMessage = ''
$global:PlayniteApi = New-Module -AsCustomObject -ScriptBlock {
    $Dialogs = New-Module -AsCustomObject -ScriptBlock {
        function ShowMessage {
            param($text,$caption,$icon,$options)
            $global:lastMessage = $text
            if ($options) { foreach ($o in $options) { if ($o.Title -eq $global:chooseTitle) { return $o } } ; return $options[0] }
            return [System.Windows.MessageBoxResult]::OK
        }
        function ShowErrorMessage { param($a,$b) }
        Export-ModuleMember -Function ShowMessage,ShowErrorMessage
    }
    Export-ModuleMember -Variable Dialogs
}
Import-Module $mod -Force -DisableNameChecking
$m=Get-Module NonSteamShortcuts

# a vdf with three existing shortcuts, none of them ours
$tmp = Join-Path $env:TEMP "nss_ra_$([guid]::NewGuid().ToString('N')).vdf"
$lst = New-Object 'System.Collections.Generic.List[object]'
foreach($n in 'EmuDeck Thing','Hand Made','Other Tool'){
  $lst.Add([ordered]@{ 'appid'=[int]-500; 'appname'=$n; 'exe'='"x.exe"'; 'startdir'='""'; 'icon'=''; 'launchoptions'=''; 'devkitgameid'=''; 'tags'=[ordered]@{} })
}
& $m { param($p,$s) Write-ShortcutsVdf $p $s } $tmp $lst
Check 'three existing shortcuts staged' (& $m { param($p) Read-ShortcutsVdf $p } $tmp).Count 3

'--- the warning states the consequence plainly ---'
$global:chooseTitle = 'No, leave my shortcuts alone'
$r = & $m { param($p,$c) Confirm-ReplaceAllShortcuts $p $c } $tmp 7
"  message:"
($global:lastMessage -split "`r?`n") | Where-Object { $_ } | ForEach-Object { "     $_" }
Check 'says it will overwrite'        ($global:lastMessage -like '*completely rewrite and overwrite*') 'True'
Check 'counts what will be destroyed' ($global:lastMessage -like '*3 non-Steam shortcut(s)*') 'True'
Check 'counts the replacements'       ($global:lastMessage -like '*7 game(s)*') 'True'
Check 'warns about outside changes'   ($global:lastMessage -like '*those changes will be lost*') 'True'
Check 'mentions the backup'           ($global:lastMessage -like '*backup*') 'True'

'--- choosing No returns false (nothing happens) ---'
Check 'No -> false' $r 'False'

'--- choosing Yes returns true ---'
$global:chooseTitle = 'Yes, replace everything'
Check 'Yes -> true' (& $m { param($p,$c) Confirm-ReplaceAllShortcuts $p $c } $tmp 7) 'True'

'--- No is the default and the cancel option (safe if dismissed) ---'
$src = Get-Content -LiteralPath $mod -Raw
Check 'No is default+cancel' ($src -like "*MessageBoxOption('No, leave my shortcuts alone', `$true, `$true)*") 'True'
Check 'Yes is neither'       ($src -like "*MessageBoxOption('Yes, replace everything', `$false, `$false)*") 'True'

'--- the read is skipped entirely when replacing all ---'
Check 'read is in an else branch' ($src -like '*Deliberately do NOT read the existing file*') 'True'
$region = [regex]::Match($src, '(?s)if \(\$ReplaceAll\) \{.*?\n        \}\r?\n        else \{').Success
Check 'ReplaceAll block is followed by else' $region 'True'

'--- menu now has three game entries ---'
$items = @(& $m { GetGameMenuItems $null })
# Four now: plain create and rebuild, each with a 'use Playnite artwork'
# counterpart for overruling a bad SteamGridDB match.
Check 'four game menu items' $items.Count 4
Check 'has the replace-all entry' ($items.Description -contains 'Replace ALL non-Steam shortcuts with the selected games') 'True'

Remove-Item $tmp -Force -ErrorAction SilentlyContinue
Remove-Item $global:CurrentExtensionDataPath -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests

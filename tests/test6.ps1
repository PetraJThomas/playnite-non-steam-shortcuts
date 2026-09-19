. "$PSScriptRoot\common.ps1"
$mod = $ModulePath

# Playnite injects $__logger into the runspace; stub it for standalone runs.
$global:__logger = New-Module -AsCustomObject -ScriptBlock {
    function Info([string]$m){}; function Warn([string]$m){}; function Error([string]$m){}
    Export-ModuleMember -Function Info,Warn,Error
}

# Snapshot the real shortcuts.vdf so we can prove THIS test did not touch it.
# Pinning a literal hash rots the moment the user legitimately adds a game.
$realVdf  = Get-RealShortcutsVdf
$realHash = if ($realVdf) { (Get-FileHash -LiteralPath $realVdf).Hash } else { $null }
Import-Module $mod -Force -DisableNameChecking
$m=Get-Module NonSteamShortcuts

'--- encoding: dialog text is ASCII and decodes identically either way ---'
$b=[IO.File]::ReadAllBytes($mod)
$utf8=[Text.Encoding]::UTF8.GetString($b); $ansi=[Text.Encoding]::GetEncoding(1252).GetString($b)
$r=[regex]'Nothing to do (.{1,8}?) shortcuts\.vdf'
Check 'UTF8 decode'  ($r.Match($utf8).Groups[1].Value) '-'
Check 'cp1252 decode' ($r.Match($ansi).Groups[1].Value) '-'

'--- new function exists and is exported ---'
$cmds=(Get-Command -Module NonSteamShortcuts).Name
foreach($f in 'Resolve-LibraryPluginLaunch','Complete-LaunchSpec'){ Check "exported: $f" ($cmds -contains $f) 'True' }

'--- Complete-LaunchSpec behaviour ---'
$g=[pscustomobject]@{Name='G'}
$r1 = & $m { param($g,$l) Complete-LaunchSpec $g $l } $g @{Exe='C:\games\x\g.exe';Arguments='-w';WorkingDir='';IsUrl=$false}
Check 'derives workdir from rooted exe' $r1.StartDir 'C:\games\x'
Check 'keeps exe'                        $r1.Exe     'C:\games\x\g.exe'
Check 'keeps args'                       $r1.Arguments '-w'
Check 'not url'                          $r1.IsUrl   'False'

$r2 = & $m { param($g,$l) Complete-LaunchSpec $g $l } $g @{Exe='uplay://launch/123/0';Arguments='';WorkingDir='';IsUrl=$true}
Check 'url passes through'   $r2.Exe   'uplay://launch/123/0'
Check 'url flagged'          $r2.IsUrl 'True'
Check 'url has empty startdir' ($r2.StartDir -eq '') 'True'

$r3 = & $m { param($g,$l) Complete-LaunchSpec $g $l } $g @{Exe='steam://rungameid/17886490569509699584';Arguments='';WorkingDir='';IsUrl=$true}
Check 'rejects self-referential steam url' ($null -eq $r3) 'True'

$r4 = & $m { param($g,$l) Complete-LaunchSpec $g $l } $g @{Exe='relative.exe';Arguments='';WorkingDir='';IsUrl=$false}
Check 'rejects relative exe with no workdir' ($null -eq $r4) 'True'

$r5 = & $m { param($g,$l) Complete-LaunchSpec $g $l } $g $null
Check 'null launch -> null' ($null -eq $r5) 'True'

$r6 = & $m { param($g,$l) Complete-LaunchSpec $g $l } $g @{Exe='';Arguments='';WorkingDir='C:\x';IsUrl=$false}
Check 'empty exe -> null' ($null -eq $r6) 'True'

'--- relative exe WITH a workdir is rooted correctly ---'
$r7 = & $m { param($g,$l) Complete-LaunchSpec $g $l } $g @{Exe='bin\game.exe';Arguments='';WorkingDir='C:\games\y';IsUrl=$false}
Check 'combines workdir + relative exe' $r7.Exe 'C:\games\y\bin\game.exe'

'--- regressions ---'
Check 'crc32 vector' ('0x{0:X8}' -f (& $m { Get-Crc32 ([Text.Encoding]::ASCII.GetBytes('123456789')) })) '0xCBF43926'
$c = & $m { Find-SteamUserdataDirs }
Check 'userdata still string[]' ($c -is [string[]]) 'True'
Check 'no type name in join' ((($c -join '|') -like '*System.*')) 'False'
if ($realVdf) {
    Check 'real vdf untouched by this test' (Get-FileHash -LiteralPath $realVdf).Hash $realHash
} else {
    '  SKIP no real shortcuts.vdf to compare against'
}

Complete-Tests

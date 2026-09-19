. "$PSScriptRoot\common.ps1"
$mod = $ModulePath
$global:__logger = New-Module -AsCustomObject -ScriptBlock {
    function Info([string]$m){ Write-Host "      [log] $m" -ForegroundColor DarkGray }
    function Warn([string]$m){ Write-Host "      [warn] $m" -ForegroundColor DarkYellow }
    function Error([string]$m){}
    Export-ModuleMember -Function Info,Warn,Error
}
$global:CurrentExtensionDataPath = Join-Path $env:TEMP "nss_key_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $global:CurrentExtensionDataPath | Out-Null
Import-Module $mod -Force -DisableNameChecking
$m=Get-Module NonSteamShortcuts

$secret = 'sgdb_live_abc123SECRETkey456xyz'

'--- save, then confirm the secret is NOT in the file ---'
& $m { param($k) Save-SteamGridDbApiKey $k } $secret
$file = & $m { Get-SteamGridDbKeyPath }
"  file: $(Split-Path -Leaf $file)"
$raw = Get-Content -LiteralPath $file -Raw
"  contents start: $($raw.Substring(0,[Math]::Min(44,$raw.Length)))..."
Check 'file exists'                    (Test-Path $file) 'True'
Check 'secret NOT present in plaintext' ($raw -like "*$secret*") 'False'
Check 'no fragment of it either'        ($raw -like '*SECRET*') 'False'
Check 'is base64 DPAPI blob'            ($raw.Trim() -match '^[A-Za-z0-9+/=\r\n]+$') 'True'
Check 'file extension is .dat'          ([IO.Path]::GetExtension($file)) '.dat'

'--- read it back in a fresh module load ---'
Import-Module $mod -Force -DisableNameChecking
$m=Get-Module NonSteamShortcuts
Check 'decrypts to the original' (& $m { Get-SteamGridDbApiKey }) $secret

'--- a tampered / foreign blob fails safely, no exception ---'
Set-Content -LiteralPath $file -Value ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('not a dpapi blob'))) -Encoding UTF8
Import-Module $mod -Force -DisableNameChecking
$m=Get-Module NonSteamShortcuts
Check 'undecryptable -> null (no throw)' ($null -eq (& $m { Get-SteamGridDbApiKey })) 'True'

'--- migration: a plaintext key from an older version ---'
Remove-Item -LiteralPath $file -Force
$legacy = & $m { Get-SteamGridDbLegacyKeyPath }
Set-Content -LiteralPath $legacy -Value $secret -Encoding UTF8
Check 'legacy plaintext staged' (Get-Content -LiteralPath $legacy -Raw).Trim() $secret
Import-Module $mod -Force -DisableNameChecking
$m=Get-Module NonSteamShortcuts
Check 'migrated value is correct'   (& $m { Get-SteamGridDbApiKey }) $secret
Check 'encrypted file now exists'   (Test-Path $file) 'True'
Check 'plaintext file is gone'      (Test-Path $legacy) 'False'
Check 'secret gone from disk'       ((Get-Content -LiteralPath $file -Raw) -like "*$secret*") 'False'

'--- clearing removes both files ---'
& $m { Remove-SteamGridDbApiKey }
Check 'encrypted removed' (Test-Path $file)   'False'
Check 'legacy removed'    (Test-Path $legacy) 'False'
Check 'key is null'       ($null -eq (& $m { Get-SteamGridDbApiKey })) 'True'

'--- nothing sensitive left anywhere in the data folder ---'
$hits = @(Get-ChildItem $global:CurrentExtensionDataPath -Recurse -File | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -like "*$secret*" })
Check 'no file contains the secret' $hits.Count 0

Remove-Item $global:CurrentExtensionDataPath -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests

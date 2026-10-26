param(
    [string]$Version = (Get-Date -Format "yyyy.MM.dd-HHmmss"),
    [string]$OutputRoot = "validator_release",
    [string]$ValidatorSource = "validator",
    [string]$KeyringSource = ""
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8 = [System.Text.UTF8Encoding]::new($false)
if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $Version.Contains('..') -or $Version -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$') {
    throw "Version must be a safe immutable release label."
}
if ([string]::IsNullOrWhiteSpace($KeyringSource)) { $KeyringSource = Join-Path $ValidatorSource "keyring.json" }
$releaseRoot = [IO.Path]::GetFullPath($OutputRoot)
$releaseDir = [IO.Path]::GetFullPath((Join-Path $releaseRoot $Version))
if ((Split-Path -Parent $releaseDir) -ne $releaseRoot) { throw "Release path escaped output root" }
$zipPath = "$releaseDir.zip"
if ((Test-Path -LiteralPath $releaseDir) -or (Test-Path -LiteralPath $zipPath)) {
    throw "This version already exists. Use a new label; published bundles are immutable."
}
foreach ($name in @("index.html", "noble-ed25519.js", "public_key.txt")) {
    if (-not (Test-Path -LiteralPath (Join-Path $ValidatorSource $name) -PathType Leaf)) { throw "Missing public validator asset: $name" }
}
if (-not (Test-Path -LiteralPath $KeyringSource -PathType Leaf)) { throw "An explicit public keyring with historical keys is required" }
$html = [IO.File]::ReadAllText((Join-Path $ValidatorSource "index.html"))
if ($html -match '<script[^>]+src=["'']https?://' -or $html -match '@import\s+url\(["'']?https?://') {
    throw "Offline validator must not load external scripts or styles"
}
$publicKey = [IO.File]::ReadAllText((Join-Path $ValidatorSource "public_key.txt")).Trim()
$inputRing = [IO.File]::ReadAllText($KeyringSource) | ConvertFrom-Json
$seenKids = @{}
$publicKeys = @()
foreach ($key in $inputRing.keys) {
    if ([string]::IsNullOrWhiteSpace($key.kid) -or $seenKids.ContainsKey($key.kid)) { throw "Missing or duplicate public key ID" }
    $seenKids[$key.kid] = $true
    $rawKey = [Convert]::FromBase64String($key.public_key_base64.Replace('-', '+').Replace('_', '/'))
    if ($rawKey.Length -ne 32) { throw "Invalid Ed25519 public key: $($key.kid)" }
    if ($key.status -notin @('active', 'retired', 'pending')) { throw "Invalid public key status" }
    $publicKeys += [ordered]@{ kid=$key.kid; public_key_base64=$key.public_key_base64; status=$key.status }
}
if (-not ($publicKeys | Where-Object { $_.public_key_base64 -eq $publicKey })) { throw "public_key.txt is absent from the public keyring" }
New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
foreach ($name in @("index.html", "noble-ed25519.js", "public_key.txt")) {
    Copy-Item -LiteralPath (Join-Path $ValidatorSource $name) -Destination $releaseDir
}
$publicRing = [ordered]@{ version="1.0"; keys=$publicKeys }
if ($inputRing.PSObject.Properties['active_kid']) { $publicRing['active_kid'] = $inputRing.active_kid }
[IO.File]::WriteAllText((Join-Path $releaseDir 'keyring.json'), ($publicRing | ConvertTo-Json -Depth 8), $utf8)
$manifestFiles = @()
foreach ($name in @('index.html','keyring.json','noble-ed25519.js','public_key.txt')) {
    $file = Get-Item -LiteralPath (Join-Path $releaseDir $name)
    if ([IO.File]::ReadAllText($file.FullName) -match '-----BEGIN [A-Z ]*PRIVATE KEY-----') { throw "Private material found in public bundle" }
    $manifestFiles += [ordered]@{ path=$name; size=$file.Length; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$manifest = [ordered]@{
    version=$Version
    generatedAt=(Get-Date).ToUniversalTime().ToString('o')
    sourceCommit=$env:GITHUB_SHA
    authoritativePagesUrl='https://artemyx-datascientist.github.io/CIIJournalValidator/'
    files=$manifestFiles
    supportedPayloads=@('v3','v3-draft')
    offlineCapabilities=@{ zeroExternalDependencies=$true; supportsSnapshotVerification=$true; localHttpRequired=$true }
}
[IO.File]::WriteAllText((Join-Path $releaseDir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 8), $utf8)
$checksums = @()
foreach ($name in @('index.html','keyring.json','manifest.json','noble-ed25519.js','public_key.txt')) {
    $digest = (Get-FileHash -LiteralPath (Join-Path $releaseDir $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksums += "$digest  $name"
}
[IO.File]::WriteAllText((Join-Path $releaseDir 'SHA256SUMS.txt'), (($checksums -join [char]10) + [char]10), $utf8)
Compress-Archive -Path (Join-Path $releaseDir '*') -DestinationPath $zipPath
Write-Host "Validator release: $Version"
Write-Host "Directory: $releaseDir"
Write-Host "Archive: $zipPath"
Write-Host "ZIP SHA-256: $((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant())"

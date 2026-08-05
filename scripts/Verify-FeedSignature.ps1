param(
    [string] $FeedPath = (Join-Path $PSScriptRoot '..\feed\updates.json'),
    [string] $SignaturePath = (Join-Path $PSScriptRoot '..\feed\updates.sig'),
    [string] $PublicKeyPath = (Join-Path $PSScriptRoot '..\feed\public-key.txt')
)

$ErrorActionPreference = 'Stop'

$publicKey = [Convert]::FromBase64String(
    (Get-Content -LiteralPath $PublicKeyPath -Raw -Encoding utf8).Trim())
$signature = [Convert]::FromBase64String(
    (Get-Content -LiteralPath $SignaturePath -Raw -Encoding utf8).Trim())

$ecdsa = [System.Security.Cryptography.ECDsa]::Create()
try {
    $bytesRead = 0
    $ecdsa.ImportSubjectPublicKeyInfo($publicKey, [ref] $bytesRead)
    $valid = $ecdsa.VerifyData(
        [System.IO.File]::ReadAllBytes((Resolve-Path $FeedPath).Path),
        $signature,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.DSASignatureFormat]::IeeeP1363FixedFieldConcatenation)
}
finally {
    $ecdsa.Dispose()
}

if (-not $valid) {
    throw 'Feed signature verification failed.'
}

Write-Host 'Feed signature OK.'

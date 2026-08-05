param(
    [string] $FeedPath = (Join-Path $PSScriptRoot '..\feed\updates.json'),
    [string] $SignaturePath = (Join-Path $PSScriptRoot '..\feed\updates.sig'),
    [string] $PrivateKeyPem = $env:FEED_SIGNING_KEY_PEM
)

$ErrorActionPreference = 'Stop'

if (-not $PrivateKeyPem) {
    throw 'FEED_SIGNING_KEY_PEM is not configured.'
}

$feed = (Resolve-Path $FeedPath).Path
$ecdsa = [System.Security.Cryptography.ECDsa]::Create()
try {
    $ecdsa.ImportFromPem($PrivateKeyPem)
    $signature = $ecdsa.SignData(
        [System.IO.File]::ReadAllBytes($feed),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.DSASignatureFormat]::IeeeP1363FixedFieldConcatenation)
    [System.IO.File]::WriteAllText(
        $SignaturePath,
        [Convert]::ToBase64String($signature) + "`n",
        [System.Text.UTF8Encoding]::new($false))
}
finally {
    $ecdsa.Dispose()
}

Write-Host "Signed $feed."

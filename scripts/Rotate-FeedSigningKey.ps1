param(
    [Parameter(Mandatory)] [string] $ConfigXRepository,
    [string] $GitHubRepository = 'MattNorthOfficial/configx-update-feed',
    [switch] $ConfirmRotation
)

$ErrorActionPreference = 'Stop'

if (-not $ConfirmRotation) {
    throw 'Key rotation changes the trust root for every client. Re-run with -ConfirmRotation.'
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI is required to store the private key as an Actions secret.'
}

$feedRoot = Split-Path $PSScriptRoot
$configData = Join-Path $ConfigXRepository 'Data'
$curve = [System.Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP256')
$ecdsa = [System.Security.Cryptography.ECDsa]::Create($curve)

try {
    $privateKey = $ecdsa.ExportPkcs8PrivateKeyPem()
    $privateKey | gh secret set FEED_SIGNING_KEY_PEM --repo $GitHubRepository
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not store FEED_SIGNING_KEY_PEM in GitHub Actions.'
    }

    $publicKey = [Convert]::ToBase64String($ecdsa.ExportSubjectPublicKeyInfo())
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText(
        (Join-Path $feedRoot 'feed\public-key.txt'), $publicKey + "`n", $utf8)
    [System.IO.File]::WriteAllText(
        (Join-Path $configData 'feed-public-key.txt'), $publicKey + "`n", $utf8)

    function Write-Signature([string] $dataPath, [string] $signaturePath) {
        $signature = $ecdsa.SignData(
            [System.IO.File]::ReadAllBytes($dataPath),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.DSASignatureFormat]::IeeeP1363FixedFieldConcatenation)
        [System.IO.File]::WriteAllText(
            $signaturePath, [Convert]::ToBase64String($signature) + "`n", $utf8)
    }

    Write-Signature `
        (Join-Path $feedRoot 'feed\updates.json') `
        (Join-Path $feedRoot 'feed\updates.sig')
    Write-Signature `
        (Join-Path $configData 'updates.json') `
        (Join-Path $configData 'updates.sig')

    $fingerprint = [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData(
            $ecdsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant()
    Write-Host "Feed signing key rotated. Public-key SHA-256: $fingerprint"
}
finally {
    $privateKey = $null
    $ecdsa.Dispose()
}

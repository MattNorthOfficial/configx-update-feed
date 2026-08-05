$ErrorActionPreference = 'Stop'

$work = Join-Path ([System.IO.Path]::GetTempPath()) "configx-sign-test-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $work | Out-Null
$curve = [System.Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP256')
$ecdsa = [System.Security.Cryptography.ECDsa]::Create($curve)

try {
    $publicPath = Join-Path $work 'public-key.txt'
    $signaturePath = Join-Path $work 'updates.sig'
    [System.IO.File]::WriteAllText(
        $publicPath,
        [Convert]::ToBase64String($ecdsa.ExportSubjectPublicKeyInfo()) + "`n",
        [System.Text.UTF8Encoding]::new($false))

    & (Join-Path $PSScriptRoot 'Sign-Feed.ps1') `
        -FeedPath (Join-Path $PSScriptRoot '..\feed\updates.json') `
        -SignaturePath $signaturePath `
        -PrivateKeyPem $ecdsa.ExportPkcs8PrivateKeyPem()
    & (Join-Path $PSScriptRoot 'Verify-FeedSignature.ps1') `
        -FeedPath (Join-Path $PSScriptRoot '..\feed\updates.json') `
        -SignaturePath $signaturePath `
        -PublicKeyPath $publicPath

    Write-Host 'Feed signing round-trip test passed.'
}
finally {
    $ecdsa.Dispose()
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

param(
    [string] $Path = (Join-Path $PSScriptRoot '..\feed\updates.json'),
    [switch] $SkipSignature
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FeedContract.psm1') -Force

$resolved = (Resolve-Path $Path).Path
$feed = Get-Content -LiteralPath $resolved -Raw -Encoding utf8 | ConvertFrom-Json
Assert-FeedContract $feed | Out-Null
if (-not $SkipSignature) {
    & (Join-Path $PSScriptRoot 'Verify-FeedSignature.ps1') -FeedPath $resolved
}

$boards = @($feed.motherboards.PSObject.Properties).Count
$dell = @($feed.dell.PSObject.Properties).Count
$chipsetIds = @($feed.intel.chipsetInf.PSObject.Properties).Count
Write-Host "Feed contract OK: $boards boards, $dell Dell systems, $chipsetIds Intel chipset IDs."

$legacyGigabyteBetas = @($feed.motherboards.PSObject.Properties | Where-Object {
    $_.Value.vendor -eq 'gigabyte' -and
    ("$($_.Value.bios)" -cmatch '[a-z]$' -or "$($_.Value.bios)" -cmatch '\d[A-Z]$')
})
if ($legacyGigabyteBetas.Count -gt 0) {
    Write-Warning "$($legacyGigabyteBetas.Count) legacy Gigabyte beta entries remain; the next full Gigabyte sweep will replace them with stable releases."
}

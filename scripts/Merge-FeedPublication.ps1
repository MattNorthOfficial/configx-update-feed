param(
    [Parameter(Mandatory)] [string] $BoardFeedPath,
    [Parameter(Mandatory)] [string] $LatestFeedPath,
    [Parameter(Mandatory)] [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FeedContract.psm1') -Force

$boardFeed = Get-Content -LiteralPath $BoardFeedPath -Raw -Encoding utf8 | ConvertFrom-Json
$latestFeed = Get-Content -LiteralPath $LatestFeedPath -Raw -Encoding utf8 | ConvertFrom-Json

function Set-FeedProperty($target, [string] $name, $value) {
    $property = $target.PSObject.Properties[$name]
    if ($property) {
        $property.Value = $value
    }
    else {
        $target | Add-Member -NotePropertyName $name -NotePropertyValue $value
    }
}

# A full sweep owns only the two motherboard sections. Everything else from
# the latest origin feed may have been refreshed by a quicker run that started
# later, so replaying the full JSON would move those sections backwards.
Set-FeedProperty $latestFeed 'schemaVersion' 1
Set-FeedProperty $latestFeed 'motherboards' $boardFeed.motherboards
if ($boardFeed.PSObject.Properties['motherboardConflicts']) {
    Set-FeedProperty $latestFeed 'motherboardConflicts' $boardFeed.motherboardConflicts
}
else {
    $latestFeed.PSObject.Properties.Remove('motherboardConflicts')
}
foreach ($entry in $boardFeed.freshness.PSObject.Properties |
        Where-Object { $_.Name.StartsWith('motherboards.', [StringComparison]::Ordinal) }) {
    Set-FeedProperty $latestFeed.freshness $entry.Name $entry.Value
}
Set-FeedProperty $latestFeed 'updated' (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

Assert-FeedContract $latestFeed | Out-Null
$json = $latestFeed | ConvertTo-Json -Depth 5
Set-Content -LiteralPath $OutputPath -Value $json -Encoding utf8

Write-Host "Merged full-sweep motherboard data onto the latest quick sections."

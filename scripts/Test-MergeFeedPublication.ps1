$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot '..\feed\updates.json'
$work = Join-Path ([System.IO.Path]::GetTempPath()) "configx-feed-merge-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $work | Out-Null

try {
    $latest = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json
    $boards = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json

    $latest.amd.windows.current.adrenalin = '99.1.1'
    $latest.freshness.'amd.windows' = '2026-08-05T15:00:00Z'
    $boards.freshness.'motherboards.gigabyte' = '2026-08-05T14:00:00Z'
    $boardProperty = $boards.motherboards.PSObject.Properties | Select-Object -First 1
    $boardProperty.Value.bios = 'TEST1'

    $latestPath = Join-Path $work 'latest.json'
    $boardsPath = Join-Path $work 'boards.json'
    $outputPath = Join-Path $work 'merged.json'
    Set-Content -LiteralPath $latestPath -Value ($latest | ConvertTo-Json -Depth 5) -Encoding utf8
    Set-Content -LiteralPath $boardsPath -Value ($boards | ConvertTo-Json -Depth 5) -Encoding utf8

    & (Join-Path $PSScriptRoot 'Merge-FeedPublication.ps1') `
        -BoardFeedPath $boardsPath -LatestFeedPath $latestPath -OutputPath $outputPath

    $merged = Get-Content -LiteralPath $outputPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($merged.amd.windows.current.adrenalin -ne '99.1.1') {
        throw 'The merge did not preserve the newest quick-section data.'
    }
    if ($merged.motherboards.PSObject.Properties[$boardProperty.Name].Value.bios -ne 'TEST1') {
        throw 'The merge did not publish the full sweep motherboard data.'
    }
    $quickFreshness = [datetimeoffset]$merged.freshness.'amd.windows'
    $boardFreshness = [datetimeoffset]$merged.freshness.'motherboards.gigabyte'
    if ($quickFreshness.ToUniversalTime() -ne [datetimeoffset]'2026-08-05T15:00:00Z' -or
        $boardFreshness.ToUniversalTime() -ne [datetimeoffset]'2026-08-05T14:00:00Z') {
        throw 'The merge did not preserve per-section freshness ownership.'
    }

    Write-Host 'Feed publication merge test passed.'
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

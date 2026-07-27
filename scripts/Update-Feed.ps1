# Scrapes AMD GPUOpen's driver version table and writes feed/drivers.json.
# The table maps every Adrenalin release to its Windows driver-store version
# (the version WMI reports), including the separate RDNA1/2 and Polaris/Vega
# branches that older GPUs are kept on.
#
# Runs on PowerShell 7 (locally on Windows or in GitHub Actions on Linux).

$ErrorActionPreference = 'Stop'

$sourceUrl = 'https://gpuopen.com/version-table/'
$outputPath = Join-Path $PSScriptRoot '..\feed\drivers.json'

$html = (Invoke-WebRequest $sourceUrl -UserAgent 'Mozilla/5.0 winx-driver-feed/1.0' -UseBasicParsing).Content

# Rows look like: Adrenalin Release | WHQL or Optional | Internal Driver | Driver Store Version | Vulkan Version
$rowPattern = '<tr[^>]*>\s*<td[^>]*>(?<release>.*?)</td>\s*<td[^>]*>(?<whql>.*?)</td>\s*<td[^>]*>(?<internal>.*?)</td>\s*<td[^>]*>(?<store>.*?)</td>'
$rows = [regex]::Matches($html, $rowPattern, 'Singleline')

if ($rows.Count -eq 0) {
    throw "No table rows found at $sourceUrl - the page layout may have changed."
}

function Get-CellText([string] $cell) {
    $text = $cell -replace '<[^>]+>', ''
    return [System.Net.WebUtility]::HtmlDecode($text).Trim()
}

# The table is newest-first, so the first row seen per branch is its latest release.
$latestPerBranch = [ordered]@{}

foreach ($row in $rows) {
    $release = Get-CellText $row.Groups['release'].Value
    $store = Get-CellText $row.Groups['store'].Value

    if ($store -notmatch '^\d+(\.\d+)+$') {
        continue  # header or malformed row
    }

    # "26.6.2 for RDNA1 and RDNA2" -> version "26.6.2", branch "for RDNA1 and RDNA2"
    if ($release -notmatch '^(?<version>\d+\.\d+(\.\d+)?)\s*(?<rest>.*)$') {
        continue
    }
    $adrenalin = $Matches['version']
    $rest = $Matches['rest'].Trim()

    $branch = switch -Regex ($rest) {
        'RDNA1 and RDNA2' { 'rdna1-2'; break }
        'Polaris and Vega' { 'polaris-vega'; break }
        default { 'current' }
    }

    if (-not $latestPerBranch.Contains($branch)) {
        $latestPerBranch[$branch] = [ordered]@{
            adrenalin = $adrenalin
            whql = (Get-CellText $row.Groups['whql'].Value) -eq 'WHQL'
            driverStore = $store
        }
    }
}

if (-not $latestPerBranch.Contains('current')) {
    throw 'Could not find the latest mainline release - the page layout may have changed.'
}

$amd = [ordered]@{ windows = $latestPerBranch }

# Leave the file untouched when the driver data hasn't changed, so the
# scheduled workflow only commits on actual releases.
if (Test-Path $outputPath) {
    $existing = Get-Content $outputPath -Raw | ConvertFrom-Json
    if (($existing.amd | ConvertTo-Json -Depth 5) -eq ($amd | ConvertTo-Json -Depth 5)) {
        Write-Host 'Driver data unchanged; feed not rewritten.'
        return
    }
}

$feed = [ordered]@{
    updated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    source = $sourceUrl
    amd = $amd
}

$json = $feed | ConvertTo-Json -Depth 5
Set-Content -Path $outputPath -Value $json -Encoding utf8
Write-Host "Wrote $((Resolve-Path $outputPath).Path):`n$json"

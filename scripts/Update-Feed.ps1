# Scrapes the latest AMD driver versions and writes feed/drivers.json:
# - Graphics: GPUOpen's version table, which maps every Adrenalin release to
#   its Windows driver-store version (the version WMI reports), including the
#   separate RDNA1/2 and Polaris/Vega branches that older GPUs are kept on.
# - Chipset: AMD's chipset driver page (the package is identical across AM4/AM5
#   chipsets) plus its release notes, which list the component driver versions.
#
# Runs on PowerShell 7 (locally on Windows or in GitHub Actions on Linux).

$ErrorActionPreference = 'Stop'

$userAgent = 'Mozilla/5.0 winx-update-feed/1.0'
$outputPath = Join-Path $PSScriptRoot '..\feed\drivers.json'

function Get-CellText([string] $cell) {
    $text = $cell -replace '<[^>]+>', ''
    return [System.Net.WebUtility]::HtmlDecode($text).Trim()
}

# --- Graphics drivers (GPUOpen version table) -------------------------------

$gpuSourceUrl = 'https://gpuopen.com/version-table/'
$html = (Invoke-WebRequest $gpuSourceUrl -UserAgent $userAgent -UseBasicParsing).Content

# Rows look like: Adrenalin Release | WHQL or Optional | Internal Driver | Driver Store Version | Vulkan Version
$rowPattern = '<tr[^>]*>\s*<td[^>]*>(?<release>.*?)</td>\s*<td[^>]*>(?<whql>.*?)</td>\s*<td[^>]*>(?<internal>.*?)</td>\s*<td[^>]*>(?<store>.*?)</td>'
$rows = [regex]::Matches($html, $rowPattern, 'Singleline')

if ($rows.Count -eq 0) {
    throw "No table rows found at $gpuSourceUrl - the page layout may have changed."
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

# --- Chipset drivers (AMD chipset page + release notes) ---------------------

# The AMD Chipset Software package is unified; any chipset's page reports the
# same revision, so X870E stands in for all of them.
$chipsetSourceUrl = 'https://www.amd.com/en/support/downloads/drivers.html/chipsets/am5/x870e.html'

# Failure to scrape the chipset pages should not break the graphics feed, so
# fall back to the previously published chipset data.
$chipset = $null
try {
    $chipsetHtml = (Invoke-WebRequest $chipsetSourceUrl -UserAgent $userAgent -UseBasicParsing).Content
    $chipsetText = $chipsetHtml -replace '<[^>]+>', ' '

    if ($chipsetText -notmatch 'Revision Number\s*([\d.]+)') {
        throw 'Revision number not found on the chipset page.'
    }
    $chipset = [ordered]@{ revision = $Matches[1] }
    if ($chipsetText -match 'Release Date\s*([\d/.-]+)') {
        $chipset.date = $Matches[1]
    }

    # The release notes list every bundled component driver and its version.
    $notesLink = [regex]::Match($chipsetHtml, 'href="([^"]*RN-RYZEN-CHIPSET[^"]*)"').Groups[1].Value
    if ($notesLink) {
        if ($notesLink -notmatch '^https?:') { $notesLink = "https://www.amd.com$notesLink" }
        $notesText = ((Invoke-WebRequest $notesLink -UserAgent $userAgent -UseBasicParsing).Content) -replace '<[^>]+>', ' '

        # The notes use non-breaking spaces; Windows PowerShell 5.1 additionally
        # mis-decodes them as "Â ". Normalize both so \s+ in the patterns works
        # regardless of the PowerShell version running this script.
        $notesText = $notesText -replace [char]0x00C2, ' ' -replace [char]0x00A0, ' '

        # Only the components Win X displays. "AMD Interface Driver" is the
        # package behind the SMBus PnP device on current installs.
        $componentPatterns = [ordered]@{
            smbus = 'AMD Interface Driver[^0-9]{0,160}(\d+(?:\.\d+)+)'
            psp = 'AMD PSP Driver\s+(\d+(?:\.\d+)+)'
            ppm = 'AMD PPM Provisioning File Driver\s+(\d+(?:\.\d+)+)'
            vcache = 'AMD 3D V-Cache Performance Optimizer Driver\s+(\d+(?:\.\d+)+)'
            gpio = 'AMD GPIO2 Driver\s+(\d+(?:\.\d+)+)'
            i2c = 'AMD I2C Driver\s+(\d+(?:\.\d+)+)'
            # PT GPIO is the one component whose Windows 10 and 11 versions can
            # differ; skip the first (Windows 10) column when both are present.
            ptgpio = 'PT GPIO Driver\D{1,30}(?:\d+(?:\.\d+)+\D{1,10})?(\d+(?:\.\d+)+)'
            compatdb = 'AMD Application Compatibility Database Driver\s+(\d+(?:\.\d+)+)'
        }

        $components = [ordered]@{}
        foreach ($key in $componentPatterns.Keys) {
            if ($notesText -match $componentPatterns[$key]) {
                $components[$key] = $Matches[1]
            }
        }
        if ($components.Count -gt 0) {
            $chipset.components = $components
        }
    }
}
catch {
    Write-Warning "Chipset scrape failed: $($_.Exception.Message)"
}

if (-not $chipset -and (Test-Path $outputPath)) {
    $previous = (Get-Content $outputPath -Raw | ConvertFrom-Json).amd.chipset
    if ($previous) {
        Write-Warning 'Reusing previously published chipset data.'
        $chipset = $previous
    }
}

# --- Windows builds (Microsoft's release information page) ------------------

# The release-history tables list every update per version, newest first.
# Only B (Patch Tuesday) and OOB releases count as required - D-week releases
# are optional previews and would flag fully patched machines as outdated.
$windowsSourceUrl = 'https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information'
$windowsBuilds = $null
try {
    $winHtml = (Invoke-WebRequest $windowsSourceUrl -UserAgent $userAgent -UseBasicParsing).Content

    $versionPattern = 'Version (?<version>\d\dH\d) \(OS build \d+\)'
    $winRowPattern = '<tr>\s*<td[^>]*>(?<opt>.*?)</td>\s*<td[^>]*>(?<type>.*?)</td>\s*<td[^>]*>(?<date>.*?)</td>\s*<td[^>]*>(?<build>.*?)</td>\s*<td[^>]*>(?<kb>.*?)</td>'

    $versionMatches = [regex]::Matches($winHtml, $versionPattern)
    $builds = [ordered]@{}

    for ($i = 0; $i -lt $versionMatches.Count; $i++) {
        $version = $versionMatches[$i].Groups['version'].Value
        if ($builds.Contains($version)) {
            continue  # the page mentions each version again in later sections
        }

        $start = $versionMatches[$i].Index
        $end = if ($i + 1 -lt $versionMatches.Count) { $versionMatches[$i + 1].Index } else { $winHtml.Length }
        $block = $winHtml.Substring($start, $end - $start)

        foreach ($row in [regex]::Matches($block, $winRowPattern, 'Singleline')) {
            $type = Get-CellText $row.Groups['type'].Value
            if ($type -notmatch '(\bB|OOB)$') {
                continue
            }
            $build = Get-CellText $row.Groups['build'].Value
            if ($build -notmatch '^\d+\.\d+$') {
                continue
            }

            $entry = [ordered]@{
                build = $build
                date = Get-CellText $row.Groups['date'].Value
            }
            $kb = [regex]::Match($row.Groups['kb'].Value, 'KB\d+').Value
            if ($kb) {
                $entry.kb = $kb
            }
            $builds[$version] = $entry
            break
        }
    }

    if ($builds.Count -eq 0) {
        throw 'No Windows build rows found - the page layout may have changed.'
    }
    $windowsBuilds = $builds
}
catch {
    Write-Warning "Windows builds scrape failed: $($_.Exception.Message)"
}

if (-not $windowsBuilds -and (Test-Path $outputPath)) {
    $previousBuilds = (Get-Content $outputPath -Raw | ConvertFrom-Json).windowsBuilds
    if ($previousBuilds) {
        Write-Warning 'Reusing previously published Windows build data.'
        $windowsBuilds = $previousBuilds
    }
}

# --- Write the feed ----------------------------------------------------------

$amd = [ordered]@{ windows = $latestPerBranch }
if ($chipset) {
    $amd.chipset = $chipset
}

# Leave the file untouched when the data hasn't changed, so the scheduled
# workflow only commits on actual releases.
if (Test-Path $outputPath) {
    $existing = Get-Content $outputPath -Raw | ConvertFrom-Json
    $existingData = @($existing.amd, $existing.windowsBuilds) | ConvertTo-Json -Depth 5
    $newData = @($amd, $windowsBuilds) | ConvertTo-Json -Depth 5
    if ($existingData -eq $newData) {
        Write-Host 'Driver data unchanged; feed not rewritten.'
        return
    }
}

$feed = [ordered]@{
    updated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    source = $gpuSourceUrl
    amd = $amd
}
if ($windowsBuilds) {
    $feed.windowsBuilds = $windowsBuilds
}

$json = $feed | ConvertTo-Json -Depth 5
Set-Content -Path $outputPath -Value $json -Encoding utf8
Write-Host "Wrote $((Resolve-Path $outputPath).Path):`n$json"

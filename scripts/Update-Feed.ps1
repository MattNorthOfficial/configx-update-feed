# Scrapes the latest driver/firmware versions and writes feed/updates.json:
# - AMD graphics: GPUOpen's version table, which maps every Adrenalin release
#   to its Windows driver-store version (the version WMI reports), including
#   the separate RDNA1/2 and Polaris/Vega branches that older GPUs are kept on.
# - AMD chipset: AMD's chipset driver page (the package is identical across
#   AM4/AM5 chipsets) plus its release notes with the component versions.
# - Windows builds: Microsoft's release information page.
# - Motherboard BIOS: MSI's product support API.
# - Intel: the chipset INF utility and both graphics-driver download pages.
# - NVIDIA: the driver-search endpoint behind NVIDIA's own download page.
#
# Runs on PowerShell 7 (locally on Windows or in GitHub Actions on Linux).

$ErrorActionPreference = 'Stop'

$userAgent = 'Mozilla/5.0 winx-update-feed/1.0'
$outputPath = Join-Path $PSScriptRoot '..\feed\updates.json'

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

# --- Motherboard BIOS versions (MSI product API) -----------------------------

# MSI's API rejects plain HTTP clients (Akamai TLS fingerprinting) but serves a
# real browser engine unchallenged, so fetch it through headless Chrome/Edge.
# ASUS is not here - it exposes a public API the app queries live for any
# board; Gigabyte and ASRock aren't yet supported (their BIOS lists need,
# respectively, Nuxt devalue-payload resolution and a per-board table scrape
# that the current --dump-dom approach doesn't reliably reach).
#
# Feed keys are the clean marketing name - Win X strips WMI's "(MS-7E51)"-style
# suffix before looking a board up - so boards are added by name alone, and the
# URL slug is just the name with spaces turned into hyphens. Boards whose slug
# doesn't resolve are skipped, so an incorrect guess is harmless.
$msiBoards = @(
    'MAG X870 TOMAHAWK WIFI'
    'MAG X870E TOMAHAWK WIFI'
    'PRO X870-P WIFI'
    'MPG X870E CARBON WIFI'
    'MAG B850 TOMAHAWK MAX WIFI'
    'PRO B850-P WIFI'
    'MAG B650 TOMAHAWK WIFI'
    'PRO B650-P WIFI'
    'MPG B650 CARBON WIFI'
    'MAG X670E TOMAHAWK WIFI'
    'MPG Z890 CARBON WIFI'
    'MAG Z890 TOMAHAWK WIFI'
    'PRO Z890-P WIFI'
    'MAG B860 TOMAHAWK WIFI'
    'MPG Z790 CARBON WIFI'
    'MAG Z790 TOMAHAWK WIFI'
    'MAG B760 TOMAHAWK WIFI'
)

function Find-HeadlessBrowser {
    foreach ($name in 'google-chrome', 'chromium-browser', 'chromium') {
        if (Get-Command $name -ErrorAction SilentlyContinue) { return $name }
    }
    $windowsPaths = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
    )
    foreach ($path in $windowsPaths) {
        if ($path -and (Test-Path $path)) { return $path }
    }
    return $null
}

$browserUa = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'

# Runs a URL through headless Chrome/Edge and returns the page DOM. Bypasses
# the TLS-fingerprinting bot protection (Akamai) that MSI and Intel use, which
# rejects plain HTTP clients but serves a real browser engine unchallenged.
function Get-BrowserDom([string] $browser, [string] $url) {
    # The browser logs harmless warnings to stderr, which would become
    # terminating errors under $ErrorActionPreference = 'Stop'.
    $previousPreference = $script:ErrorActionPreference
    $script:ErrorActionPreference = 'Continue'
    $dom = & $browser --headless=new --disable-gpu --no-sandbox --user-agent="$browserUa" --dump-dom $url 2>$null | Out-String
    $script:ErrorActionPreference = $previousPreference
    return $dom
}

# Normalizes a release date to yyyy-MM-dd where parseable.
function Format-BiosDate([string] $raw) {
    if (-not $raw) { return '' }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($raw.Trim(), [ref] $parsed)) {
        return $parsed.ToString('yyyy-MM-dd')
    }
    return $raw.Trim()
}

# MSI: JSON support panel via headless browser (Akamai-protected). The slug is
# the marketing name with spaces turned into hyphens.
function Get-MsiBios([string] $browser, [string] $model) {
    $slug = ($model -replace '\s+', '-')
    $dom = Get-BrowserDom $browser "https://www.msi.com/api/v1/product/support/panel?product=$slug&type=bios"
    $json = [regex]::Match($dom, '(?s)\{.*\}').Value
    if (-not $json) { return $null }

    $data = [System.Net.WebUtility]::HtmlDecode($json) | ConvertFrom-Json
    $latest = @($data.result.downloads.'AMI BIOS') |
        Where-Object { $_.download_version -and "$($_.download_version) $($_.download_title)" -notmatch 'beta' } |
        Select-Object -First 1
    if (-not $latest) { return $null }

    return [ordered]@{ bios = $latest.download_version; date = (Format-BiosDate $latest.download_release) }
}

$motherboards = $null
try {
    $browser = Find-HeadlessBrowser
    if (-not $browser) {
        throw 'No Chrome or Edge available for the MSI fetch.'
    }

    $boards = [ordered]@{}
    foreach ($model in $msiBoards) {
        try {
            $entry = Get-MsiBios $browser $model
            if ($entry) {
                $boards[$model] = $entry
            }
            else {
                Write-Warning "MSI: no BIOS for $model."
            }
        }
        catch {
            Write-Warning "MSI '$model' failed: $($_.Exception.Message)"
        }
    }

    if ($boards.Count -eq 0) {
        throw 'No BIOS versions could be fetched.'
    }
    $motherboards = $boards
}
catch {
    Write-Warning "Motherboard BIOS scrape failed: $($_.Exception.Message)"
}

if (-not $motherboards -and (Test-Path $outputPath)) {
    $previousBoards = (Get-Content $outputPath -Raw | ConvertFrom-Json).motherboards
    if ($previousBoards) {
        Write-Warning 'Reusing previously published motherboard data.'
        $motherboards = $previousBoards
    }
}

# --- Intel drivers (Intel download-center pages) ------------------------------

# Each download page states its latest version in the short-description text.
# Graphics has two branches since Intel's 2025 split: "arc" (Arc cards and
# Core Ultra iGPUs) and "xe" (legacy-support package for 11th-14th gen
# Iris Xe / UHD). Keys match the app's feed lookups.
$intelPages = [ordered]@{
    chipset = @{
        url = 'https://www.intel.com/content/www/us/en/download/19347/chipset-inf-utility.html'
        pattern = 'utility version\s+(\d+(?:\.\d+)+)'
    }
    arc = @{
        url = 'https://www.intel.com/content/www/us/en/download/785597/intel-arc-graphics-windows.html'
        pattern = 'Graphics Driver\s+(\d+(?:\.\d+)+)\s+for'
    }
    xe = @{
        url = 'https://www.intel.com/content/www/us/en/download/864990/intel-11th-14th-gen-processor-graphics-windows.html'
        pattern = 'Graphics Driver\s+(\d+(?:\.\d+)+)\s+for'
    }
}

$intel = $null
try {
    $browser = Find-HeadlessBrowser
    if (-not $browser) {
        throw 'No Chrome or Edge available for the Intel fetch.'
    }

    $entries = [ordered]@{}
    foreach ($key in $intelPages.Keys) {
        $page = $intelPages[$key]
        $text = [System.Net.WebUtility]::HtmlDecode(
            ((Get-BrowserDom $browser $page.url) -replace '<[^>]+>', ' '))

        if ($text -match $page.pattern) {
            $entries[$key] = [ordered]@{
                version = $Matches[1]
                url = $page.url
            }
        }
        else {
            Write-Warning "No version found on the Intel '$key' page."
        }
    }

    if ($entries.Count -eq 0) {
        throw 'No Intel versions could be fetched.'
    }
    $intel = $entries
}
catch {
    Write-Warning "Intel scrape failed: $($_.Exception.Message)"
}

if (-not $intel -and (Test-Path $outputPath)) {
    $previousIntel = (Get-Content $outputPath -Raw | ConvertFrom-Json).intel
    if ($previousIntel) {
        Write-Warning 'Reusing previously published Intel data.'
        $intel = $previousIntel
    }
}

# --- NVIDIA GeForce driver (NVIDIA's driver-search endpoint) ------------------

# One Game Ready release covers every GeForce the current branch supports, so
# a single representative card's lookup yields the feed version. The pfid
# comes from the same community GPU map the app uses for its online lookup.
$nvidia = $null
try {
    $gpuData = Invoke-RestMethod 'https://raw.githubusercontent.com/ZenitH-AT/nvidia-data/main/gpu-data.json' -UserAgent $userAgent
    $pfid = $null
    foreach ($section in $gpuData.PSObject.Properties) {
        $hit = $section.Value.PSObject.Properties |
            Where-Object Name -in 'GeForce RTX 5090', 'GeForce RTX 4090' |
            Select-Object -First 1
        if ($hit) {
            $pfid = $hit.Value
            break
        }
    }
    if (-not $pfid) {
        throw 'No known GPU found in the community GPU map.'
    }

    $lookupUrl = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php' +
        "?func=DriverManualLookup&pfid=$pfid&osID=135&languageCode=1033&isWHQL=1&dch=1&sort1=0&numberOfResults=1"
    $info = (Invoke-RestMethod $lookupUrl -UserAgent $userAgent).IDS[0].downloadInfo
    if (-not $info.Version) {
        throw 'Lookup returned no version.'
    }

    $nvidia = [ordered]@{
        gameReady = $info.Version
        url = "$($info.DetailsURL)"
    }
}
catch {
    Write-Warning "NVIDIA lookup failed: $($_.Exception.Message)"
}

if (-not $nvidia -and (Test-Path $outputPath)) {
    $previousNvidia = (Get-Content $outputPath -Raw | ConvertFrom-Json).nvidia
    if ($previousNvidia) {
        Write-Warning 'Reusing previously published NVIDIA data.'
        $nvidia = $previousNvidia
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
    $existingData = @($existing.amd, $existing.windowsBuilds, $existing.motherboards, $existing.intel, $existing.nvidia) | ConvertTo-Json -Depth 5
    $newData = @($amd, $windowsBuilds, $motherboards, $intel, $nvidia) | ConvertTo-Json -Depth 5
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
if ($motherboards) {
    $feed.motherboards = $motherboards
}
if ($intel) {
    $feed.intel = $intel
}
if ($nvidia) {
    $feed.nvidia = $nvidia
}

$json = $feed | ConvertTo-Json -Depth 5
Set-Content -Path $outputPath -Value $json -Encoding utf8
Write-Host "Wrote $((Resolve-Path $outputPath).Path):`n$json"

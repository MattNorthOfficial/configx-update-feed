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

$userAgent = 'Mozilla/5.0 configx-update-feed/1.0'
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

        # Only the components Config X displays. The SMBus PnP device runs two
        # different driver families: "AMD Interface Driver" (2.x) on AM5 and
        # the legacy "AMD SMBUS Driver" (5.12.x) on AM4 - the notes list
        # both, and the app picks the entry matching the installed family.
        $componentPatterns = [ordered]@{
            smbus = 'AMD Interface Driver[^0-9]{0,160}(\d+(?:\.\d+)+)'
            # Like PT GPIO, the Win10 and Win11 columns can both appear;
            # take the later (Win11) one when two versions are present.
            smbusAm4 = 'AMD SMBUS Driver\D{1,30}(?:\d+(?:\.\d+)+\D{1,10})?(\d+(?:\.\d+)+)'
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

    # End-of-servicing dates come from Microsoft's lifecycle pages, not the
    # release information summary table: once a tier leaves support, the
    # summary replaces its date with the text "End of updates" (and fully
    # retired versions drop out of that table entirely), so parsing it left
    # out-of-support versions - the ones the row matters most for - with no
    # dates at all. The lifecycle pages keep every version's exact dates,
    # past and future. Versions missing there just ship without the dates.
    $lifecycleTiers = @(
        @{ Field = 'eosHome'; Url = 'https://learn.microsoft.com/en-us/lifecycle/products/windows-11-home-and-pro' }
        @{ Field = 'eosEnterprise'; Url = 'https://learn.microsoft.com/en-us/lifecycle/products/windows-11-enterprise-and-education' }
    )
    foreach ($tier in $lifecycleTiers) {
        try {
            $lifecycleHtml = (Invoke-WebRequest $tier.Url -UserAgent $userAgent -UseBasicParsing).Content
            foreach ($version in @($builds.Keys)) {
                # Each version's row holds two ISO timestamps - availability,
                # then retirement - but the HTML repeats each one (a machine-
                # readable attribute plus the rendered text), so positions
                # aren't fixed. The retirement date is always the last stamp.
                $row = [regex]::Match($lifecycleHtml, "(?s)<tr[^>]*>\s*<td[^>]*>\s*Version\s+$version\s*</td>.*?</tr>")
                if ($row.Success) {
                    $stamps = @([regex]::Matches($row.Value, '(\d{4}-\d{2}-\d{2})T') | ForEach-Object { $_.Groups[1].Value })
                    if ($stamps.Count -ge 2) {
                        $builds[$version][$tier.Field] = $stamps[-1]
                    }
                }
            }
        }
        catch {
            Write-Warning "Windows lifecycle scrape failed for $($tier.Field): $($_.Exception.Message)"
        }
    }

    $windowsBuilds = $builds
}
catch {
    Write-Warning "Windows builds scrape failed: $($_.Exception.Message)"
}

# --- Windows 10 support windows (Microsoft's lifecycle pages) ---------------

# Windows 10 shares version names with Windows 11 (both have a 22H2), so its
# dates live in a separate section the app consults when the running OS is
# Windows 10. No build tracking: Windows 10 receives no feature updates, so
# the useful signal is the support window itself.
$windows10 = $null
try {
    $win10Tiers = @(
        @{ Field = 'eosHome'; Url = 'https://learn.microsoft.com/en-us/lifecycle/products/windows-10-home-and-pro' }
        @{ Field = 'eosEnterprise'; Url = 'https://learn.microsoft.com/en-us/lifecycle/products/windows-10-enterprise-and-education' }
    )
    $win10 = [ordered]@{}
    foreach ($tier in $win10Tiers) {
        $lifecycleHtml = (Invoke-WebRequest $tier.Url -UserAgent $userAgent -UseBasicParsing).Content
        foreach ($row in [regex]::Matches($lifecycleHtml, '(?s)<tr[^>]*>\s*<td[^>]*>\s*Version\s+(\d\dH\d)\s*</td>.*?</tr>')) {
            # Same layout as the Windows 11 pages: two ISO timestamps per row
            # (each duplicated by the HTML), retirement always last.
            $version = $row.Groups[1].Value
            $stamps = @([regex]::Matches($row.Value, '(\d{4}-\d{2}-\d{2})T') | ForEach-Object { $_.Groups[1].Value })
            if ($stamps.Count -ge 2) {
                if (-not $win10.Contains($version)) {
                    $win10[$version] = [ordered]@{}
                }
                $win10[$version][$tier.Field] = $stamps[-1]
            }
        }
    }
    if ($win10.Count -gt 0) {
        $windows10 = $win10
    }
}
catch {
    Write-Warning "Windows 10 lifecycle scrape failed: $($_.Exception.Message)"
}

if (-not $windows10 -and (Test-Path $outputPath)) {
    $previousWin10 = (Get-Content $outputPath -Raw | ConvertFrom-Json).windows10
    if ($previousWin10) {
        Write-Warning 'Reusing previously published Windows 10 data.'
        $windows10 = $previousWin10
    }
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
# real browser engine unchallenged, so everything here goes through headless
# Chrome/Edge. The board list is not maintained by hand: MSI's products
# sitemap enumerates every motherboard slug, filtered to desktop chipsets
# (AM4/AM5, LGA1200/1700/1851, HEDT). Each board's support panel then reports
# its official marketing name ("PRO X870-P WIFI") - the feed key, matching
# what Config X reads from WMI once it strips the "(MS-7E51)"-style suffix -
# alongside its BIOS downloads.
#
# Gigabyte and ASRock are covered further down with full catalog sweeps of
# their own (Gigabyte's pages are server-rendered but only exist at
# canonical revision URLs enumerated from its All-Series grid; ASRock's
# derive from the model name). ASUS is swept last, through its public
# APIs - the app checks ASUS live first and uses those feed entries as the
# offline fallback.
$msiSitemapUrl = 'https://www.msi.com/sitemap-products-001.xml'
$msiChipsetFilter = '\b(X870|X670|B850|B840|B650|A620|X570|B550|A520|B450|X470|X370|B350|A320' +
    '|Z890|B860|H810|Z790|B760|H770|Z690|B660|H670|H610|Z590|B560|H510|Z490|B460|H410|H310' +
    '|TRX50|TRX40|WRX90|X399|X299)[A-Z]*\b'

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

# Normalizes a release date to yyyy-MM-dd where parseable. Invariant culture,
# so "Jul 20, 2026" (Gigabyte) and "2026/7/2" (ASRock) parse the same way
# regardless of the machine's locale.
function Format-BiosDate([string] $raw) {
    if (-not $raw) { return '' }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($raw.Trim(), [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref] $parsed)) {
        return $parsed.ToString('yyyy-MM-dd')
    }
    return $raw.Trim()
}

# MSI: JSON support panel via headless browser (Akamai-protected). Returns the
# board's official name alongside its newest non-beta BIOS, or $null when the
# slug doesn't resolve or lists no BIOS.
function Get-MsiBios([string] $browser, [string] $slug) {
    $dom = Get-BrowserDom $browser "https://www.msi.com/api/v1/product/support/panel?product=$slug&type=bios"
    $json = [regex]::Match($dom, '(?s)\{.*\}').Value
    if (-not $json) { return $null }

    $data = [System.Net.WebUtility]::HtmlDecode($json) | ConvertFrom-Json
    $name = "$($data.result.title)".Trim()
    $latest = @($data.result.downloads.'AMI BIOS') |
        Where-Object { $_.download_version -and "$($_.download_version) $($_.download_title)" -notmatch 'beta' } |
        Select-Object -First 1
    if (-not $name -or -not $latest) { return $null }

    return [pscustomobject]@{
        Name = $name
        Entry = [ordered]@{ bios = $latest.download_version; date = (Format-BiosDate $latest.download_release) }
    }
}

# Gigabyte: the BIOS list is server-rendered into each board's support page,
# but pages only exist at canonical revision URLs ("...-rev-10-11") that
# cannot be derived from a board name - so slugs come from enumerating the
# All-Series grid. The entry's url rides into the feed so the app can link
# the exact page (pattern-built Gigabyte links would land on an error shell).
function Get-GigabyteBios([string] $browser, [string] $slug) {
    $url = "https://www.gigabyte.com/Motherboard/$slug/support"
    $dom = Get-BrowserDom $browser $url
    # First version cell ("F42c") with its date cell nearby = newest BIOS.
    $m = [regex]::Match($dom, '(?s)>(F\d{1,2}[a-z]?)<.{0,400}?>([A-Z][a-z]{2} \d{1,2}, \d{4})<')
    if (-not $m.Success) { return $null }

    return [ordered]@{
        bios = $m.Groups[1].Value
        date = Format-BiosDate $m.Groups[2].Value
        url  = "$url#support-dl-bios"
    }
}

# ASRock: BIOS.html renders under headless. Some boards list oldest-first, so
# the newest entry is picked by date rather than position; beta rows ("[Beta]"
# or ".AS06"-suffixed versions) never match because the pattern requires the
# date to follow the plain version directly. The page URL rides into the feed
# because Phantom Gaming boards live on pg.asrock.com - their old
# www.asrock.com pages froze when the line moved (~2022) and would otherwise
# look plausible while being years stale.
function Get-AsrockBios([string] $browser, [string] $url) {
    $dom = Get-BrowserDom $browser $url
    $text = $dom -replace '<[^>]+>', ' ' -replace '\s+', ' '

    $best = $null
    $bestDate = [datetime]::MinValue
    foreach ($m in [regex]::Matches($text, '\b(\d+\.\d+[A-Za-z]?)\s+(\d{4}/\d{1,2}/\d{1,2})\b')) {
        $date = [datetime]::MinValue
        if ([datetime]::TryParse($m.Groups[2].Value, [cultureinfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None, [ref] $date) -and $date -gt $bestDate) {
            $bestDate = $date
            $best = [ordered]@{ bios = $m.Groups[1].Value; date = $date.ToString('yyyy-MM-dd'); url = $url }
        }
    }

    return $best
}

$motherboards = $null
try {
    $browser = Find-HeadlessBrowser
    if (-not $browser) {
        throw 'No Chrome or Edge available for the MSI fetch.'
    }

    $slugs = @([regex]::Matches((Get-BrowserDom $browser $msiSitemapUrl),
            'https://www\.msi\.com/Motherboard/([^<\s"/]+)') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique |
        Where-Object { $_ -match $msiChipsetFilter })
    if ($slugs.Count -lt 50) {
        throw "Only $($slugs.Count) boards enumerated - the sitemap layout may have changed."
    }
    Write-Host "MSI: checking $($slugs.Count) boards..."

    # Each headless call takes a few seconds; a handful in flight keeps the
    # full sweep to minutes without hammering MSI. The parallel runspaces
    # don't inherit functions, so they are re-hydrated from their text.
    $getBrowserDom = ${function:Get-BrowserDom}.ToString()
    $getMsiBios = ${function:Get-MsiBios}.ToString()
    $formatBiosDate = ${function:Format-BiosDate}.ToString()
    $results = $slugs | ForEach-Object -ThrottleLimit 6 -Parallel {
        $slug = $_
        ${function:Get-BrowserDom} = $using:getBrowserDom
        ${function:Get-MsiBios} = $using:getMsiBios
        ${function:Format-BiosDate} = $using:formatBiosDate
        $browserUa = $using:browserUa
        try {
            Get-MsiBios $using:browser $slug
        }
        catch {
            Write-Warning "MSI '$slug' failed: $($_.Exception.Message)"
            $null
        }
    }

    $fetched = @{}
    foreach ($result in $results | Where-Object { $_ }) {
        $fetched[$result.Name] = $result.Entry
    }
    if ($fetched.Count -eq 0) {
        throw 'No BIOS versions could be fetched.'
    }
    Write-Host "MSI: $($fetched.Count) boards resolved."

    # Gigabyte: the All-Series grid server-renders its catalog page by page
    # (~14 products each), and its anchors carry the canonical revision
    # slugs. Walking pages until no new slug appears enumerates every board
    # ever listed; out-of-range pages just echo page 1, which that stop
    # condition also catches.
    $gigabyteSlugs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pageStart = 1
    while ($pageStart -le 200) {
        $batch = ($pageStart..($pageStart + 7)) | ForEach-Object -ThrottleLimit 8 -Parallel {
            ${function:Get-BrowserDom} = $using:getBrowserDom
            $browserUa = $using:browserUa
            $dom = Get-BrowserDom $using:browser "https://www.gigabyte.com/Motherboard/All-Series?page=$_"
            [regex]::Matches($dom, 'href="/Motherboard/([^"#?/]+)"') | ForEach-Object { $_.Groups[1].Value }
        }
        $before = $gigabyteSlugs.Count
        foreach ($slug in $batch) { [void]$gigabyteSlugs.Add($slug) }
        if ($gigabyteSlugs.Count -eq $before) { break }
        $pageStart += 8
    }

    # Unlike the other vendors, Gigabyte is swept unfiltered - every board
    # the grid lists, back through the oldest generations. Anything with a
    # digit is a product (series pages like "AORUS" or "All-Series" have
    # none), and non-board pages that slip through self-filter because
    # their support page has no F-version BIOS list to match.
    $gigabyteBoards = @($gigabyteSlugs | Where-Object { $_ -match '\d' } | Sort-Object)
    if ($gigabyteBoards.Count -lt 50) {
        throw "Only $($gigabyteBoards.Count) Gigabyte boards enumerated - the All-Series layout may have changed."
    }
    Write-Host "Gigabyte: checking $($gigabyteBoards.Count) board pages..."

    $getGigabyteBios = ${function:Get-GigabyteBios}.ToString()
    $gigabyteResults = $gigabyteBoards | ForEach-Object -ThrottleLimit 6 -Parallel {
        $slug = $_
        ${function:Get-BrowserDom} = $using:getBrowserDom
        ${function:Get-GigabyteBios} = $using:getGigabyteBios
        ${function:Format-BiosDate} = $using:formatBiosDate
        $browserUa = $using:browserUa
        try {
            $entry = Get-GigabyteBios $using:browser $slug
            if ($entry) { [pscustomobject]@{ Slug = $slug; Entry = $entry } } else { $null }
        }
        catch {
            Write-Warning "Gigabyte '$slug' failed: $($_.Exception.Message)"
            $null
        }
    }

    # Boards with several hardware revisions get one page (and BIOS train)
    # per revision, while WMI only reports the marketing name - so revisions
    # collapse onto that name and the newest-dated BIOS wins. The entry's
    # url keeps pointing at the exact revision page the verdict came from.
    $gigabyteByName = @{}
    foreach ($result in $gigabyteResults | Where-Object { $_ }) {
        $name = ($result.Slug -replace '-rev-[0-9a-zx-]+$', '') -replace '-', ' '
        $existing = $gigabyteByName[$name]
        if (-not $existing -or [string]::Compare($result.Entry.date, $existing.date) -gt 0) {
            $gigabyteByName[$name] = $result.Entry
        }
    }
    foreach ($name in $gigabyteByName.Keys) {
        $fetched[$name] = $gigabyteByName[$name]
    }
    Write-Host "Gigabyte: $($gigabyteByName.Count) boards resolved."

    # ASRock: the motherboard index embeds the complete catalog as JS
    # arrays - "allmodels" holds every board ever made ([name, socket,
    # chipset, form factor], ~1300 entries back to socket 754) and
    # "pgmodels" names the Phantom Gaming boards whose live pages sit on
    # pg.asrock.com. One headless fetch enumerates everything; the sweep
    # covers the sockets Config X's audience runs, mirroring the MSI filter.
    # BIOS page URLs drop the slashes some names carry ("Z790 Pro RS/D4"
    # lives at ".../Z790 Pro RSD4/"; an encoded slash 404s).
    $asrockDom = Get-BrowserDom $browser 'https://www.asrock.com/mb/index.asp'

    # The arrays are single-quoted JS literals, so entries parse by pattern
    # rather than as JSON: ['name','socket','chipset','form factor'].
    function Get-AsrockCatalog([string] $dom, [string] $arrayName) {
        $slice = [regex]::Match($dom, "(?s)$arrayName\s*=\s*\[(.*?)\]\s*;").Groups[1].Value
        [regex]::Matches($slice, "\['([^']*)','([^']*)','([^']*)','([^']*)'\]") |
            ForEach-Object { , @($_.Groups[1].Value, $_.Groups[2].Value, $_.Groups[3].Value, $_.Groups[4].Value) }
    }

    $asrockAll = @(Get-AsrockCatalog $asrockDom 'allmodels')
    $asrockPgNames = @(Get-AsrockCatalog $asrockDom 'pgmodels' | ForEach-Object { $_[0] })

    $asrockSockets = 'AM4', 'AM5', 'sTR5', 'sWRX8', 'sTRX4', 'TR4', '1200', '1700', '1851', '2066'
    $asrockBoards = @($asrockAll | Where-Object { $_[1] -in $asrockSockets })
    if ($asrockBoards.Count -lt 50) {
        throw "Only $($asrockBoards.Count) ASRock boards enumerated - the index layout may have changed."
    }
    Write-Host "ASRock: checking $($asrockBoards.Count) boards..."

    $getAsrockBios = ${function:Get-AsrockBios}.ToString()
    $asrockResults = $asrockBoards | ForEach-Object -ThrottleLimit 6 -Parallel {
        $board = $_
        ${function:Get-BrowserDom} = $using:getBrowserDom
        ${function:Get-AsrockBios} = $using:getAsrockBios
        $browserUa = $using:browserUa

        # Vendor is the chipset field's first word and names drop their
        # slashes - the same rules the page's own link-building code uses.
        $name = $board[0]
        $vendor = $board[2].Split(' ')[0]
        $site = if ($using:asrockPgNames -contains $name) { 'pg.asrock.com' } else { 'www.asrock.com' }
        $slug = [uri]::EscapeDataString($name.Replace('/', ''))
        try {
            $entry = Get-AsrockBios $using:browser "https://$site/mb/$vendor/$slug/BIOS.html"
            if (-not $entry) {
                # Some lines sit on the other subdomain than the catalog
                # claims (the Lightning boards live on pg without being in
                # pgmodels); product pages redirect across but BIOS.html
                # doesn't, so a miss retries on the other side.
                $other = if ($site -eq 'www.asrock.com') { 'pg.asrock.com' } else { 'www.asrock.com' }
                $entry = Get-AsrockBios $using:browser "https://$other/mb/$vendor/$slug/BIOS.html"
            }
            if (-not $entry) {
                # Boards sold in multiple editions (B450M Steel Legend and
                # its Pink Edition share one page) number their fragments:
                # BIOS1.html is the base edition's list.
                $entry = Get-AsrockBios $using:browser "https://$site/mb/$vendor/$slug/BIOS1.html"
            }

            if ($entry) { [pscustomobject]@{ Name = $name; Entry = $entry } }
            else { Write-Warning "ASRock: no BIOS for $name."; $null }
        }
        catch {
            Write-Warning "ASRock '$name' failed: $($_.Exception.Message)"
            $null
        }
    }

    $asrockResolved = 0
    foreach ($result in $asrockResults | Where-Object { $_ }) {
        $fetched[$result.Name] = $result.Entry
        $asrockResolved++
    }
    Write-Host "ASRock: $asrockResolved boards resolved."

    # ASUS: their support API answers plain requests, so the app checks ASUS
    # boards live - this sweep bundles the same answers into the feed as the
    # offline fallback. The board list comes from the JSON API behind
    # asus.com's own product grid (~900 boards), filtered to the same
    # sockets as the other vendors via the shared chipset pattern. No
    # headless browser needed for any of it.
    $asusNames = [System.Collections.Generic.List[string]]::new()
    $pageIndex = 1
    do {
        $page = Invoke-RestMethod -UserAgent $userAgent -TimeoutSec 30 -Uri (
            'https://odinapi.asus.com/recent-data/apiv2/SeriesFilterResult?SystemCode=asus&WebsiteCode=global' +
            '&ProductLevel1Code=motherboards-components&ProductLevel2Code=motherboards' +
            "&PageSize=100&PageIndex=$pageIndex" +
            '&CategoryName=&SeriesName=&SubSeriesName=&Spec=&SubSpec=&PriceMin=&PriceMax=&Sort=Newsest&siteID=www')
        foreach ($product in $page.Result.ProductList) {
            $name = [System.Net.WebUtility]::HtmlDecode(($product.Name -replace '<[^>]+>', '')).Trim()
            if ($name) { $asusNames.Add($name) }
        }
        $pageIndex++
    } while ($asusNames.Count -lt $page.Result.TotalCount -and $page.Result.ProductList.Count -gt 0)

    $asusBoards = @($asusNames | Sort-Object -Unique | Where-Object { $_ -match $msiChipsetFilter })
    if ($asusBoards.Count -lt 50) {
        throw "Only $($asusBoards.Count) ASUS boards enumerated - the listing API may have changed."
    }
    Write-Host "ASUS: checking $($asusBoards.Count) boards..."

    $asusResults = $asusBoards | ForEach-Object -ThrottleLimit 8 -Parallel {
        $name = $_
        try {
            $response = Invoke-RestMethod -UserAgent $using:userAgent -TimeoutSec 30 -Uri (
                'https://www.asus.com/support/api/product.asmx/GetPDBIOS?website=global' +
                "&model=$([uri]::EscapeDataString($name))&cpu=")
            $biosGroup = $response.Result.Obj | Where-Object { $_.Name -eq 'BIOS' } | Select-Object -First 1
            $newest = if ($biosGroup) { $biosGroup.Files | Select-Object -First 1 } else { $null }
            if ($newest -and $newest.Version) {
                [pscustomobject]@{
                    Name  = $name
                    Entry = [ordered]@{
                        bios = "$($newest.Version)"
                        date = "$($newest.ReleaseDate)".Replace('/', '-')
                        url  = "https://www.asus.com/supportonly/$([uri]::EscapeDataString($name))/helpdesk_bios/"
                    }
                }
            }
            else { $null }
        }
        catch {
            Write-Warning "ASUS '$name' failed: $($_.Exception.Message)"
            $null
        }
    }

    $asusResolved = 0
    foreach ($result in $asusResults | Where-Object { $_ }) {
        $fetched[$result.Name] = $result.Entry
        $asusResolved++
    }
    Write-Host "ASUS: $asusResolved boards resolved."

    # Boards that dropped out of this sweep (a transient API failure, or a
    # vendor delisting an older product) keep their previously published
    # entry: the last-known BIOS remains the newest one there is.
    if (Test-Path $outputPath) {
        $previousBoards = (Get-Content $outputPath -Raw | ConvertFrom-Json).motherboards
        foreach ($prop in @($previousBoards.PSObject.Properties)) {
            if ($prop.Value.bios -and -not $fetched.ContainsKey($prop.Name)) {
                $carried = [ordered]@{ bios = $prop.Value.bios; date = "$($prop.Value.date)" }
                if ($prop.Value.url) { $carried.url = $prop.Value.url }
                $fetched[$prop.Name] = $carried
            }
        }
    }

    # Sorted keys keep the feed diff stable across runs (parallel completion
    # order varies run to run).
    $boards = [ordered]@{}
    foreach ($name in ($fetched.Keys | Sort-Object)) {
        $boards[$name] = $fetched[$name]
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
        $dom = Get-BrowserDom $browser $page.url
        $text = [System.Net.WebUtility]::HtmlDecode(($dom -replace '<[^>]+>', ' '))

        if ($text -match $page.pattern) {
            $entries[$key] = [ordered]@{
                version = $Matches[1]
                url = $page.url
            }

            # The page's download button links straight to Intel's CDN, where
            # the installer (.exe) sits alongside release notes and readmes.
            # Published so the app can offer the file directly.
            $exe = [regex]::Match($dom, 'https://downloadmirror\.intel\.com/[^\s"''<>]+\.exe')
            if ($exe.Success) {
                $entries[$key].download = $exe.Value
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
        # The lookup also names the installer file itself, so the app can
        # offer the download directly instead of the details page.
        download = "$($info.DownloadURL)"
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
    $existingData = @($existing.amd, $existing.windowsBuilds, $existing.windows10, $existing.motherboards, $existing.intel, $existing.nvidia) | ConvertTo-Json -Depth 5
    $newData = @($amd, $windowsBuilds, $windows10, $motherboards, $intel, $nvidia) | ConvertTo-Json -Depth 5
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
if ($windows10) {
    $feed.windows10 = $windows10
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

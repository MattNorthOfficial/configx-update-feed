# Validates the Gigabyte sweep's structural parsing against a stratified
# sample of real board pages: BIOS-section hit rate, version/date extraction
# across the different version schemes ("F42c", "FA2"), and the page-title
# board naming the feed keys entries by.
#
# Deliberately gentle: 2-3 browsers in flight and ~50 board pages, so it can
# run on a workstation without the load profile of the full sweep.
$ErrorActionPreference = 'Stop'

$browserUa = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
$browser = @('google-chrome', 'chromium-browser', 'chromium') |
    Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if (-not $browser) {
    $browser = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $browser) { throw 'No browser.' }

function Get-Dom([string] $url) {
    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    $profile = Join-Path ([System.IO.Path]::GetTempPath()) "gb-parse-$([guid]::NewGuid())"
    try {
        $arguments = @(
            '--headless=new'
            '--disable-gpu'
            '--disable-dev-shm-usage'
            "--user-agent=$script:browserUa"
            "--user-data-dir=$profile"
            '--dump-dom'
            $url
        ) | ForEach-Object { '"' + $_ + '"' }
        $process = Start-Process -FilePath $script:browser -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
            -ArgumentList $arguments
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill($true) } catch { }
            $process.WaitForExit(5000) | Out-Null
        }
        return [string](Get-Content -LiteralPath $stdout -Raw -Encoding utf8 -ErrorAction SilentlyContinue)
    }
    finally {
        Remove-Item $stdout, $stderr -Force -ErrorAction SilentlyContinue
        Remove-Item $profile -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$getDom = ${function:Get-Dom}.ToString()

Write-Host 'Enumerating the catalog (throttle 3)...'
$slugs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$pageStart = 1
while ($pageStart -le 200) {
    $batch = ($pageStart..($pageStart + 5)) | ForEach-Object -ThrottleLimit 3 -Parallel {
        ${function:Get-Dom} = $using:getDom
        $script:browser = $using:browser
        $script:browserUa = $using:browserUa
        $dom = Get-Dom "https://www.gigabyte.com/Motherboard/All-Series?page=$_"
        [regex]::Matches($dom, 'href="/Motherboard/([^"#?/]+)"') | ForEach-Object { $_.Groups[1].Value }
    }
    $before = $slugs.Count
    foreach ($slug in $batch) { [void]$slugs.Add($slug) }
    if ($slugs.Count -eq $before) { break }
    $pageStart += 6
}
$boards = @($slugs | Where-Object { $_ -match '\d' } | Sort-Object)
Write-Host "Catalog: $($boards.Count) board slugs."

# Stratified sample: every Nth board across the alphabetical span (covers
# all chipset eras and naming styles) plus known interesting shapes.
$step = [Math]::Max(1, [int][Math]::Floor($boards.Count / 40))
$sample = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $boards.Count; $i += $step) { $sample.Add($boards[$i]) }
foreach ($extra in @($boards | Where-Object { $_ -match '^GA-' } | Select-Object -First 3) +
                   @($boards | Where-Object { $_ -match '-rev-1[0-9]-' } | Select-Object -First 2) +
                   @($boards | Where-Object { $_ -match 'X870E|TRX50' } | Select-Object -First 3) +
                   @('TRX50-AERO-D-rev-11', 'H410M-H-V2-rev-18', 'B550-AORUS-ELITE-AX-V2-rev-12-13', 'GA-C1037UN-rev-20')) {
    if ($extra -and -not $sample.Contains($extra)) { $sample.Add($extra) }
}
Write-Host "Sampling $($sample.Count) board pages (throttle 2)..."

$results = $sample | ForEach-Object -ThrottleLimit 2 -Parallel {
    ${function:Get-Dom} = $using:getDom
    $script:browser = $using:browser
    $script:browserUa = $using:browserUa
    $slug = $_
    $dom = Get-Dom "https://www.gigabyte.com/Motherboard/$slug/support"

    # Mirrors Update-Feed.ps1's Get-GigabyteBios structural parse.
    $bios = [regex]::Match($dom, '(?s)<h2>\s*BIOS\s*</h2>(.*?)(?:<h2>|</html>|$)').Groups[1].Value
    $bestVer = ''
    $bestDate = [datetime]::MinValue
    $rowCount = 0
    if ($bios) {
        foreach ($m in [regex]::Matches($bios,
                '(?s)class="item-version"[^>]*>\s*([^<]+?)\s*<.*?class="item-date"[^>]*>\s*([^<]+?)\s*<')) {
            $version = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value.Trim())
            if ($version -cmatch '[a-z]$' -or $version -cmatch '\d[A-Z]$') {
                continue
            }
            $rowCount++
            $date = [datetime]::MinValue
            if ([datetime]::TryParse($m.Groups[2].Value.Trim(), [cultureinfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None, [ref] $date) -and $date -gt $bestDate) {
                $bestDate = $date
                $bestVer = $version
            }
        }
    }
    $title = [regex]::Match($dom, '<title>\s*([^<]+?)\s*(?:\(Rev\.[^)]*\)\s*)?Motherboard Support').Groups[1].Value.Trim()

    [pscustomobject]@{
        Slug        = $slug
        DomLength   = $dom.Length
        HasBiosSect = [bool]$bios
        RowCount    = $rowCount
        Version     = $bestVer
        Date        = if ($bestDate -gt [datetime]::MinValue) { $bestDate.ToString('yyyy-MM-dd') } else { '' }
        Name        = $title
        OldRegexHit = [regex]::IsMatch($dom, '(?s)>(F\d{1,2}[a-z]?)<.{0,400}?>([A-Z][a-z]{2} \d{1,2}, \d{4})<')
    }
}

$report = Join-Path $PSScriptRoot 'gb-parsing-report.csv'
$results | Export-Csv -Path $report -NoTypeInformation -Encoding UTF8
Write-Host "Saved $report"

$total = @($results).Count
$parsed = @($results | Where-Object { $_.Version })
Write-Host "Structural parse hit: $($parsed.Count)/$total (old regex would have hit $(@($results | Where-Object OldRegexHit).Count))"
Write-Host "Misses: $((@($results | Where-Object { -not $_.Version }) | ForEach-Object Slug) -join ', ')"
Write-Host "No page title: $((@($results | Where-Object { -not $_.Name }) | ForEach-Object Slug) -join ', ')"
Write-Host '--- sample of extractions ---'
$results | Where-Object Version | Select-Object -First 10 | ForEach-Object { Write-Host "  $($_.Slug) -> '$($_.Name)' $($_.Version) ($($_.Date))" }

if ($parsed.Count -lt [Math]::Max(10, [int]($total * 0.5))) {
    throw "Only $($parsed.Count) of $total sampled pages produced a stable BIOS."
}
if ($parsed | Where-Object { $_.Version -cmatch '[a-z]$' -or $_.Version -cmatch '\d[A-Z]$' }) {
    throw 'A beta-style Gigabyte BIOS escaped the stable-release filter.'
}

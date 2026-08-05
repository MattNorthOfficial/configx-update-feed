$ErrorActionPreference = 'Stop'

$tokens = $null
$errors = $null
$scriptPath = Join-Path $PSScriptRoot 'Update-Feed.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath, [ref] $tokens, [ref] $errors)
if ($errors.Count -gt 0) {
    throw "Update-Feed.ps1 does not parse: $($errors -join '; ')"
}

function Get-ScraperFunctionText([string] $name) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $name
    }, $true)
    if (-not $functionAst) {
        throw "Function '$name' was not found in Update-Feed.ps1."
    }
    return $functionAst.Extent.Text
}

Invoke-Expression (Get-ScraperFunctionText 'Read-JsonFromBrowserDom')
Invoke-Expression (Get-ScraperFunctionText 'Test-GigabyteBetaBios')
Invoke-Expression (Get-ScraperFunctionText 'Copy-BoardEntry')

$payload = '{"result":{"title":"MAG X870 TOMAHAWK WIFI","downloads":{"AMI BIOS":[]}}}'
$encoded = [System.Net.WebUtility]::HtmlEncode($payload)
$dom = "<html><head><script>window.noise={bad:true};</script></head><body><pre>$encoded</pre></body></html>"
$parsed = Read-JsonFromBrowserDom $dom
if ($parsed.result.title -ne 'MAG X870 TOMAHAWK WIFI') {
    throw 'The MSI JSON payload was not read from its explicit <pre> container.'
}
if (Read-JsonFromBrowserDom '<html><script>window.noise={bad:true};</script></html>') {
    throw 'Unrelated page braces were incorrectly accepted as an API response.'
}
if ((Read-JsonFromBrowserDom $payload).result.title -ne 'MAG X870 TOMAHAWK WIFI') {
    throw 'A raw JSON response was not accepted.'
}

if (-not (Test-GigabyteBetaBios 'F42c') -or
    -not (Test-GigabyteBetaBios 'F9A') -or
    (Test-GigabyteBetaBios 'F41') -or
    (Test-GigabyteBetaBios 'FA2')) {
    throw 'Gigabyte beta/stable classification failed.'
}

$copy = Copy-BoardEntry ([pscustomobject]@{
    bios = 'F41'
    date = '2026-05-21'
    revisionAmbiguous = $true
})
if (-not $copy.revisionAmbiguous -or $copy.bios -ne 'F41') {
    throw 'Board carry-forward dropped an additive safety field.'
}

Write-Host 'Feed parser helper tests passed.'

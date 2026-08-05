function Get-FeedMapEntries {
    param($Map)

    if ($null -eq $Map) {
        return @()
    }

    if ($Map -is [System.Collections.IDictionary]) {
        return @($Map.Keys | ForEach-Object {
            [pscustomobject]@{ Name = "$_"; Value = $Map[$_] }
        })
    }

    return @($Map.PSObject.Properties | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Value = $_.Value }
    })
}

function Test-FeedHttpsHost {
    param(
        [string] $Url,
        [string[]] $AllowedHosts
    )

    if (-not $Url) {
        return $false
    }

    try {
        $uri = [uri]$Url
        return $uri.Scheme -eq 'https' -and $AllowedHosts -contains $uri.Host
    }
    catch {
        return $false
    }
}

function Assert-FeedContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Feed
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    function Require([bool] $condition, [string] $message) {
        if (-not $condition) {
            $errors.Add($message)
        }
    }

    Require ($Feed.schemaVersion -eq 1) 'schemaVersion must be 1.'
    $updatedIsValid = $Feed.updated -is [datetime] -or
        $Feed.updated -is [datetimeoffset] -or
        "$($Feed.updated)" -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
    Require $updatedIsValid `
        'updated must be an ISO-8601 UTC timestamp.'

    Require ("$($Feed.communitySources.intelChipsetInf.repository)" -eq
        'FirstEverTech/Universal-Intel-Chipset-Updater') `
        'communitySources.intelChipsetInf.repository is invalid.'
    Require ("$($Feed.communitySources.intelChipsetInf.commit)" -match '^[0-9a-f]{40}$') `
        'communitySources.intelChipsetInf.commit must be a full Git commit.'
    Require ("$($Feed.communitySources.nvidiaGpuMap.repository)" -eq
        'ZenitH-AT/nvidia-data') `
        'communitySources.nvidiaGpuMap.repository is invalid.'
    Require ("$($Feed.communitySources.nvidiaGpuMap.commit)" -match '^[0-9a-f]{40}$') `
        'communitySources.nvidiaGpuMap.commit must be a full Git commit.'

    foreach ($key in @(
            'amd.windows', 'amd.chipset', 'windowsBuilds', 'windows10',
            'motherboards.msi', 'motherboards.gigabyte',
            'motherboards.asrock', 'motherboards.asus',
            'dell', 'intel.chipset', 'intel.arc', 'intel.xe',
            'intel.rst20', 'intel.rst21', 'intel.chipsetInf', 'nvidia')) {
        $value = $Feed.freshness.$key
        $valid = $value -is [datetime] -or
            $value -is [datetimeoffset] -or
            "$value" -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        Require $valid "freshness.$key must be an ISO-8601 UTC timestamp."
    }

    $amdBranches = @('current', 'rdna1-2', 'polaris-vega')
    foreach ($branch in $amdBranches) {
        $entry = $Feed.amd.windows.$branch
        Require ($null -ne $entry) "amd.windows.$branch is required."
        Require ("$($entry.adrenalin)" -match '^\d+(?:\.\d+){1,2}$') `
            "amd.windows.$branch.adrenalin is invalid."
        Require ("$($entry.driverStore)" -match '^\d+(?:\.\d+){2,3}$') `
            "amd.windows.$branch.driverStore is invalid."
    }

    Require ("$($Feed.amd.chipset.revision)" -match '^\d+(?:\.\d+){2,4}$') `
        'amd.chipset.revision is required.'
    $componentEntries = Get-FeedMapEntries $Feed.amd.chipset.components
    Require ($componentEntries.Count -ge 1) 'amd.chipset.components must not be empty.'
    foreach ($component in $componentEntries) {
        Require ("$($component.Value)" -match '^\d+(?:\.\d+){2,4}$') `
            "amd.chipset.components.$($component.Name) is invalid."
    }

    $windowsEntries = Get-FeedMapEntries $Feed.windowsBuilds
    Require ($windowsEntries.Count -ge 1) 'windowsBuilds must not be empty.'
    foreach ($version in $windowsEntries) {
        Require ("$($version.Value.build)" -match '^\d+\.\d+$') `
            "windowsBuilds.$($version.Name).build is invalid."
        foreach ($dateField in @('date', 'eosHome', 'eosEnterprise')) {
            $date = "$($version.Value.$dateField)"
            if ($date) {
                Require ($date -match '^\d{4}-\d{2}-\d{2}$') `
                    "windowsBuilds.$($version.Name).$dateField is invalid."
            }
        }
    }

    $boardEntries = Get-FeedMapEntries $Feed.motherboards
    Require ($boardEntries.Count -ge 500) `
        "motherboards contains only $($boardEntries.Count) entries; expected at least 500."
    $biosShape = '^[A-Za-z0-9][A-Za-z0-9._/+-]{0,19}$'
    $boardHosts = @('www.asus.com', 'www.gigabyte.com', 'www.asrock.com', 'pg.asrock.com')
    $boardVendors = @('msi', 'gigabyte', 'asrock', 'asus')
    foreach ($board in $boardEntries) {
        Require ("$($board.Value.bios)" -match $biosShape) `
            "motherboards.$($board.Name).bios is invalid."
        Require ("$($board.Value.date)" -match '^\d{4}-\d{2}-\d{2}$') `
            "motherboards.$($board.Name).date is invalid."
        if ($board.Value.vendor) {
            Require ($boardVendors -contains "$($board.Value.vendor)") `
                "motherboards.$($board.Name).vendor is invalid."
        }
        if ($null -ne $board.Value.revisionAmbiguous) {
            Require ($board.Value.revisionAmbiguous -is [bool]) `
                "motherboards.$($board.Name).revisionAmbiguous must be boolean."
        }
        if ($board.Value.url) {
            Require (Test-FeedHttpsHost "$($board.Value.url)" $boardHosts) `
                "motherboards.$($board.Name).url has an unexpected host."
        }
    }

    foreach ($conflict in Get-FeedMapEntries $Feed.motherboardConflicts) {
        $claims = Get-FeedMapEntries $conflict.Value
        Require ($claims.Count -ge 2) `
            "motherboardConflicts.$($conflict.Name) must carry at least two claims."
        foreach ($claim in $claims) {
            Require ($boardVendors -contains $claim.Name) `
                "motherboardConflicts.$($conflict.Name).$($claim.Name) has an invalid vendor key."
            Require ("$($claim.Value.bios)" -match $biosShape) `
                "motherboardConflicts.$($conflict.Name).$($claim.Name).bios is invalid."
        }
    }

    $dellEntries = Get-FeedMapEntries $Feed.dell
    Require ($dellEntries.Count -ge 100) `
        "dell contains only $($dellEntries.Count) entries; expected at least 100."
    foreach ($system in $dellEntries) {
        Require ($system.Name -match '^[0-9A-F]{4}$') "dell.$($system.Name) has an invalid system id."
        Require ("$($system.Value.bios)" -match $biosShape) "dell.$($system.Name).bios is invalid."
        Require (Test-FeedHttpsHost "$($system.Value.url)" @('downloads.dell.com')) `
            "dell.$($system.Name).url has an unexpected host."
    }

    foreach ($key in @('chipset', 'arc', 'xe', 'rst20', 'rst21')) {
        $entry = $Feed.intel.$key
        Require ("$($entry.version)" -match '^\d+(?:\.\d+){2,4}$') "intel.$key.version is invalid."
        Require (Test-FeedHttpsHost "$($entry.url)" @('www.intel.com')) `
            "intel.$key.url has an unexpected host."
        Require (Test-FeedHttpsHost "$($entry.download)" @('downloadmirror.intel.com')) `
            "intel.$key.download has an unexpected host."
    }

    $infEntries = Get-FeedMapEntries $Feed.intel.chipsetInf
    Require ($infEntries.Count -ge 100) `
        "intel.chipsetInf contains only $($infEntries.Count) entries; expected at least 100."
    foreach ($device in $infEntries) {
        Require ($device.Name -match '^[0-9A-F]{4}$') `
            "intel.chipsetInf.$($device.Name) has an invalid hardware id."
        Require ("$($device.Value)" -match '^\d+(?:\.\d+){2,3}$') `
            "intel.chipsetInf.$($device.Name) has an invalid version."
    }

    Require ("$($Feed.nvidia.gameReady)" -match '^\d+\.\d+$') 'nvidia.gameReady is invalid.'
    Require (Test-FeedHttpsHost "$($Feed.nvidia.url)" @('www.nvidia.com')) `
        'nvidia.url has an unexpected host.'
    Require (Test-FeedHttpsHost "$($Feed.nvidia.download)" @('us.download.nvidia.com')) `
        'nvidia.download has an unexpected host.'

    if ($errors.Count -gt 0) {
        throw "Feed contract validation failed:`n - $($errors -join "`n - ")"
    }

    return $true
}

Export-ModuleMember -Function Assert-FeedContract

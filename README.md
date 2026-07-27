# Win X driver feed

A small JSON feed of the latest AMD graphics driver versions, consumed by the
[Win X](https://github.com/MattNorthOfficial) app. AMD offers no public API for
driver releases, so a scheduled GitHub Action scrapes
[AMD GPUOpen's version table](https://gpuopen.com/version-table/) every six
hours and commits `feed/drivers.json` when a new release appears.

## Feed format

```json
{
  "updated": "2026-07-27T02:13:29Z",
  "source": "https://gpuopen.com/version-table/",
  "amd": {
    "windows": {
      "current":      { "adrenalin": "26.6.4", "whql": true, "driverStore": "32.0.31021.5001" },
      "rdna1-2":      { "adrenalin": "26.6.2", "whql": true, "driverStore": "32.0.21043.19003" },
      "polaris-vega": { "adrenalin": "26.5.2", "whql": true, "driverStore": "31.0.21925.1001" }
    }
  }
}
```

- `adrenalin` is the marketing version (what AMD's site shows).
- `driverStore` is the Windows driver-store version (what WMI / Device Manager
  reports), which lets a client match its installed driver to the right branch.
- `current` is the mainline release; `rdna1-2` and `polaris-vega` are the
  maintenance branches AMD keeps for older GPU generations.

## Consuming

Fetch the raw file:

```
https://raw.githubusercontent.com/MattNorthOfficial/winx-driver-feed/main/feed/drivers.json
```

## Running locally

```powershell
pwsh ./scripts/Update-Feed.ps1
```

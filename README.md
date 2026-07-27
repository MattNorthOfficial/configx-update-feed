# Win X update feed

A small JSON feed of the latest AMD driver versions and Windows builds,
consumed by the [Win X](https://github.com/MattNorthOfficial) app. Neither AMD
nor Microsoft offer a public API for this, so a scheduled GitHub Action scrapes
[AMD GPUOpen's version table](https://gpuopen.com/version-table/) (graphics),
[AMD's chipset driver page](https://www.amd.com/en/support/downloads/drivers.html/chipsets/am5/x870e.html)
plus its release notes (chipset), and
[Microsoft's Windows 11 release information](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information)
(OS builds) every six hours, and commits `feed/drivers.json` when a new
release appears.

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
    },
    "chipset": {
      "revision": "8.05.04.516",
      "date": "2026-05-18",
      "components": {
        "smbus": "2.0.0.26",
        "psp": "5.44.0.0",
        "ppm": "8.0.0.62",
        "vcache": "1.0.0.12",
        "gpio": "2.2.0.137",
        "i2c": "1.2.0.126",
        "ptgpio": "3.0.5.0",
        "compatdb": "1.0.0.3"
      }
    }
  },
  "windowsBuilds": {
    "25H2": { "build": "26200.8894", "date": "2026-07-18", "kb": "KB5121767" },
    "24H2": { "build": "26100.8894", "date": "2026-07-18", "kb": "KB5121767" }
  }
}
```

- `adrenalin` is the marketing version (what AMD's site shows).
- `driverStore` is the Windows driver-store version (what WMI / Device Manager
  reports), which lets a client match its installed driver to the right branch.
- `current` is the mainline release; `rdna1-2` and `polaris-vega` are the
  maintenance branches AMD keeps for older GPU generations.
- `chipset.revision` is the AMD Chipset Software bundle version; `components`
  holds the driver versions bundled in that release (SMBus/interface, PSP,
  PPM provisioning, 3D V-Cache optimizer, GPIO, I2C, Promontory GPIO, and the
  application compatibility database) as reported by PnP devices.
- `windowsBuilds` maps each Windows 11 version to its latest *required* build:
  Patch Tuesday (B) and out-of-band (OOB) releases count, optional D-week
  previews do not, so fully patched machines are never flagged as outdated.

## Consuming

Fetch the raw file:

```
https://raw.githubusercontent.com/MattNorthOfficial/winx-update-feed/main/feed/drivers.json
```

## Running locally

```powershell
pwsh ./scripts/Update-Feed.ps1
```

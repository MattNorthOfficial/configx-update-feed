# Rig X update feed

A small JSON feed of the latest driver versions, Windows builds, and BIOS
releases, consumed by the [Rig X](https://github.com/MattNorthOfficial) app.
None of the vendors offer a stable public API for this, so a scheduled GitHub
Action scrapes
[AMD GPUOpen's version table](https://gpuopen.com/version-table/) (graphics),
[AMD's chipset driver page](https://www.amd.com/en/support/downloads/drivers.html/chipsets/am5/x870e.html)
plus its release notes (chipset),
[Microsoft's Windows 11 release information](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information)
(OS builds), MSI's product support API (BIOS), Intel's download-center pages
(chipset INF utility and both graphics branches), and NVIDIA's driver-search
endpoint (GeForce Game Ready) every six hours, and commits
`feed/updates.json` when a new release appears.

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
  },
  "motherboards": {
    "MAG X870 TOMAHAWK WIFI": { "bios": "7E51v1A92", "date": "2026-07-01" },
    "MAG Z890 TOMAHAWK WIFI": { "bios": "7E32v1AD0", "date": "2026-07-27" }
  },
  "intel": {
    "chipset": { "version": "10.1.20398.8776", "url": "https://www.intel.com/content/www/us/en/download/19347/chipset-inf-utility.html", "download": "https://downloadmirror.intel.com/872506/SetupChipset.exe" },
    "arc":     { "version": "32.0.101.8864",   "url": "https://www.intel.com/content/www/us/en/download/785597/intel-arc-graphics-windows.html", "download": "https://downloadmirror.intel.com/923907/gfx_win_101.8864.exe" },
    "xe":      { "version": "32.0.101.7088",   "url": "https://www.intel.com/content/www/us/en/download/864990/intel-11th-14th-gen-processor-graphics-windows.html", "download": "https://downloadmirror.intel.com/922492/gfx_win_101.7088.exe" }
  },
  "nvidia": {
    "gameReady": "610.74",
    "url": "https://www.nvidia.com/en-us/drivers/details/274187/",
    "download": "https://us.download.nvidia.com/Windows/610.74/610.74-desktop-win10-win11-64bit-international-dch-whql.exe"
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
- `motherboards` maps board models (the clean marketing name; Rig X strips
  WMI's "(MS-7E51)"-style suffix before looking a board up) to the latest
  non-beta BIOS on the manufacturer's support page. The MSI board list is
  enumerated from MSI's products sitemap (every desktop board on AM4/AM5,
  LGA1200/1700/1851, and HEDT sockets - about 450 models), then each board's
  support panel supplies its official name and BIOS list. Gigabyte boards are
  curated with their canonical revision slugs (their server-rendered pages
  only exist at those addresses, so entries also carry a `url` the app links
  to). ASRock boards are curated with their platform segment; their BIOS
  pages derive from the model name. All of it goes through a headless
  Chrome/Edge since these sites reject plain HTTP clients. Boards that drop
  out of a sweep keep their last published entry. ASUS is handled entirely
  in the app, which queries ASUS's public BIOS API live for any board, so
  ASUS boards never need a feed entry.
- `intel` holds the chipset INF utility version plus the two graphics-driver
  branches Intel maintains since their 2025 split: `arc` (Arc cards and Core
  Ultra iGPUs) and `xe` (the legacy-support package for 11th-14th gen
  Iris Xe / UHD). Intel's pages sit behind the same bot protection as MSI's,
  so they also go through the headless browser.
- `nvidia.gameReady` is the latest GeForce Game Ready driver, which covers
  every GPU the current branch supports; Rig X uses it as the offline
  fallback for its per-GPU online lookup.
- `download` (Intel and NVIDIA entries) is the installer file itself, straight
  off the vendor's CDN, so the app can offer the download directly. AMD has no
  equivalent: its CDN rejects requests that don't come from its own pages.

## Consuming

Fetch the raw file:

```
https://raw.githubusercontent.com/MattNorthOfficial/rigx-update-feed/main/feed/updates.json
```

## Running locally

```powershell
pwsh ./scripts/Update-Feed.ps1
```

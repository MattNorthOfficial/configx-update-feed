# Config X update feed

A small JSON feed of the latest driver versions, Windows builds, and BIOS
releases, consumed by the [Config X](https://github.com/MattNorthOfficial) app.
None of the vendors offer a stable public API for this, so a scheduled GitHub
Action scrapes
[AMD GPUOpen's version table](https://gpuopen.com/version-table/) (graphics),
[AMD's chipset driver page](https://www.amd.com/en/support/downloads/drivers.html/chipsets/am5/x870e.html)
plus its release notes (chipset),
[Microsoft's Windows 11 release information](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information)
(OS builds), MSI's product support API (BIOS), Intel's download-center pages
(chipset INF utility and both graphics branches), and NVIDIA's driver-search
endpoint (GeForce Game Ready), and commits `feed/updates.json` when a new
release appears. The quick sections above refresh every six hours; the full
motherboard sweep (~2,900 pages across four vendors) runs once daily at
10:37 UTC - right after the Taiwanese workday, since all four board vendors
publish from Taiwan - with boards carrying forward between sweeps. A publish gate refuses a sweep whose
BIOS dates regress en masse (the signature of a vendor layout change parsing
wrong-but-plausible values), transient fetch failures retry once before a
board is left to carry forward, and each run writes a per-vendor summary to
the workflow's step summary. Every headless fetch is killed at its own
deadline and every vendor phase runs against a time budget, so a vendor that
starts stonewalling mid-sweep costs its own boards a carry-forward rather
than stalling the run.

## Feed format

```json
{
  "schemaVersion": 1,
  "updated": "2026-08-05T13:06:09Z",
  "source": "https://gpuopen.com/version-table/",
  "communitySources": {
    "intelChipsetInf": {
      "repository": "FirstEverTech/Universal-Intel-Chipset-Updater",
      "commit": "3ca0886aa5a60d58cd82c0e938028db9f131d840"
    },
    "nvidiaGpuMap": {
      "repository": "ZenitH-AT/nvidia-data",
      "commit": "a94a519be9ec15b972533e501e47d5e8d67100c5"
    }
  },
  "freshness": {
    "amd.windows": "2026-08-05T13:06:09Z",
    "motherboards.gigabyte": "2026-08-04T10:37:00Z"
  },
  "amd": {
    "windows": {
      "current":      { "adrenalin": "26.7.1", "whql": true, "driverStore": "32.0.31035.1003" },
      "rdna1-2":      { "adrenalin": "26.7.1", "whql": true, "driverStore": "32.0.21045.1000" },
      "polaris-vega": { "adrenalin": "26.5.2", "whql": true, "driverStore": "31.0.21925.1001" }
    },
    "chipset": {
      "revision": "8.07.16.1035",
      "date": "2026-07-30",
      "components": {
        "smbus": "2.0.0.29",
        "smbusAm4": "5.12.0.44",
        "psp": "5.46.0.0",
        "ppm": "8.0.0.62",
        "vcache": "1.0.0.12",
        "gpio": "2.2.0.137",
        "i2c": "1.2.0.131",
        "ptgpio": "3.0.5.0",
        "compatdb": "1.0.0.3"
      }
    }
  },
  "windowsBuilds": {
    "25H2": {
      "build": "26200.8894",
      "date": "2026-07-18",
      "kb": "KB5121767",
      "eosHome": "2027-10-12",
      "eosEnterprise": "2028-10-10"
    }
  },
  "windows10": {
    "22H2": { "eosHome": "2025-10-14", "eosEnterprise": "2025-10-14" }
  },
  "motherboards": {
    "B650 AORUS ELITE": {
      "bios": "F41",
      "date": "2026-05-21",
      "url": "https://www.gigabyte.com/Motherboard/B650-AORUS-ELITE-rev-10/support#support-dl-bios",
      "vendor": "gigabyte",
      "revisionAmbiguous": true
    }
  },
  "motherboardConflicts": {
    "B650M GAMING PLUS WIFI": {
      "msi": { "bios": "7E24v1E2", "date": "2026-07-06" },
      "gigabyte": { "bios": "F41", "date": "2026-05-21" }
    }
  },
  "dell": {
    "0A5C": {
      "bios": "1.15.0",
      "date": "2026-07-15",
      "url": "https://downloads.dell.com/FOLDER/example.exe"
    }
  },
  "intel": {
    "chipset": { "version": "10.1.20398.8776", "url": "https://www.intel.com/content/www/us/en/download/19347/chipset-inf-utility.html", "download": "https://downloadmirror.intel.com/872506/SetupChipset.exe" },
    "arc":     { "version": "32.0.101.8864",   "url": "https://www.intel.com/content/www/us/en/download/785597/intel-arc-graphics-windows.html", "download": "https://downloadmirror.intel.com/923907/gfx_win_101.8864.exe" },
    "xe":      { "version": "32.0.101.7088",   "url": "https://www.intel.com/content/www/us/en/download/864990/intel-11th-14th-gen-processor-graphics-windows.html", "download": "https://downloadmirror.intel.com/922492/gfx_win_101.7088.exe" },
    "rst20":   { "version": "20.2.6.1025.3",   "url": "https://www.intel.com/content/www/us/en/download/849936/intel-rapid-storage-technology-driver-installation-software-with-intel-optane-memory-12th-to-15th-gen-platforms.html", "download": "https://downloadmirror.intel.com/example/rst20.exe" },
    "rst21":   { "version": "21.1.0.1006.2",   "url": "https://www.intel.com/content/www/us/en/download/920456/intel-rapid-storage-technology-driver-installation-software-for-intel-core-ultra-series-3-platforms.html", "download": "https://downloadmirror.intel.com/example/rst21.exe" },
    "chipsetInf": { "7A23": "10.1.46.5" }
  },
  "nvidia": {
    "gameReady": "610.88",
    "url": "https://www.nvidia.com/en-us/drivers/",
    "download": "https://us.download.nvidia.com/Windows/610.88/610.88-desktop-win10-win11-64bit-international-dch-whql.exe"
  }
}
```

- `schemaVersion` changes only when a consumer-facing breaking change is
  introduced. Additive fields stay within the current version.
- `communitySources` records the immutable commits used for the Intel INF and
  NVIDIA product-ID maps. Runtime and scheduled jobs never consume moving
  upstream branches.
- `freshness` records the last successful check represented by each source
  section. Skipped or failed vendor phases retain their previous timestamp,
  so clients can distinguish a newly written feed from carried-forward data.
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
- `motherboards` maps board models (the clean marketing name; Config X strips
  WMI's "(MS-7E51)"-style suffix before looking a board up) to the latest
  non-beta BIOS on the manufacturer's support page. The MSI board list is
  enumerated from MSI's products sitemap (every desktop board on AM4/AM5,
  LGA1200/1700/1851, and HEDT sockets - about 450 models), then each board's
  support panel supplies its official name and BIOS list. The ASRock board
  list is enumerated from the catalog ASRock's own motherboard index embeds
  (every board on the same sockets - about 480 models); BIOS page URLs
  derive from the model name (slashes dropped, "Z790 Pro RS/D4" lives at
  "Z790 Pro RSD4"), Phantom Gaming-family boards resolve on pg.asrock.com,
  and a miss on one subdomain retries on the other since some lines moved
  without the catalog saying so. The Gigabyte board list is enumerated by
  walking the server-rendered pages of gigabyte.com's All-Series grid,
  which yields the canonical revision slugs their pages only exist at -
  swept unfiltered, every generation the grid lists (~780 boards resolve).
  Each board's BIOS list is read structurally from its support page
  (stable version schemes vary: "F41", "FA2"; trailing-letter beta builds
  such as "F42c" are excluded), boards are named from the page's own title,
  and entries carry a `url` the app links to. When several revision pages
  share one marketing name, `revisionAmbiguous` is set and Config X withholds
  the BIOS verdict/link rather than sending every revision to one file.
  All of it goes through a headless Chrome/Edge since these sites reject
  plain HTTP clients. ASUS boards (~900, every board the
  catalog lists, enumerated from the JSON API behind asus.com's product
  grid) are swept through ASUS's public GetPDBIOS API with plain requests;
  the app still checks ASUS live first and uses these entries as the
  offline fallback. Boards that drop out of a sweep keep their last
  published entry.
- `dell` maps Dell system ids (the 4-hex code every Dell and Alienware
  reports as its SKU) to the newest BIOS in Dell's own update catalog
  (`CatalogPC.cab`, the machine-readable source Dell Command Update reads;
  ~700 systems). Entries carry the version, date, and the official
  installer's download URL.
- `intel` holds the chipset INF utility version plus the two graphics-driver
  branches Intel maintains since their 2025 split: `arc` (Arc cards and Core
  Ultra iGPUs) and `xe` (the legacy-support package for 11th-14th gen
  Iris Xe / UHD). Intel's pages sit behind the same bot protection as MSI's,
  so they also go through the headless browser.
- `nvidia.gameReady` is the latest GeForce Game Ready driver, which covers
  every GPU the current branch supports; Config X uses it as the offline
  fallback for its per-GPU online lookup.
- `download` (Intel and NVIDIA entries) is the installer file itself, straight
  off the vendor's CDN, so the app can offer the download directly. AMD has no
  equivalent: its CDN rejects requests that don't come from its own pages.

## Consuming

Fetch the raw file, detached signature, and pinned public key:

```
https://raw.githubusercontent.com/MattNorthOfficial/configx-update-feed/main/feed/updates.json
https://raw.githubusercontent.com/MattNorthOfficial/configx-update-feed/main/feed/updates.sig
https://raw.githubusercontent.com/MattNorthOfficial/configx-update-feed/main/feed/public-key.txt
```

`updates.sig` is a Base64 ECDSA P-256/SHA-256 signature in IEEE P1363 format.
Config X verifies the exact response bytes before parsing or exposing any
version/download data. Current public-key SHA-256 fingerprint:
`5748dbf69e5a3fda65628b30aef1ea28972532285a296ccf491b0d6d39767f9d`.

## Running locally

PowerShell 7 is required. Chrome or Edge is needed for MSI, Gigabyte, ASRock,
and Intel; Dell catalog extraction also needs Windows `expand.exe` or `7z`.

```powershell
pwsh ./scripts/Test-FeedContract.ps1                      # validate current JSON, no network
pwsh ./scripts/Verify-FeedSignature.ps1                   # verify detached signature
pwsh ./scripts/Test-FeedSigning.ps1                       # ephemeral signing round trip
pwsh ./scripts/Test-FeedParsing.ps1                       # parser unit checks, no network
pwsh ./scripts/Test-MergeFeedPublication.ps1              # verify overlap merge, no network
pwsh ./scripts/Update-Feed.ps1 -BoardVendors none        # quick sections only
pwsh ./scripts/Update-Feed.ps1 -BoardVendors asus        # targeted board refresh
pwsh ./scripts/Update-Feed.ps1 -MaxParallel 3            # gentler full sweep
pwsh ./scripts/Test-GigabyteParsing.ps1                  # live stratified parser smoke test
```

## Updating community source pins

Review the upstream diff first, then replace the full commit in
`scripts/Update-Feed.ps1` (and the NVIDIA commit in Config X's
`UpdateCheckService.cs`). Run the parser, contract, and Config X test suites
before publishing. The chosen commits are written into `communitySources` so
every feed snapshot remains attributable and reproducible.

## Rotating the feed signing key

Key rotation changes Config X's trust root and therefore requires an app
release. After reviewing that coordinated change:

```powershell
pwsh ./scripts/Rotate-FeedSigningKey.ps1 `
  -ConfigXRepository "C:\path\to\ConfigX" `
  -ConfirmRotation
```

The private key is sent directly to the repository's
`FEED_SIGNING_KEY_PEM` Actions secret and is never written to disk. Commit the
new public-key files and signatures in both repositories together.

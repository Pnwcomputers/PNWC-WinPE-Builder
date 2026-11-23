# PNWC WinPE Builder

[![Repository checks](https://github.com/Pnwcomputers/PNWC-WinPE-Builder/actions/workflows/validate.yml/badge.svg)](https://github.com/Pnwcomputers/PNWC-WinPE-Builder/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/source-MIT-blue.svg)](LICENSE)

Build your own x64 Windows PE recovery media with a PowerShell launcher, optional portable tools, drivers, and updates. Maintained by Pacific Northwest Computers as a companion to the [Ultimate Cybersecurity Master Guide](https://github.com/Pnwcomputers/ULTIMATE-CYBERSECURITY-MASTER-GUIDE).

**Status: source alpha.** Automated checks validate source and safety helpers. A complete ADK build, boot, and every third-party tool have **not** been verified on physical hardware. See the [validation checklist](docs/VALIDATION.md) before using this on a client system.

## Purpose and limits

Use this project for Windows deployment/recovery, recovery-related system inventory, and authorized offline triage. It creates an ISO and can optionally prepare USB or fixed VHD media. Tools stay outside `boot.wim` under `Tools` and appear in a text launcher.

Microsoft limits Windows PE to deployment and recovery and says it should not be used for hardware validation. Stress tests and benchmarking belong in an appropriately licensed full Windows environment; those workflows from the original private script were removed. Read Microsoft's [WinPE overview and limitations](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-intro).

This is **not a forensic write blocker**. Booting a computer can change its disks, and rebooting destroys its prior volatile memory. Preserve evidence and acquire live data first when required. See [recovery and incident-response use](docs/CYBERSECURITY-INTEGRATION.md).

## Requirements

- An administrator session in **64-bit Windows PowerShell 5.1** on a supported x64 Windows host. PowerShell 7 is for repository checks, not building the image.
- Git, `curl.exe`, and Windows storage utilities (`dism`, `robocopy`, and, for VHD creation, `diskpart`).
- Microsoft's **Windows ADK Deployment Tools** and the **matching Windows PE add-on**, with current servicing patches. Get both from the [official ADK download page](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install). Use matching optional components, not CABs from another ADK release.
- A dedicated local build directory, such as `C:\PNWC-PE`, outside this checkout. Plan for tens of GB of free space, plus the entire requested fixed VHD size if used. Actual requirements depend on your tools and drivers.
- Internet access for automatic downloads, or your own reviewed x64 portable tools for an offline build. No Microsoft installers, tool binaries, signatures, rules, license keys, or customer data are included in Git.

## First build: ISO only

Clone or download this repository, review the script, install the prerequisites, then open **Windows PowerShell as administrator**:

```powershell
git clone https://github.com/Pnwcomputers/PNWC-WinPE-Builder.git
Set-Location PNWC-WinPE-Builder
Get-Help .\build-pnwc-winpe.ps1 -Full

# Builds with the tools you have staged; a fresh root produces the base launcher.
.\build-pnwc-winpe.ps1 -Root C:\PNWC-PE -SkipDownloads
```

To fetch optional portable tools:

```powershell
.\build-pnwc-winpe.ps1 -Root C:\PNWC-PE -SkipVentoyExtras
```

Downloading a tool does not prove it works in WinPE. Download failures appear in the tool summary; they can leave you with a usable base ISO missing optional tools. Review every `FAILED`, `WARN`, and `MANUAL` result before use.

Some preparation steps execute third-party programs on the elevated build host (7-Zip extraction, ClamAV signature updates, and KAPE synchronization). They are disabled unless you deliberately pass `-AllowToolExecution`. Review those binaries and their provenance before enabling it. Run builds on a dedicated disposable workstation or VM.

The main result is `C:\PNWC-PE\PNWC-PE.iso`. Logs and download hashes stay in `C:\PNWC-PE\Logs`; `Ventoy` holds a copy of the ISO and any requested extras. This builder does not install Ventoy or format a Ventoy disk automatically.

For boot files signed by Windows UEFI CA 2023, add `-BootEx` with a compatible ADK and firmware trust configuration. Microsoft's [MakeWinPEMedia reference](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/makewinpemedia-command-line-options) documents the option. Test the target firmware instead of assuming universal Secure Boot support.

## Supply your own data

Place inputs below the **build root**, not inside this Git repository:

```text
C:\PNWC-PE\Source\
  Drivers\Storage\           # extracted signed x64 INF driver packages
  Drivers\Network\
  Drivers\GPU\
  Updates\                   # applicable Microsoft .msu packages
  Drop\                      # optional legitimately obtained KAPE archive
  Tools\<Category>\<Tool>\   # reviewed portable tools and optional launch.txt
```

Use the [input checklist](data/required-inputs.json), [tool catalog](data/tools.json), and [manual-tool instructions](docs/TOOLS.md). Sample launcher files are in [examples](examples). Commercial entitlements and redistribution rights remain your responsibility; see [third-party notices](THIRD_PARTY_NOTICES.md).

## USB and VHD output

Start with an ISO and test it in a VM. USB creation **formats the selected target** and requires `-AllowUsbFormat`. Independently inspect the drive's model, capacity, contents, and disk number first:

```powershell
Get-Disk | Format-Table Number,FriendlyName,BusType,IsBoot,IsSystem,Size
Get-Volume | Format-Table DriveLetter,FileSystemLabel,FileSystem,Size

# Example only: replace E: with the verified expendable USB target.
.\build-pnwc-winpe.ps1 -Root C:\PNWC-PE -SkipDownloads -UsbDrive E: -AllowUsbFormat
```

For an IODD-style virtual disk, choose a **new** `.vhd` file on NTFS or exFAT:

```powershell
.\build-pnwc-winpe.ps1 -Root C:\PNWC-PE -SkipDownloads -VhdPath E:\VHD\PNWC-PE.vhd -VhdSizeGB 16
```

The fixed VHD reserves its entire size and uses a small FAT32 boot partition plus an NTFS tools/data partition. Reusing an existing project VHD requires `-AllowVhdRebuild`; its partition labels/layout must match. Unknown disks are rejected. Back up the VHD before rebuilding. USB and VHD boot paths require the manual checks in [validation](docs/VALIDATION.md).

## Options and troubleshooting

`-RefreshTools` replaces managed cached tools; `-SkipDownloads` uses local tools; `-SkipVentoyExtras` omits additional boot images; `-Lang` selects optional component resources; `-ScratchMB` controls WinPE scratch space. The script's `Get-Help` is the parameter reference.

- Missing ADK files: install Deployment Tools and its matching PE add-on.
- Missing storage/network device: stage the appropriate signed x64 driver and rebuild.
- A tool will not launch: confirm it is x64, portable, and compatible with WinPE. MSI installation, 32-bit apps, full desktop services, Java, or GPU drivers may be unavailable.
- Build directory refused: use a fresh dedicated root. The builder deliberately refuses to delete an unrecognized or redirected build tree.
- No persistent logs: ISO media is read-only; logs fall back to `X:\PNWC-Logs` and disappear on reboot. Copy needed logs to an explicitly chosen destination before shutting down.

## Development

```powershell
.\tests\Invoke-RepositoryChecks.ps1
.\tests\Invoke-SafetyTests.ps1
```

CI runs these checks on Windows PowerShell and PowerShell 7 without downloading third-party tools, mounting WIMs, or writing boot media. See [CONTRIBUTING](CONTRIBUTING.md), [SECURITY](SECURITY.md), and the [changelog](CHANGELOG.md). Only original project source is covered by the [MIT license](LICENSE).

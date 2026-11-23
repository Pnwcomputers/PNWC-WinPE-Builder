# 🛠️ PNWC WinPE Builder

<p align="center"><strong>PACIFIC NORTHWEST COMPUTERS</strong></p>

<p align="center"><strong>Windows Deployment & Recovery · Offline Triage · Build Your Own Boot Media</strong></p>

<p align="center">
  <a href="https://github.com/Pnwcomputers/PNWC-WinPE-Builder/actions/workflows/validate.yml"><img src="https://github.com/Pnwcomputers/PNWC-WinPE-Builder/actions/workflows/validate.yml/badge.svg" alt="Repository checks"/></a>
  <img src="https://img.shields.io/badge/Status-Source_Alpha-orange" alt="Status: source alpha"/>
  <img src="https://img.shields.io/badge/Platform-Windows_x64-blue" alt="Platform: Windows x64"/>
  <img src="https://img.shields.io/badge/Builder-Windows_PowerShell_5.1-5391FE" alt="Builder: Windows PowerShell 5.1"/>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/Source-MIT-green" alt="Original source license: MIT"/></a>
</p>

> **Build your own x64 Windows PE recovery media with a PowerShell launcher, optional portable tools, drivers, and updates.**
>
> A companion project to the **[Ultimate Cybersecurity Master Guide](https://github.com/Pnwcomputers/ULTIMATE-CYBERSECURITY-MASTER-GUIDE)**, maintained by Pacific Northwest Computers.

> [!WARNING]
> **Status: source alpha.** Automated checks validate source and safety helpers. A complete ADK build, boot, and every third-party tool have **not** been verified on physical hardware. Follow the [validation checklist](./docs/VALIDATION.md) before using this on a client system.

---

## 🎯 Purpose

Create locally built Windows deployment and recovery media for recovery-related system inventory and authorized offline triage.

## ⚙️ Function

Build an x64 WinPE ISO from Microsoft's ADK and matching PE add-on, inject supplied drivers and updates, and add a text launcher for optional tools. Tools stay outside `boot.wim` under `Tools`. USB and fixed VHD output are optional.

## 🏆 Goal

Make the recovery build process documented, reviewable, and repeatable while keeping licensed software, private inputs, and customer data outside the public repository.

## 🧭 Start Here

| I Want To... | Start Here |
| --- | --- |
| Build My First Recovery ISO | [Requirements](#requirements) → [ISO Build](#first-build-iso-only) |
| Add Drivers, Updates & Portable Tools | [Supply Your Own Data](#supply-your-own-data) |
| Prepare USB Or IODD-Style VHD Media | [USB & VHD Output](#usb-and-vhd-output) |
| Use This Within Incident Response | [Recovery & Incident-Response Integration](./docs/CYBERSECURITY-INTEGRATION.md) |
| Check Readiness Before Field Use | [Validation Checklist](./docs/VALIDATION.md) |
| Contribute Or Report An Issue | [Contributing](./CONTRIBUTING.md) · [Security Policy](./SECURITY.md) |

## 📋 Table Of Contents

- [Scope & Evidence Limits](#purpose-and-limits)
- [Requirements](#requirements)
- [First Build: ISO Only](#first-build-iso-only)
- [Supply Your Own Data](#supply-your-own-data)
- [USB & VHD Output](#usb-and-vhd-output)
- [Options & Troubleshooting](#options-and-troubleshooting)
- [Development & Validation](#development)

---

<a id="purpose-and-limits"></a>

## ⚖️ Scope & Evidence Limits

Microsoft limits Windows PE to deployment and recovery and says it should not be used for hardware validation. Stress tests and benchmarking belong in an appropriately licensed full Windows environment; those workflows from the original private script were removed. Read Microsoft's [WinPE overview and limitations](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-intro).

> [!CAUTION]
> This is **not a forensic write blocker**. Booting a computer can change its disks, and rebooting destroys its prior volatile memory. Preserve evidence and acquire live data first when required. See [recovery and incident-response use](./docs/CYBERSECURITY-INTEGRATION.md).

<a id="requirements"></a>

## 🧰 Requirements

| Requirement | What You Need |
| --- | --- |
| Build Host & Shell | An administrator session in **64-bit Windows PowerShell 5.1** on a supported x64 Windows host. PowerShell 7 is for repository checks, not building the image. |
| Local Utilities | Git, `curl.exe`, and Windows storage utilities: `dism`, `robocopy`, and, for VHD creation, `diskpart`. |
| Microsoft Build Components | **Windows ADK Deployment Tools** and the **matching Windows PE add-on**, with current servicing patches. Obtain both from the [official ADK download page](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install). Use matching optional components, not CABs from another ADK release. |
| Dedicated Build Directory | A local directory such as `C:\PNWC-PE`, outside this checkout. Plan for tens of GB free, plus the entire requested fixed VHD size. Actual requirements depend on your tools and drivers. |
| Tool Sources | Internet access for automatic downloads, or your own reviewed x64 portable tools for an offline build. |

No Microsoft installers, tool binaries, signatures, rules, license keys, or customer data are included in Git.

<a id="first-build-iso-only"></a>

## 🚀 First Build: ISO Only

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

Some preparation steps execute third-party programs on the elevated build host: 7-Zip extraction, ClamAV signature updates, and KAPE synchronization. They are disabled unless you deliberately pass `-AllowToolExecution`. Review those binaries and their provenance before enabling it. Run builds on a dedicated disposable workstation or VM.

| Output | Default Location & Behavior |
| --- | --- |
| Recovery ISO | `C:\PNWC-PE\PNWC-PE.iso` |
| Build Logs & Download Hashes | `C:\PNWC-PE\Logs` |
| Ventoy Staging | `C:\PNWC-PE\Ventoy` holds a copy of the ISO and any requested extras. The builder does not install Ventoy or format a Ventoy disk automatically. |

For boot files signed by Windows UEFI CA 2023, add `-BootEx` with a compatible ADK and firmware trust configuration. Microsoft's [MakeWinPEMedia reference](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/makewinpemedia-command-line-options) documents the option. Test the target firmware instead of assuming universal Secure Boot support.

<a id="supply-your-own-data"></a>

## 📂 Supply Your Own Data

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

| Resource | Description |
| --- | --- |
| [Required Input Checklist](./data/required-inputs.json) | Microsoft prerequisites, optional local inputs, and data to keep private. |
| [Tool Catalog](./data/tools.json) | Acquisition recipes and unverified WinPE compatibility status. |
| [Tool Preparation Guide](./docs/TOOLS.md) | Manual tools, dependencies, and preparation instructions. |
| [Launcher Examples](./examples/README.md) | Sample entries for your own portable tools. |
| [Third-Party Notices](./THIRD_PARTY_NOTICES.md) | Commercial entitlements, vendor terms, and redistribution considerations. |

Commercial entitlements and redistribution rights remain your responsibility.

<a id="usb-and-vhd-output"></a>

## 💾 USB & VHD Output

Start with an ISO and test it in a VM. USB and VHD boot paths require the manual checks in [validation](./docs/VALIDATION.md).

### USB Media

> [!CAUTION]
> USB creation **formats the selected target** and requires `-AllowUsbFormat`. Independently inspect the drive's model, capacity, contents, and disk number first.

```powershell
Get-Disk | Format-Table Number,FriendlyName,BusType,IsBoot,IsSystem,Size
Get-Volume | Format-Table DriveLetter,FileSystemLabel,FileSystem,Size

# Example only: replace E: with the verified expendable USB target.
.\build-pnwc-winpe.ps1 -Root C:\PNWC-PE -SkipDownloads -UsbDrive E: -AllowUsbFormat
```

### Fixed VHD Media

For an IODD-style virtual disk, choose a **new** `.vhd` file on NTFS or exFAT:

```powershell
.\build-pnwc-winpe.ps1 -Root C:\PNWC-PE -SkipDownloads -VhdPath E:\VHD\PNWC-PE.vhd -VhdSizeGB 16
```

The fixed VHD reserves its entire size and uses a small FAT32 boot partition plus an NTFS tools/data partition. Reusing an existing project VHD requires `-AllowVhdRebuild`; its partition labels/layout must match. Unknown disks are rejected. Back up the VHD before rebuilding.

<a id="options-and-troubleshooting"></a>

## ⚙️ Options & Troubleshooting

The script's `Get-Help` is the parameter reference.

| Option | Purpose |
| --- | --- |
| `-Root` / `-IsoName` | Select the dedicated build root and ISO filename. |
| `-SkipDownloads` | Use locally staged tools. |
| `-RefreshTools` | Replace managed cached tools. |
| `-SkipVentoyExtras` | Omit additional boot images. |
| `-AllowToolExecution` | Permit the documented third-party preparation helpers on the build host. |
| `-BootEx` | Request Windows UEFI CA 2023 boot files with a compatible ADK. |
| `-UsbDrive` / `-AllowUsbFormat` | Select and explicitly authorize formatting an expendable USB target. |
| `-VhdPath` / `-VhdSizeGB` | Select the fixed VHD path and size. |
| `-AllowVhdRebuild` | Authorize rebuilding a recognized existing project VHD. |
| `-Lang` / `-ScratchMB` | Select optional-component resources and WinPE scratch space. |

| Problem | What To Check |
| --- | --- |
| Missing ADK Files | Install Deployment Tools and its matching PE add-on. |
| Missing Storage Or Network Device | Stage the appropriate signed x64 driver and rebuild. |
| A Tool Will Not Launch | Confirm it is x64, portable, and compatible with WinPE. MSI installation, 32-bit apps, full desktop services, Java, or GPU drivers may be unavailable. |
| Build Directory Refused | Use a fresh dedicated root. The builder deliberately refuses to delete an unrecognized or redirected build tree. |
| No Persistent Logs | ISO media is read-only; logs fall back to `X:\PNWC-Logs` and disappear on reboot. Copy needed logs to an explicitly chosen destination before shutting down. |

<a id="development"></a>

## 🧪 Development & Validation

```powershell
.\tests\Invoke-RepositoryChecks.ps1
.\tests\Invoke-SafetyTests.ps1
```

CI runs these checks on Windows PowerShell and PowerShell 7 without downloading third-party tools, mounting WIMs, or writing boot media. These checks do not replace a complete ADK build, boot test, or third-party tool validation.

| Resource | Description |
| --- | --- |
| [Validation Checklist](./docs/VALIDATION.md) | Record build, boot, hardware, and tool checks for the exact image. |
| [Contributing](./CONTRIBUTING.md) | Development workflow and contribution expectations. |
| [Security Policy](./SECURITY.md) | Report security issues without exposing sensitive data. |
| [Changelog](./CHANGELOG.md) | Project changes and current limitations. |
| [MIT License](./LICENSE) | Covers original project source only; third-party terms remain separate. |

---

<p align="center"><strong>🛠️ Build Locally · Review Your Inputs · Validate Before Field Use</strong></p>

[⬅️ Ultimate Cybersecurity Master Guide](https://github.com/Pnwcomputers/ULTIMATE-CYBERSECURITY-MASTER-GUIDE) | [Recovery & Incident-Response Integration](./docs/CYBERSECURITY-INTEGRATION.md) | [Third-Party Notices](./THIRD_PARTY_NOTICES.md)

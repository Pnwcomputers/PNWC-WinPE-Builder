# Tools, rules and signatures

The executable catalog lives in `build-pnwc-winpe.ps1`. [data/tools.json](../data/tools.json) is its documentation inventory. It lists acquisition recipes, not a locked or certified toolset. Vendor pages and release names can change, so review the per-build results.

## Acquisition and trust

The builder uses HTTPS vendor links, official project release APIs, and selected publisher mirrors. GitHub asset digests are checked when supplied; other files may only have a locally recorded hash. Hash logging is not vendor authentication. Independently verify publisher signatures or published checksums before executing binaries. Scraped/latest URLs and caches are not a reproducible dependency lock.

`-AllowToolExecution` enables third-party preparation programs on the elevated build host. Without it, operations that require 7-Zip execution, ClamAV updating, or KAPE synchronization are skipped/reported. Ordinary archive extraction and file downloads do not imply the binaries are safe to execute later in WinPE.

Tool downloads are optional. `-SkipDownloads` avoids acquisition and uses staged local files. `-RefreshTools` replaces builder-managed tool copies, so keep custom tools in separate folders. The launcher accepts local `launch.txt` files; see [examples](../examples/README.md).

## Required ancillary data

| Tool | Data to supply or verify | Recovery use and caveats |
| --- | --- | --- |
| ClamAV | Current `database/*.cvd` or `*.cld` signatures; freshclam can update with explicit execution opt-in. | A missing/outdated database makes scanning ineffective. The menu opens a console; choose an explicit offline target and database. Do not enable deletion/quarantine on evidence. |
| Hayabusa | Matching upstream release rules/configuration, or a separately reviewed pinned rule checkout. | Analyze copied EVTX files with explicit paths; a PE boot does not provide the previous OS's live event stream. |
| Chainsaw | Upstream mappings and compatible Sigma rules, if the downloaded release does not include them. | Keep a record of rule versions. Obtaining the executable alone does not create a complete hunting workflow. |
| Velociraptor | A reviewed offline collector configuration/artifact set matching the case. | The generic executable/help entry is not a configured collector. Do not assume all live-OS artifacts work against an offline Windows volume. |
| KAPE | A legitimately obtained KAPE zip, reviewed Targets/Modules, and any separately required external tools. | `--sync` requires execution opt-in; verify its result. Point acquisition at the identified offline source and write output to separate case media. |
| Manual forensic/recovery tools | Vendor package, notices, entitlement, and dependencies. | WinPE compatibility and x64 architecture need individual testing. No download gates are bypassed. |

Upstream references: [ClamAV documentation](https://docs.clamav.net/), [Hayabusa](https://github.com/Yamato-Security/hayabusa), [Chainsaw](https://github.com/WithSecureOpenSource/chainsaw), [Sigma rules](https://github.com/SigmaHQ/sigma), [Velociraptor offline collection](https://docs.velociraptor.app/docs/offline_triage/), and [KapeFiles](https://github.com/EricZimmerman/KapeFiles). These sources and their licenses can change; record the exact versions used on each engagement. Kroll's current [KAPE terms](https://www.kroll.com/en/services/cyber/reactive-services/kroll-artifact-parser-and-extractor-kape) exclude third-party paid work; this project does not establish an entitlement for client engagements.

## Compatibility

An x64 PE image cannot run 32-bit utilities. Full Windows services, GPU acceleration, shell integrations, MSI installers, and some runtimes are unavailable. Driver-dependent monitoring programs may fail even when their executable launches. A menu entry is not a compatibility certification.

Use deployment/recovery tasks only. CPU/GPU stress testing, burn-in and benchmarking from the earlier private script were removed because they do not fit Microsoft's WinPE scope. Use a suitable full Windows environment for those tasks.

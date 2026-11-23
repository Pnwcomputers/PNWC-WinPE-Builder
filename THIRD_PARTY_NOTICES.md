# Third-party software and data

The MIT license covers original project source and documentation only. It grants no rights to Microsoft Windows PE, ADK files, vendor applications, signatures, drivers, rules, or license keys. No such payload is distributed by this repository. Build your own media from legitimate sources and review terms before copying it to colleagues, customers, or a public release.

Microsoft documents WinPE's deployment/recovery scope and limitations in the [WinPE overview](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-intro). Obtain ADK and the matching add-on through [Microsoft](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) and follow their accompanying terms. Hardware stress testing and benchmarks are outside this project's WinPE workflow.

The machine-readable [tool inventory](data/tools.json) records upstream projects and acquisition methods. Inventory entries mean the builder has an acquisition recipe; they do not mean compatibility, redistribution permission, commercial-use entitlement, or endorsement has been established.

Examples of terms that need separate attention:

- [Sysinternals](https://learn.microsoft.com/en-us/sysinternals/license-terms): review the suite's license and each tool's EULA. The launcher does not automatically accept them.
- [HWiNFO](https://www.hwinfo.com/licenses/): commercial use requires an appropriate Engineer or Corporate Pro entitlement; Personal Pro does not cover commercial use. Review current terms before staging it.
- [KAPE](https://www.kroll.com/en/services/cyber/reactive-services/kroll-artifact-parser-and-extractor-kape): Kroll's current page excludes third-party paid engagements from its available use. Do not assume that purchasing an edition authorizes client work. Confirm your exact use with Kroll. The builder can consume a local archive for permitted uses; it does not bypass the download form.
- FTK Imager, R-Studio, DMDE, Emsisoft, GPU-Z, Recuva, and other manual tools: obtain from the original publisher and check current edition-specific terms. A public download is not blanket permission to redistribute.
- [ClamAV](https://docs.clamav.net/), [Hayabusa](https://github.com/Yamato-Security/hayabusa), [Chainsaw](https://github.com/WithSecureOpenSource/chainsaw), and [Velociraptor](https://github.com/Velocidex/velociraptor): application licenses and separately supplied databases, rules, mappings, or artifacts may differ. Keep upstream notices with any local copy where required.

Do not place commercial license keys, including PassMark `key.dat`, in Git. The automatic PassMark installation/license-copy routine in the original private script was removed from this public recovery project.

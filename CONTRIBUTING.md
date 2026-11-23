# Contributing

Open an issue or pull request with the problem, Windows/ADK versions, expected behavior, and a redacted reproduction. Keep changes focused. Do not include customer identifiers, disk images, malware samples, license files, credentials, or tool binaries.

Run `tests/Invoke-RepositoryChecks.ps1` and `tests/Invoke-SafetyTests.ps1` in both Windows PowerShell 5.1 and PowerShell 7. These tests never invoke the builder. A change to disk operations needs negative tests for rejected targets and independent review. After catalog changes, run `scripts/Export-ToolInventory.ps1` to update `data/tools.json`; it describes sources, not redistribution permission.

Document manual build/boot testing using [docs/VALIDATION.md](docs/VALIDATION.md), including ADK build, host version, firmware mode, and tool versions. Say explicitly what was not tested. Test on disposable media; do not use client disks for development.

Keep the public release source-only. Review third-party download destinations and signatures/checksums. Latest-release URLs and scraped pages are deliberately not a reproducible dependency lock; do not claim byte-for-byte reproducibility.

Submitting a contribution means you have the right to share it under the project's MIT license. Third-party software retains its own terms.

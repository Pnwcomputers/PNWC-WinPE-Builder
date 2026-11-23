# Security policy

The current alpha source is maintained on `main`. There is no production support or guaranteed response time.

Report vulnerabilities privately through [GitHub private vulnerability reporting](https://github.com/Pnwcomputers/PNWC-WinPE-Builder/security/advisories/new). If that option is unavailable, contact the maintainer through the [Pnwcomputers profile](https://github.com/Pnwcomputers) for a private channel. Do not publish working credentials, client data, or weaponized payloads in an issue.

Useful reports include the affected commit, attack prerequisites, impact, and a minimal sanitized reproduction. Relevant risks include unsafe drive selection, path traversal or reparse points, untrusted launcher input, downloader verification, elevated tool execution, and inadvertent inclusion of secrets in published artifacts.

The builder and WinPE launcher run with administrative capabilities. `launch.txt`, `tools.csv`, optional archives, drivers, and manually staged tools are trusted local code/configuration. Review them as code. HTTPS and a recorded hash provide transport/provenance evidence; a self-computed hash alone does not authenticate a vendor. Verify vendor signatures or independently published digests before executing downloaded programs.

WinPE is not forensic write-blocked, and reports may contain serial numbers, MAC addresses, or other identifiers. Store and share them according to the engagement's data-handling requirements.

# Recovery and incident-response integration

This builder complements the [Ultimate Cybersecurity Master Guide](https://github.com/Pnwcomputers/ULTIMATE-CYBERSECURITY-MASTER-GUIDE) when Windows cannot boot or an authorized response plan calls for offline recovery. Its role is preparation of recovery media, recovery-related inventory, and access to reviewed portable tools.

| Guide area | Appropriate use | Boundary |
| --- | --- | --- |
| Incident response | Prepare trusted media in advance; access a non-booting Windows installation after preservation decisions. | Preserve live evidence before rebooting; this is not a live-response platform. |
| Digital forensics | Use approved offline tools against identified images or protected source media. | No built-in forensic write blocking, case management, or chain-of-custody enforcement. |
| Malware analysis and hunting | Inspect copies of offline logs/files with reviewed signatures and rules. | The builder does not provide malware samples, detection guarantees, or automatic remediation. |
| Disaster recovery | Verify storage/network access, recover files, inspect encryption state, and assist an approved restoration. | Recovery/repair tools can change disks. Acquire a copy and record planned changes first. |
| Technician toolkit | Maintain a source-controlled media recipe and local input checklist. | Hardware validation and stress testing belong in full Windows, outside this WinPE workflow. |

## Suggested sequence

1. Confirm authorization, scope, identifiers, and the evidence/retention plan.
2. Decide whether live memory, active sessions, encryption keys, or other volatile data must be collected before shutdown. Rebooting into PE loses the prior live state.
3. Build media on a trusted dedicated workstation. Verify downloaded binaries and record versions, hashes, drivers, signatures, and rule revisions. Test on representative disposable hardware.
4. Use a hardware write blocker or an approved forensic acquisition workflow when source preservation requires it. This WinPE image does not enforce that protection.
5. Identify disks by model/serial/capacity and volumes by contents. Drive letters in PE can differ from installed Windows. Obtain BitLocker recovery material through the approved channel; do not commit it to Git.
6. Store case output on explicitly selected separate media. Review tool arguments before running them; many recovery utilities can write to their target.
7. Copy any RAM-drive logs before shutdown, hash collected artifacts, and record operator/time/tool versions. Sanitize reports before sharing.

## Media and data separation

Booting an ISO gives read-only boot media, not read-only internal disks. The launcher stores logs beside a writable recognized `Tools` directory when possible, otherwise in volatile `X:\PNWC-Logs`. Choose and document a case destination yourself. Do not rely on automatic discovery of arbitrary attached disks.

Never upload a built client-specific ISO, configured collector, evidence, hardware report, commercial key, or event log to this public repository. The source-only recipe and documentation are the integration point; tool payloads and case data stay local.

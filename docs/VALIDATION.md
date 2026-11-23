# Validation and release acceptance

## Current evidence

The initial release is an alpha source recipe. Parser checks and safety-helper tests can run without the ADK. They do not establish that an image builds, boots, works with a particular Secure Boot configuration, or supports every downloaded tool. Do not describe an unperformed check as passed.

## Automated checks

Run both scripts from the repository root in Windows PowerShell 5.1 and PowerShell 7:

```powershell
.\tests\Invoke-RepositoryChecks.ps1
.\tests\Invoke-SafetyTests.ps1
```

These checks parse source (including the embedded launcher), validate data and repository hygiene, and test path/target rejection without invoking DISM, mounting images, downloading tools, or formatting disks. CI runs the same checks. GitHub Actions dependencies are pinned by commit and maintained with Dependabot.

## Manual acceptance checklist

Record the commit/tag, Windows host build, PowerShell version/bitness, exact ADK/add-on/patch versions, tool versions and hashes, rule/signature dates, driver versions, firmware mode, and test date. Use disposable media and a VM or test machine with no client data.

- [ ] Fresh-root base ISO build using `-SkipDownloads`; check exit status, transcript, WIM unmount, ISO output, launcher, reboot and shutdown.
- [ ] Rebuild the same owned root; verify unknown build directories and reparse points are rejected.
- [ ] Online acquisition with and without `-AllowToolExecution`; inspect every result and download hash; confirm failures are visible.
- [ ] Boot the ISO in a VM in UEFI mode, then representative hardware; verify keyboard, display, storage, PowerShell, network drivers, and recovery-related inventory.
- [ ] Test Secure Boot with the intended certificate trust; test `-BootEx` separately. Legacy BIOS is a separate test where supported.
- [ ] Confirm every selected portable tool and its dependencies/rules/signatures work against disposable offline test data. Record incompatible tools rather than hiding failures.
- [ ] Confirm read-only ISO logs remain in RAM and writable tools media logs stay on that media; copy logs before reboot.
- [ ] Validate USB rejection cases before testing an expendable removable USB with explicit formatting opt-in. Check FAT32 per-file limits and boot behavior.
- [ ] Create a new VHD, boot it through the actual IODD/device, then rebuild an owned VHD with explicit opt-in; verify tools and intended retained data. Confirm unknown VHD layouts are rejected.
- [ ] Confirm no licensed payload, customer data, key, or binary image is present in the Git diff or release assets.

## Known constraints

Third-party sites and release selectors can change; there is no complete pinned download lock. Locally calculated hashes do not independently authenticate upstream binaries. Some applications require full Windows, 32-bit support, services, or hardware drivers not available in PE. Firmware boot and fixed VHD layouts depend on the actual device. Microsoft updates may have prerequisites or ordering requirements; stage only packages applicable to your image and validate the result.

# Synthetic Btrfs handoff on the M4

The isolated HVF experiment passed staging and verification after a second boot on 2026-09-28 UTC. This demonstrates the current ciphertext publisher on a real Btrfs filesystem inside a disposable Linux VM. Native first-boot encryption, owner provisioning, and the complete migration journey remain unproven.

## Observed result

| Check | Result |
| --- | --- |
| Synthetic target | 2 GiB regular host file presented as a uniquely marked virtio disk |
| Initial Btrfs size | 268,435,456 bytes (256 MiB) |
| Initial available space | 183,500,800 bytes (175 MiB) |
| Encrypted payload | 402,755,766 bytes, larger than initial available space |
| Planned and observed Btrfs growth | 772,800,512 bytes (737 MiB), within the synthetic target |
| Insufficient-capacity preflight | Smaller target rejected by capacity arithmetic before growth; this is not a physical ENOSPC test |
| Deliberate publication interruption | Raised after 1,048,576 bytes; no readiness marker appeared |
| Resume | Copied exactly the remaining 401,707,190 bytes; complete readback and age authentication passed |
| Second boot | Filesystem UUID, receipt/digest, complete ciphertext authentication, and grown size matched |
| Factory fixture | Sentinel digest and read-only subvolume property preserved |
| Stop after both phases | Btrfs unmounted, root remounted read-only, owned QEMU exited successfully |

The experiment boots a separate factory-derived guest with 2 vCPUs and 3 GiB RAM. It attaches only its own 6 GiB root, read-only test input archive, and synthetic target. No network, Mac folder share, personal VM disk, or native installation partition is attached. Formatting is gated on the lab kernel marker, target serial, exact device size, available Btrfs kernel support, and absence of an existing filesystem signature.

## Identities and retained evidence

Run ID: `91e9507e20af3cf9`. Preparation completed at `2026-09-28T00:19:40.508806+00:00`; staging at `00:20:01.265231+00:00`; second-boot verification at `00:20:19.073132+00:00`.

- Host: Apple M4, macOS 26.6.2 arm64, bundled QEMU 11.1.1 using HVF.
- Guest: kernel `7.2.6-1-aarch64-ARCH`, Python 3.14.7, Btrfs tools 7.1; cryptsetup 2.8.8 was present but was not exercised.
- Factory manifest SHA-256: `719d716625909cad5cfd879bf10c8bd2244be4603db6e82e81124d4470b3e9cb`.
- Original factory root SHA-256: `963494828e226a9890ba2a8bd246d7ffaaf6699c313bcd76dc2f47e56c429b2e`.
- Read-only input archive: 6,850,560 bytes; SHA-256 `87f25a02e2e9686feb7125b7270a46650ca7ecc135f5ad93b902b45054b31cb0`.
- Host harness SHA-256: `922e3d23710dda695d205af8b0bf8c7420c2da3ce0ffee2e65eedc0069fb359e`.
- Guest harness SHA-256: `7c495bb9212371832b8a4591901e696adde441f90a8a7ff05fd518351ea17ce3`.
- Btrfs package SHA-256: `059eae37c827cdcfe5830926af389794b2dcbdb72dcef8144d4b31884c3a7174`; repository checksum and detached signature were verified before extracting two tools. Nothing was installed on the Mac or into its personal Try guest.

The executed staging modules and crypto probe match their bytes in source commit `9f779fc448a538a629fd541a86fc20231c37660e`. The host/guest orchestration is an additional disposable lab harness, identified above; it has not been packaged as a public runner. Its source, input manifest, full console logs, phase receipts, and evidence hashes are retained with the project lab records. The public branch contains this sanitized result and the tested component implementations.

An earlier run on the same factory guest passed all 18 encrypted-bundle unit tests, then failed a device-identity guard before formatting. Those tests were not unnecessarily repeated: the successful run checked the earlier evidence-log hash, factory identity, and unchanged probe/test/age identities. Kernel and initramfs hashes were checked before each successful boot. The retained phase receipts bind both successful phases to the same input manifest.

## Limits and next gates

The injected interruption was a caught exception in one guest process, not a VM crash or power loss. The clean stop used a maintenance shell, filesystem unmount/remount, and QMP quit; it was not a normal Try desktop shutdown. The factory check covered a synthetic sentinel/read-only subvolume, not an entire native sealed image.

The guest had the whole synthetic target. This run did not exercise the bounded QEMU broker or GPT selection; their separate source tests do not establish combined VM isolation. No root shrink, LUKS conversion, native owner/default initialization, real data capture, application restore, or physical installation was performed. M4 VM evidence does not change native hardware eligibility.

This is an additional step toward the native staging gate, not completion of it. A [runnable integration fixture](../../packages/omarchy-migration/docs/FIXTURE.md) is now available separately. Remaining work includes the production shared export/restore interface, exact-image native boot/encryption qualification, and durable controller recovery.

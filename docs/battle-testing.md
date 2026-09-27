# Installer battle testing

This source review starts from `7a61e0a604ae812ddf9c1ff0f322ad301f6da7fb`. It exercises failures with disposable files, synthetic disks, mocked helpers and the debug simulation state machine. It is not physical installation qualification, and no finite test suite covers every possible machine, disk or interruption.

## Changes and regression coverage

| Failure | Prevention | Regression coverage |
| --- | --- | --- |
| A resumed run encounters another APFS partition at the same location | Reconcile the saved target evidence before the next mutation; validate installed content before a resumed Recovery handoff | Coordinator rejection before intent; changed UUID, identifier, size, offset and type; existing Recovery readback tests |
| Container geometry changes during preflight | Check the source endpoint and APFS type before resizing | Changed source endpoint produces zero resize and partition-creation calls |
| A repair ZIP lacks a later image after an earlier partition has already been overwritten | Check every replacement's member, local header, size and decoder before opening any writable target; require manifest image sizes to fit their partitions and 4 KiB raw-device alignment | Missing/mis-sized later member leaves the earlier partition untouched; oversized and unaligned images produce no repair candidate |
| A network observer ends before the download | Distinguish observer completion from work completion | Finished stream plus delayed failing work cannot publish verified |
| Two releases reuse a payload digest but stage it at different paths | Bind in-flight reuse to the artifact and canonical destination | Both release directories receive their own verified file; unchanged replans still reuse the existing download |
| Cancellation arrives during local assembly or hashing | Check cancellation between chunks and before promotion; prevent superseded generations from promoting | Deterministic cancellation at assembly leaves no final payload and retains verified parts for retry |
| Local preparation or helper ping fails before submission and locks the UI permanently | Explicit app-side pre-submission error; revoke approval and allow fresh inspection | Proven pre-submission failure unlocks initial installation; Recovery retry preserves its checkpoint; ordinary connection loss remains locked |
| Quit/Close interrupts the app while its helper continues | Guard app termination during execution and use native window dismissal control; keep a single installer window | Session guard covers initial execution and Recovery retry and clears at terminal outcomes; native UI behavior still needs manual verification |
| A non-reproducible engine build replaces the previous good output | Validate the temporary archive's modes, size and digest before atomic promotion; clean up on failure | Whole-script fixture uses mocked build tools and verifies the previous bytes survive all three rejection paths |

The UI also displays the planned release and target, provides **Copy setup steps**, and exposes progress through native accessibility semantics while respecting Reduce Motion. These are source changes; passing Swift tests does not replace a visual or VoiceOver review.

## Verification boundaries

Run `bash test/all` with Bash 5+, Python 3.12+ and the documented tools. The new engine-build regression uses fake build tools and disposable archives; it does not compile the native engine, compress a release payload, sign, publish or modify disks. Run strict Swift formatting and both Swift configurations through XcodeBuildMCP as described in `validation.md`. The debug suite iterates every defined installation simulation scenario; these remain synthetic environments.

The source lock, trust roots, release descriptor and blocked-model rules are unchanged. In particular `apple,j614s` remains blocked. The engine overlay edits are not present in the existing authenticated engine archive. A separately reviewed engine rebuild/repack, updated artifact identity, assembled-package checks and authorized physical qualification are required before distribution. Never bypass an old lock's mismatch to package these changes.

## Remaining practical work

1. **Read-only subprocess hangs (high priority).** `MacHostInspection.swift` drains stdout before stderr although it discards stderr; enough stderr can fill the pipe and deadlock the child. Discard that unused stream or drain it concurrently. Add bounded timeouts and output caps to read-only disk/engine inspection with fixture children that flood stderr or never exit. Do not apply a generic kill timeout to an active disk write or APFS mutation.
2. **Restart-safe download recovery (medium priority).** Prefetch work directories are tracked only in memory and named with random UUIDs. After a crash, a new process cannot reclaim or reuse their multi-gigabyte parts. Design a narrowly scoped owner lease/manifest; reverify parts before reuse and reclaim only demonstrably abandoned directories. Test low-space relaunch and a concurrently live unrelated owner. Do not recursively clear the shared staging folder.
3. **Immediate unsupported-host feedback (medium priority).** `LiveInstallerEnvironment.inspect` waits for a catalog to enrich a model it already knows is unsupported; network timeout can delay the refusal. Show the refusal immediately and enrich the optional model list asynchronously or from an already validated catalog. Preserve the blocked-device gate.
4. **Prefetch simulation coverage (medium priority).** The simulation environment still uses preparation-stage download scenarios and does not model the live plan-screen prefetch lifecycle. Add waiting-for-network, pause/resume, verification, failure/retry and release-change cases through the same session interface.
5. **Repair durability (before enabling physical repair).** The repair writer still uses `fsync`; the fresh-install image writer has the macOS raw-device synchronization primitive. Reuse that primitive with a fake flush seam and verify it on authorized hardware. Malformed member tables now fail before writes, but corruption or I/O failure encountered during actual writing can still leave a partial repair.
6. **Geometry identity boundary.** The new resize check rejects endpoint drift but does not introduce a new UUID-bearing plan format or an OS-level lock against another disk management process. Revalidate live resize limits/identity as close to mutation as practical; qualify behavior if another process changes the disk. The existing engine and diskutil checks remain necessary.

## Native UI and physical scenario checklist

- During credential verification, active installation and Recovery retry, try Command-Q, Command-W and the close button. They must preserve the running session. Repeat after rejected credentials, completion and failure; normal exit and requested shutdown must be allowed.
- Review the release/target details, minimum-size and narrow-window layouts, keyboard size editing, light/dark mode, VoiceOver progress and toggling Reduce Motion while progress is visible.
- Copy Recovery steps before shutdown; retain warnings and step details. Simulate rejected shutdown and confirm instructions stay visible.
- Exercise all installation and removal simulation outcomes, including unknown helper results, changed allocation, rejected credentials, offline channels and partial removal. A missing checkpoint must never be presented as proof of no writes.
- On separately authorized, backed-up supported hardware: cold/warm downloads, dropped Wi-Fi, disk pressure, snapshots/FileVault, APFS resize refusal, interruption at each mutation boundary, Recovery retry, first boot, encryption choice and removal. Preserve recovery paths and record the exact catalog, payload, engine and app identities.
- Measure download, app/helper import, resize, decompression/write, synchronization, readback and Recovery separately. Keep streaming hashes, authenticated admission and sequential disk mutation. Do not promise a faster physical install without measurements.

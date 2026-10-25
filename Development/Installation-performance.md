# Installer performance notes

How the installer keeps the write path small and the UI honest. Sizes refer to the current payload: a 2 GiB boot image and a 32 GiB root image, so about 34 GiB is written to disk; download time, APFS operations and the Recovery interaction still contribute.

## Handoff and staging

- The app-to-engine handoff clones the verified artifacts with APFS copy-on-write when the volume supports it (`fclonefileat`), and falls back to a verified streaming copy elsewhere. Either way the copy is re-hashed: the expected size and SHA-256 must match the staged artifact before use, and the helper keeps its own authenticated private copy.
- Disk-size replanning reuses already-staged assets after fresh catalog, version and model validation. The execution handoff still verifies the bytes before admission.
- The payload ZIP is not fully decompressed during preflight: structural, image-capacity and member checks run before any disk mutation.

## Writing and verification

- The root helper owns the write path. The payload ZIP is never fully expanded: CRCs are checked as members are extracted, and each written image leaves a receipt recording installed bytes and a SHA-256 content digest.
- Boot and EFI images are re-read in full and hashed against their receipts; the root image gets write verification plus a prefix hash unless full read-back is requested. Recovery retry re-checks every installed image against its recorded hash without decompressing the source. Set `OMARCHY_FULL_READBACK=1` in the engine environment for a diagnostic full read-back of the written device.
- Cancellation and interrupted runs follow the journal rules in [Removal.md](Removal.md) and [Simulation.md](Simulation.md): an uncertain outcome never reports success and locks new installs until the recorded journal is reconciled.

## Measurement

- Engine phase timings are recorded to a `.performance.jsonl` sidecar next to the run transcript (`OMARCHY_PERFORMANCE_LOG` selects its path); app preparation and credential-validation timings go to the system log.
- Progress is monotonic and stays below completion until the real success transition. The time estimate shown early in the run comes from the latest successful stage-one duration; it is an estimate, not a measured speed claim.

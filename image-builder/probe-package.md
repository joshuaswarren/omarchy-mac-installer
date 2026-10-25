# Probe package (single-board private test)

`probe-package.py` builds an installer payload with the exact full-OS shape the
engine admits (`omarchy_asahi.AsahiStage1Adapter._validate_full_os_package`):
the EFI + Boot + Root partition contract, the required payload members, the
metadata contract. Its only live part is the probe m1n1: the Stage 2 binary
supplied at build time rides at `esp/m1n1/boot.bin`, and an optional Aurora
Stage 1 at `esp/aurora/stage1.bin` becomes the stub's boot object for the
qualified board. `boot.img` and `root.img` are minimal placeholder images —
the package installs a Mac that boots the probe m1n1 (USB proxy) and never
boots Linux. Nothing here claims otherwise, and it must never be offered on a
public channel.

## Build

```bash
python3 image-builder/probe-package.py \
  --stage2  ~/path/m1n1-stage2.bin \
  --stage1  ~/path/m1n1-stage1.bin \
  --bootaa64 ~/path/BOOTAA64.EFI \
  --output  ~/path/out
```

Writes `<out>/omarchy-probe-j575d-os-package.zip`,
`<out>/installer_data.json` (mode 0644; the engine refuses group-writable
metadata), and `<out>/catalog-inputs.json`, then validates its own output with
the engine's admission code (the same stand-ins
`test/test_engine_contract.py` uses for the pinned engine modules) and prints
sha256s and sizes.

## What the engine checks, and what a probe package meets

- Metadata: exactly one `apple-silicon-full-os` target; `package` names the
  payload; `boot_object` `m1n1.bin`, `next_object` `m1n1/boot.bin`; icon
  member; the three-partition contract with a `fat` EFI that copies firmware
  and installer data; `supported_fw`; `allowed_device_classes`; metadata file
  regular, mode 0644, under 64 KiB.
- Payload: safe member names (no links, no `..`), required members
  `boot.img`, `root.img`, `esp/m1n1/boot.bin`, `esp/EFI/BOOT/BOOTAA64.EFI`,
  `omarchy-volume.icns`, all non-empty; image members 4 KiB aligned and no
  larger than their declared partition capacity; Stage 1 (when carried and
  qualified) fills in place: one `AURORA-S1-CFG01` block, `STACKBOT` tail.
- Not checked here, and deliberately not met: everything
  `bin/mac-image-check payload` demands of a real OS image (filesystems, UUIDs,
  UKI, subvolumes). A probe package fails those by design.

## Sizes

The engine's floor is 4096-byte images (`> 0`, 4 KiB aligned, at most the
partition size, capacity `> 0`). The default 8 MiB keeps a margin above
diskutil's practical minimum. The free-space floor the engine enforces is
`stub_size + min_size`, where `min_size` is the sum of the declared
partition sizes rounded up to MiB — 516 MiB for the defaults here
(500 MiB EFI as the real image declares, 8 MiB Boot, 8 MiB Root), instead of
the real image's about 34.5 GiB. Shrinking macOS still has to satisfy the
planner's 38 GB macOS reserve.

## Private-test route

The public channel is never used. The sanctioned path is a developer build
with a sealed catalog:

1. `scripts/make-unsigned-catalog.py --developer --inputs
   <out>/catalog-inputs.json --assets-dir DIR` — `DIR` carries the payload,
   `installer_data.json`, `probe-installer_data.json` (a copy of the same
   metadata under the group's own name) and the pinned engine archive named
   by `Engine/source-lock.json`. The manifest
   (`scripts/supported-models.json`) must admit the board first (supported or
   `developer` section), or the command refuses it.
2. Sign the catalog with the operator's catalog key
   (`scripts/catalog-signing.swift`); the key is never in the repository.
3. Seal `catalog.json` + `catalog.json.sig` and the developer trust root into
   the app's `Release/` resources (see `Packaging/private-test/`), so the app
   verifies the catalog locally.

The app fetches the pinned artifacts from the catalog's https URLs or accepts
them staged locally (`Stage assets.command`), digest-checked.

Self-check: `python3 image-builder/test/test_probe_package.py` builds from
dummy binaries and runs the engine's validators on the result.

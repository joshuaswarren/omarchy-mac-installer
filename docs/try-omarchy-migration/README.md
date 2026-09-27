# Try Omarchy migration exploration

Start with the [collaboration plan](collaboration-plan.md): the agreed product direction, proposed Eduardo/Try and Scott/Omarchy Installer ownership, concrete work packages, initial protocol semantics, and staged delivery.

This branch makes the current synthetic prototypes available for joint development. It does not add a working migration command or enable migration in either app.

The [validation record](validation.md) identifies the tested commit, runner, tool hashes, passed checks, and the optional skip.

| Path | Purpose |
| --- | --- |
| [Collaboration plan](collaboration-plan.md) | Try guest delivery, stable capture/lifecycle, local export, authenticated app coordination, and acceptance criteria. |
| [Bundle probe](../../Development/migration_bundle_probe/README.md) | Experimental encrypted archive, validation, synthetic credential selection, and 18 behavioral tests. |
| [Staging components](../../Development/migration_staging/README.md) | GPT identity/bounds, a regular-fixture-only QEMU range broker, capacity arithmetic, and resumable ciphertext publication with 44 tests. |

## Run and interpret the checks

The focused migration tests require Linux and Python 3.11+; the full repository suite requires Python 3.12+ and Bash 5+. Follow each component README to supply independently verified age 1.3.2 and QEMU NBD executables; `sgdisk` enables an independent GPT-writer check. Optional integrations explicitly skip when their dependencies are not configured. Then run `./test/all` for repository source, engine, shell, and packaging-fixture checks. See [repository validation prerequisites](../validation.md) for the broader portable suite.

All added tests use synthetic regular files and temporary directories. They do not need root, mount filesystems, use real block devices, boot a VM, or download dependencies. QEMU integration tests need permission to use private Unix sockets. The release-descriptor script includes the already-tested portability fix to use its existing Python dependency for SHA-256 instead of an absolute macOS `shasum` path; release inputs and trust configuration are unchanged.

## Remaining integration work

The shared production exporter/importer, stable source capture, safe links/metadata, application adapters, authenticated app interface, durable lifecycle recovery, native staging utility, and reboot/encryption/owner handoff remain unfinished. The bundle decoder validates data without restoring a home; the staging broker cannot yet reopen after mutation or reconcile controller death. Component tests are not native installation qualification.

The proposed public Linux interface is `omarchy-migration` with inventory/export/plan/apply/report operations. There is no production implementation or stable protocol to depend on yet. Existing `omarchy-migrate` remains the release-migration runner. Try integration can start against an agreed synthetic fixture while the shared module and native handoff are developed.

Native hardware restrictions, including fail-closed `apple,j614s`, remain unchanged. The M4 mentioned in the collaboration plan is a VM experiment host. This branch does not change Swift app code, helper registration, engine locks, disk/boot policy, production signing, or packaging inputs.

Only reviewed development source, synthetic tests, and shareable planning documents are included. Local workstation inventory, SSH endpoints, downloaded tools, VM images, private lab logs, and unrelated installer work are not part of this handoff.

# Disposable migration staging components

These Linux development experiments prepare a Try-to-native migration staging test. They are not connected to the installer app, privileged helper, engine or boot package. They accept private regular fixture files and temporary directories, not real disks. No tests mount a filesystem, use `/dev/nbd`, launch a VM, install packages or require root.

## Components

- `gpt.py` checks both GPT headers and entry tables, CRCs, UUIDs, partition overlap and bounds before returning the selected Root extent. Its intentionally narrow fixture format has 512-byte logical sectors. The controller supplies expected disk and partition UUIDs; a partition name is not authority.
- `capacity.py` computes conservative staging growth while retaining the original filesystem allowance, explicit metadata reserve, 32 MiB shrink work and a 32 MiB unused partition tail. This arithmetic is not a Btrfs free-space or encryption-survival proof; actual measurements are still required.
- `broker.py` pins the selected regular-file inode and serves only its checked offset/length through QEMU's raw block node and a private Unix socket. `FixturePermit.inspect_gpt` binds expected disk/partition UUIDs, geometry and restored-prefix readback on one opened fixture. Startup rechecks them through the pinned descriptor after QEMU completes protocol negotiation. An immutable permit models the completed-install gate; it is not helper authorization. Image and QEMU locks exclude cooperating writers. No mutable pathname is passed to QEMU after opening the target.
- `publication.py` binds an opaque export, target, candidate, install plan and worker to durable intent. It resumes a matching ciphertext prefix, verifies and synchronizes the complete file, renames it, reads it back and publishes readiness last. A consumer must call `verify_ready`; a ready filename without matching bytes is insufficient.

The broker follows the maintained [QEMU NBD server's bounded raw export](https://www.qemu.org/docs/master/tools/qemu-nbd.html) rather than implementing a block server. The test-only socket client sends ordinary and deliberately invalid [NBD requests](https://github.com/NetworkBlockDevice/nbd/blob/master/doc/proto.md). GPT validation follows the [UEFI GPT layout](https://uefi.org/specs/UEFI/2.10/05_GUID_Partition_Table_Format.html). These primary references explain the interfaces; compatibility is measured against the actual recorded binaries.

## Run checks

Use Linux and Python 3.10 or newer for these components; the branch's combined bundle/staging checks require Python 3.11 or newer. The bounded server depends on Linux `/proc/self/fd`, so these tests do not provide a native macOS staging backend. Run them in a Linux development environment or guest.

The portable repository suite includes pure fixture tests and explicitly skips the optional QEMU cases when its binary is absent:

```bash
./test/all
```

For the focused suite with an installed or independently verified local QEMU NBD binary:

```bash
OMARCHY_TEST_QEMU_NBD=/absolute/path/to/qemu-nbd \
  python3 -W error::ResourceWarning -m unittest discover \
    -s Development/migration_staging -t . -p 'test_*.py'
```

QEMU tests use only Unix sockets in private temporary directories. A sandbox that prohibits socket binding may require an execution allowance; that is separate from root/device access. Tests never download their dependencies. If available, `sgdisk` supplies an independent synthetic GPT writer check; it only receives a test-created regular-file path.

Socket creation alone is not readiness: QEMU can listen before opening its image. The broker uses QEMU's maintained `--list` client to complete negotiation, checks the owned server is still alive, then revalidates the target. `--persistent` keeps the probe's disconnect from stopping the server; context cleanup terminates the exact owned process. A regression fixture creates a listening socket without a working export and must be refused.

## Deliberate boundaries

The broker is **initial-open only**. After the first utility write, the immutable restored-prefix hash no longer matches. Reopening requires a durable staging controller that reconciles the original candidate/target binding, filesystem state and previous worker; replacing the base digest with current bytes would defeat this check. Publisher retry in a directory does not prove broker/VM retry.

The standalone `read_root_extent` result is geometry, not a pinned target receipt. Use `FixturePermit.inspect_gpt` for the combined fixture path. The plain offset-based permit remains only for isolated range tests; production must derive authorization from its trusted plan, candidate and completed-engine receipt.

Normal context-managed cancellation terminates only the owned QEMU process and releases its socket and lock. Abrupt controller death may leave the child holding its inherited descriptor; the next cooperating writer remains excluded. An exact owned-process journal and recovery protocol are required before claiming crash lifecycle recovery. Same-user file locks are advisory and do not protect against another program intentionally writing through an independently opened descriptor.

Publication fault callbacks model process exceptions at defined boundaries, not power failure. File and directory synchronization is tested, but filesystem recovery and actual power-loss behavior need the disposable VM experiment. The small public receipt contains no personal filenames or passphrase and is a locator/binding, not cryptographic proof of who authorized an export. Full ciphertext authentication belongs to the shared Linux importer.

The eventual staging utility must receive only this socket and its approved read-only ciphertext input. It must not inherit the whole fixture descriptor, Mac shares, the source Try disk or network access. Native lifecycle testing later boots the complete synthetic disk separately. No utility launcher, filesystem growth/mounting, owner hook, real helper authorization or production migration support is provided here yet.

## Reboot experiment prerequisites

Use an immutable native candidate image, pinned utility kernel/initramfs and qualified VM runner. Verify the restored Root prefix before initial staging; the reference lifecycle harness's raw restore does not itself perform destination readback. Instrument the native owner's successful foreground return after defaults/rekey, preserving failure/deferred behavior, and verify the ciphertext again after the second boot. Keep the sealed factory content unchanged. Restrict any loop-device/automounter handling to the exact run-owned devices.

Preview concrete artifact sizes and operations before restoration or boot. Physical/privileged execution requires the repository's immediate owner authorization. Nothing in these fixtures expands supported native hardware or changes the fail-closed M4 policy.

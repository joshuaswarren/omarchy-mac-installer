# Migration exploration validation

## Runnable fixture candidate, 2026-09-28 UTC

Source candidate: [`4e11e700f3e7092d64a5ca0433bcd85ecd8c8ca2`](https://github.com/omacom/omarchy-mac-installer/commit/4e11e700f3e7092d64a5ca0433bcd85ecd8c8ca2), tree `c914a5b65e0d9bf904d50e3086693bc4c4dbeaa8`. This validation update is a documentation-only follow-up. One authoritative `./test/all` run on that committed candidate passed Python compilation, shell syntax, 37 engine tests, 104 overlay tests, 24 release/script tests, 43 staging tests, 28 bundle/fixture tests, and the shell/packaging fixtures. Total: **236 Python tests passed; one optional sgdisk case skipped**.

The 28 bundle/fixture cases comprise the existing 18 crypto/archive checks and 10 new integration checks. They exercise the real command and age executable, explicit/default synthetic credential selection, complete-result reuse, conflicting requests/ciphertext, unrelated directories and symlinks, malformed/duplicate/oversized requests, cooperative SIGTERM cancellation, cancellation during finalization, duplicate invocation while active, and failure to synchronize the new job directory's parent. Focused fixture tests also passed with ResourceWarning treated as an error. Documentation references and whitespace checks passed.

Runner: Linux aarch64 `7.1.12-2-11-ARCH`, Python 3.14.7, Bash 5.3.20, Git 2.55.0. age/QEMU identities match the dependency hashes recorded below. Optional crypto/QEMU tests were enabled; private Unix sockets required a sandbox allowance, without root or live devices. No Swift or app packaging source changed, so macOS builds/signing were not repeated or claimed for this fixture.

The separate [M4 experiment](m4-hvf-experiment.md) passed synthetic Btrfs growth, interrupted-copy resume, and authenticated ciphertext after a second maintenance boot. That report identifies its additional harness sources and retained evidence; it is not a native encryption/owner-provisioning qualification or a test of the new CLI inside Try.

## Initial prototype candidate, 2026-09-27 UTC

Recorded 2026-09-27 for source candidate [`9f779fc448a538a629fd541a86fc20231c37660e`](https://github.com/omacom/omarchy-mac-installer/commit/9f779fc448a538a629fd541a86fc20231c37660e), based on upstream main `a649597d4bf7465cbffb3fd8a320d32a59fce3b6`. Candidate tree: `3daa0d9e3c0bb6aaef91735e99608a6b7cc52926`. This report and its index link are a documentation-only follow-up; executable source and tests are unchanged from the tested commit.

## Runner and dependencies

| Item | Identity |
| --- | --- |
| Host | Linux aarch64, kernel `7.1.12-2-11-ARCH` |
| Python | `3.14.7` |
| Bash | `5.3.20(1)-release`, aarch64 |
| Git | `2.55.0` |
| age | `1.3.2`; executable SHA-256 `f28b157536b0d393aa4be2b95e1ead50acdcac7aa808cfdea19cb7a2e5b79053` |
| QEMU NBD | `11.1.1`; executable SHA-256 `4b42c1ba5a41ad848094415c8780ac151fdf89bf6b936d924a8f57a5f4e214d4` |
| sgdisk | Unavailable; independent GPT-writer case explicitly skipped |

The optional tools were supplied from independently verified local Arch Linux ARM packages. age and QEMU package verification used repository checksums and detached signatures with an installed trusted key. Tools and package caches are not included in the branch; see the component READMEs for environment configuration. No packages were installed by the test run.

## Results

The focused migration checks compiled all added Python modules, exercised the real age executable, and passed the available cases. The first staging attempt was blocked by the execution sandbox's Unix-socket restriction; rerunning outside that restriction passed without root, real disks, or a VM boot.

The authoritative portable run executed `./test/all` once on the committed candidate with both optional age and QEMU dependencies configured:

| Check | Result |
| --- | --- |
| Python compilation and shell syntax | Passed |
| Engine tests | 37 passed |
| Overlay tests | 104 passed |
| Release/script tests | 24 passed |
| Migration staging | 43 passed, 1 optional sgdisk case skipped |
| Encrypted bundle probe | 18 passed |
| Shell and packaging fixtures | Passed |
| Total Python cases | 226 passed, 1 skipped |

The 36 MiB bundle fixture measured 800,329 bytes peak Python allocations in the portable run. This excludes the age process, KDF memory, and kernel buffers. Wrong-passphrase/tamper/cancellation fixtures use fake contents only. Documentation references and `git diff --check` also passed.

## Scope of the evidence

This is source/component validation. No Swift app code, packaging inputs, engine lock, release trust configuration, helper authorization, or native host restriction changed. macOS debug/release builds, signing, app packaging, guest lifecycle integration, native staging/reboot/encryption, and physical installation were not exercised by this branch's run. Existing repository validation records do not qualify these unfinished migration paths.

The standalone probe still does not restore files or provide stable live capture. The broker is still initial-open only. Passing the portable suite does not make this branch a production migration release.

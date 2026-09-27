# Migration exploration validation

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

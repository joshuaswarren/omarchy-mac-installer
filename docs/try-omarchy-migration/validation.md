# Migration exploration validation

## Read-only survey candidate, 2026-10-03 UTC

Source candidate: `a3aedca`, tree `f5bfed533e8d3e3c587a78c95e142ab90472b3fc`. One authoritative `./test/all` run on pancake from a git bundle at that commit passed compilation/shell syntax, 37 engine, 104 overlay, 24 release/script, 44 staging (one optional `sgdisk` skip), 138 bundle/fixture/restore/tree/replacement/collection/survey and 44 contract tests, `preclean-m1-test` and every installer shell fixture: **390 Python tests passed; one optional skip** (391 run), exit 0, with encryption and QEMU socket cases enabled. Runner and dependency identities match the previous entry.

The [survey](../../Development/migration_bundle_probe/SURVEY.md) is the first command intended for the owner's real Try home. Instrumented tests prove it opens only directories (`O_DIRECTORY|O_NOFOLLOW`, never for writing), never lists credential stores or excluded paths, and creates nothing; its category counts equal what collection exports for the same home. Mutations that open a regular file or ignore stores fail the suite. It has not yet been run on a real home. Categories are now shared (`files-and-projects`, `configuration`, `caches`). No Swift, helper, packaging input, engine lock, trust, host-support or native disk source changed.

## Policy collection and contract fixture candidate, 2026-10-03 UTC

Source candidate: `bf1725b`, tree `d4ec61071442962dce4f7522483b8d698c1551d8`. One authoritative `./test/all` run on pancake, from a git bundle checked out at that commit, passed compilation/shell syntax, 37 engine, 104 overlay, 24 release/script, 44 staging (one optional `sgdisk` skip), 132 bundle/fixture/restore/tree/replacement/collection and 44 contract tests, `preclean-m1-test` and every installer shell fixture: **384 Python tests passed; one optional skip** (385 run), exit 0. Encryption and QEMU socket cases were enabled.

The slice moves the disposable collector onto the contract policy (exclusions never opened, including beneath a selected root; transforms on captured bytes that fail closed; inert mount links) and the runnable fixture onto contract documents, with a synthetic Try home collected through the real Try policy and restored end to end without Try integration content. One bounded read-only review found an exclusion bypass through a descendant selection, order-dependent nested rules, four transform fail-open or comment-loss cases and a silently dropped store selection; each was fixed with a regression test confirmed to fail on the earlier code. Iteration used a local Linux container (Python 3.13, tmpfs `/tmp`), which is not evidence.

Runner: Linux aarch64 `7.1.12-2-11.5-sep-ARCH`, Python 3.14.7, Bash 5.3.20, `/usr/bin/core_perl` on `PATH`; age 1.3.2 `f28b1575…5b79053`, qemu-nbd 11.1.1 `4b42c1ba…e214d4` and libaio 0.3.113 `d22000af…ea7fabc` checked by digest before use, nothing installed system-wide. No Swift, helper, packaging input, engine lock, trust, host-support or native disk source changed. macOS app builds/signing and physical installation are not claimed. The restorer still has no directory metadata or report provenance in the bundle; ticket 04 remains in progress.

## Contract v1 candidate, 2026-10-02 UTC

Source candidate: `3e7ae4672c`, tree `2b30c6df216edd77e8ca3b9dfd0c1998d79e2490`. The exact `git archive` of that commit ran `./test/all` on pancake: compilation/shell syntax, 37 engine, 104 overlay, 24 release/script, 44 staging (one optional `sgdisk` skip), 120 bundle/fixture/restore/tree/replacement/collection and 19 new contract tests passed, plus `preclean-m1-test`: **347 Python tests passed; one optional skip** (348 run). Encryption and QEMU socket cases were enabled. The archive has no `.git`, so `apple-installer-identity-test.sh` stopped at its tracked-file check and the remaining shell fixtures did not run there; all ten `test/shell.d/apple-installer-*-test.sh` files then passed on the M4 in a clean checkout at the same commit.

Runner: Linux aarch64 `7.1.12-2-11.5-sep-ARCH`, Python 3.14.7, Bash 5.3.20; `/usr/bin/core_perl` added to `PATH` as an Arch login shell does. age 1.3.2 `f28b1575…5b79053`, qemu-nbd 11.1.1 `4b42c1ba…e214d4` and libaio 0.3.113 `d22000af…ea7fabc` were copied from the verified tool records and checked by digest before use; nothing was installed system-wide. Shell fixtures: macOS 26.6.2 arm64, Bash 5 from Homebrew. Two earlier attempts on the same candidate are not evidence: one lacked `shasum` in a non-login shell, the other lacked libaio for qemu-nbd.

The [contract](../../Development/migration_contract/CONTRACT.md) is a validated draft: public document schemas, one Try policy pinned to `e1a0dbe` with evidence drift detection, and shared fixtures. The probe, fixture and restorer do not consume it yet, and no transform is applied. No Swift, helper, packaging input, engine lock, trust, host-support or native disk source changed. macOS app builds/signing and physical installation are not claimed. Ticket 04 remains in progress.

## Disposable collection candidate, 2026-09-30 UTC

Source candidate: `ed0b9299fb698c04b2703d70e6a66fb29abeeac1`, tree `09c16d54ff2f5a4980a102fb5bbdb8ca823bc11a`. One authoritative `./test/all` run passed compilation/shell syntax, 37 engine, 104 overlay, 24 release/script, 43 staging, and 120 bundle/fixture/restore/tree/replacement/collection checks, plus shell/packaging fixtures: **328 Python tests passed; one optional sgdisk case skipped**. This entry is a documentation-only follow-up to the tested candidate.

The [collection extension](../../Development/migration_bundle_probe/COLLECTION.md) adds 23 cases. Instrumented open/enumeration checks prove recognized fake stores are pruned before access, including unreadable protected directories. Default/alternate roots, direct and ancestor remapping, synthetic opt-in versus unavailable adapters, similar-prefix ordinary paths, unknown settings and project dotfiles, symbolic/hardlink aliases, nested mount identity rejection, source changes, root permission changes, bounded depth/size, capability binding, and scratch isolation/cleanup are exercised. An actual encrypted roundtrip retains captured bytes, file modes and nanosecond mtimes after subsequent source edits.

Focused collection checks, compilation/37 engine checks, and one 120-case migration closure passed with ResourceWarning treated as an error. Two independent read-only reviews found that renamed archive roots could redirect symlinks to different source objects. The implementation now omits symlinks whenever any root is renamed, with an explicit report and collision regression. Capability binding, root permissions, composed paths, and depth bounds were tightened before qualification. Final reviews reported no remaining blocker in the quiescent synthetic scope. Modified Markdown links and whitespace checks passed.

Runner: Linux aarch64 `7.1.12-2-11.5-sep-ARCH`, Python 3.14.7, Bash 5.3.20, Git 2.55.0; age/QEMU hashes match the dependencies below. Tests remained unprivileged, with a sandbox allowance for private Unix sockets. No Swift, helper, packaging input, engine lock, trust, host-support or native disk source changed. macOS app builds/signing and physical installation are not claimed.

The collector accepts caller-created disposable sources and trusted fake-store layouts. It is not a real-home CLI or qualified adapter. It requires a quiescent source and snapshot-parent namespace; metadata checks do not prove atomic live capture. Cross-mount inputs, multiply linked regular files, renamed-root links and unsupported file types are withheld/rejected explicitly. Extended metadata, authenticated collection provenance, actual credential roots/aliases, Try transformations, production encrypted scratch/cleanup, shared runtime packaging and native boot/encryption remain work. Tickets 04–05 remain in progress.

## Approved replacement candidate, 2026-09-30 UTC

Source candidate: `ac66d5cffd066c5bf7b148503a3ff6ae521104d2`, tree `1bc82c0547fd9415b5a3ec07cb35163cc41f356b`. One authoritative `./test/all` run on that committed candidate passed compilation/shell syntax, 37 engine, 104 overlay, 24 release/script, 43 staging, and 97 bundle/fixture/restore/tree/replacement tests, plus shell/packaging fixtures: **305 Python tests passed; one optional sgdisk case skipped**. This validation entry is a documentation-only follow-up.

The [approved replacement extension](../../Development/migration_bundle_probe/REPLACEMENT.md) adds 23 cases. They cover explicit path approval and job binding, default conflict preservation, both bundle versions, matching-file retention, independently copied private backups despite original hardlinks, original/parent changes, backup/preparation/intent/completion failures, synchronization failures on either side of replacement, backup corruption/missing/link/permission changes, preservation of later edits/deletions/replacements, and actual SIGKILL immediately after the destination rename. Retry reconciles only the recorded new inode plus intact backup; uncertain original/missing/changed destinations remain conflicts.

Focused cases and one 97-case migration closure passed with ResourceWarning treated as an error. Python compilation and the focused 37 engine checks passed. Two independent read-only reviews identified lost backup references in conflict reports and unjournaled backup accumulation after ordinary preparation failure; both were corrected and tested. Final review reported no remaining blocker within the disposable, quiescent-destination scope. Modified Markdown links and whitespace checks passed.

Runner: Linux aarch64 `7.1.12-2-11.5-sep-ARCH`, Python 3.14.7, Bash 5.3.20, Git 2.55.0. age/QEMU hashes match the dependencies below. Tests remained unprivileged; private QEMU Unix sockets used a sandbox allowance. No Swift, helper, packaging input, engine lock, trust, host support, VM workflow, native disk, production signing, or physical installation changed or ran. Existing native qualification requirements remain in force.

Replacement requires destination leaves and directories to remain quiescent because rename does not compare the original inode atomically. Backups are private plaintext with original metadata recorded; production encrypted placement, capacity/lifetime/cleanup, rollback UI, stable capture, credential-aware collection, Try transformations, directory metadata, and native boot/encryption integration remain unfinished. Abrupt death before intent can leave unreferenced private artifacts. Tickets 04–05 remain in progress.

## Directory and link candidate, 2026-09-28 UTC

Source candidate: [`b7bd6d68d462b2c901890783f0f483b0fb598ba8`](https://github.com/omacom/omarchy-mac-installer/commit/b7bd6d68d462b2c901890783f0f483b0fb598ba8), tree `6161b609a93edbea06b82ebe5895d98f947d3bdd`. This validation update is a documentation-only follow-up. One authoritative `./test/all` run on that committed candidate passed Python compilation, shell syntax, 37 engine tests, 104 overlay tests, 24 release/script tests, 43 staging tests, 74 bundle/fixture/restore/tree tests, and the shell/packaging fixtures. Total: **282 Python tests passed; one optional sgdisk case skipped**.

The [tree extension](../../Development/migration_bundle_probe/TREE.md) adds 20 cases. They cover typed manifest admission, explicit directory ancestry, rejection of actual TAR link records, empty directories, preserved existing directory modes, inert unsupported links, direct relative file/directory links, component-wise `..` handling, changed actual destination dependencies, racing/interrupted directory creation, and preservation of later directory/file/link deletions or replacement. An actual SIGKILL after symlink publication is recovered by a fresh authenticated session. A real synthetic Git repository retains its commit identity, modified tracked content/status, and untracked file after encrypted export/restoration. The Git fixture additionally injects repository/index environment overrides and verifies the unrelated sentinel remains untouched.

Focused tree checks, the revised Git isolation case, and the complete 74-case bundle closure passed with ResourceWarning treated as an error. Read-only review identified the Git test isolation requirement; it was fixed and verified, with no remaining blocker reported within the synthetic, quiescent-target scope. Local Markdown links and whitespace checks passed. The original v1 bundle and runnable fixture remain compatible.

Runner: Linux aarch64 `7.1.12-2-11-ARCH`, Python 3.14.7, Bash 5.3.20, Git 2.55.0. age/QEMU identities match the dependency hashes below. Tests remained unprivileged; private Unix socket checks used a sandbox allowance. No Swift, packaging, helper, host-support, release-trust, or engine-lock source changed. No M4 VM run, macOS build/signing, native disk operation, or physical installation was performed for this slice.

Newly created directories use mode 0700; source directory permissions/timestamps are recorded but explicitly deferred. Unsupported links remain encrypted records without active destination links. This does not establish replacement backups, production source discovery/credential policy, complete link/extended metadata support, advanced Git layouts, application consistency, safe plaintext cleanup after abrupt death, power-loss recovery, or native boot/encryption integration.

## Additive restoration candidate, 2026-09-28 UTC

Source candidate: [`0560807806293482ca599d196399d77600336371`](https://github.com/omacom/omarchy-mac-installer/commit/0560807806293482ca599d196399d77600336371), tree `0e0b745e0db98fd9cdb7b71d473fe33e01832c78`. This validation update is a documentation-only follow-up. One authoritative `./test/all` run on that committed candidate passed Python compilation, shell syntax, 37 engine tests, 104 overlay tests, 24 release/script tests, 43 staging tests, 54 bundle/fixture/restore tests, and the shell/packaging fixtures. Total: **262 Python tests passed; one optional sgdisk case skipped**.

The 54 bundle tests include 26 new [restoration cases](../../Development/migration_bundle_probe/RESTORE.md). Focused restoration and full bundle checks also passed with ResourceWarning treated as an error. They verify authenticated EOF before releasing plaintext objects, private scratch cleanup after validation failure, exact file contents/modes/nsmtime and current-user ownership, existing-file preservation, symlink/FIFO refusal, changed parent/target/job identities, changed plans, journal binding and duplicate-job exclusion, interrupted publication, synchronization failures, and preservation of subsequent edits/deletions. A child process was actually killed with SIGKILL immediately after linking its first destination file; a fresh authenticated session recovered that file from positive inode/content/metadata evidence and restored the remaining files.

Read-only review found a stale-plan issue involving replaced nested parent directories. The implementation now records and rechecks parent identities, with a regression case. Review found no remaining blocker within the documented synthetic, quiescent-target scope. Missing files after uncertain publication remain conflicts because the importer cannot distinguish interruption before publication from a later user deletion.

Runner: Linux aarch64 `7.1.12-2-11-ARCH`, Python 3.14.7, Bash 5.3.20, Git 2.55.0. Dependency identities match the age/QEMU hashes below. Private Unix socket tests ran with a sandbox allowance while remaining unprivileged. No Swift, packaging, helper, host-support, release trust, or engine-lock source changed. macOS builds/signing and M4 experiments were not repeated for this Python-only slice.

These results cover additive restoration of synthetic regular files. They do not establish power-loss recovery, replacement backups, hostile simultaneous namespace changes, secure plaintext cleanup after SIGKILL, stable live capture, real-home or application support, or native installation. Tickets 04–05 and the native reboot/encryption gate remain incomplete.

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

The standalone probe now restores synthetic regular files, explicit directories, and selected relative links into disposable destinations. Stable live capture, production replacement/backup behavior, complete metadata/link handling, and real-home support remain unfinished. The broker is still initial-open only. Passing the portable suite does not make this branch a production migration release.

# Installer extraction

[omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer) contains the standalone development source extracted from [maralcbr/omarchy-mx-mac at 4db862da7a0957758c504c5a3e041202019dbabf](https://github.com/maralcbr/omarchy-mx-mac/tree/4db862da7a0957758c504c5a3e041202019dbabf/apps/omarchy-apple-installer). Publishing this source enables collaboration; it does not qualify an installation release.

## Provenance

The installer directory becomes the repository root. The source repository's MIT [LICENSE](../LICENSE), original icon, three installer shell tests, their shared support file, and the recorded journal fixture are also retained. The exact path list and tool revision are in [extraction-source.json](extraction-source.json).

The import retains 114 relevant commits, including their original authors, committers, dates and messages. Commit IDs change because the repository trees and ancestry change; original commit signatures cannot authenticate rewritten commits. [extraction-commit-map.txt](extraction-commit-map.txt) maps each retained original commit to its extracted commit. The original repository remains the authority for original signatures and omitted desktop history. PR numbers retained in imported commit subjects refer to the repository where each change originated: installer-specific subjects such as `(#183)` refer to [Marcelo's source repository](https://github.com/maralcbr/omarchy-mx-mac/pull/183); inherited upstream subjects such as `(#6749)` in `988ca27` and `(#1458)` in `d31cf10` refer to [omacom/omarchy#6749](https://github.com/omacom/omarchy/pull/6749) and [omacom/omarchy#1458](https://github.com/omacom/omarchy/pull/1458). These imported references do not identify issues or pull requests in this standalone repository.

The extraction base is `0d6f8661a5ad7b263d6167f0afea7cae033419a0`. All 206 files and their Git modes at that revision were compared with the selected source paths and match exactly. Subsequent commits contain standalone path adjustments and documentation so reviewers can separate those changes from the import.

The installer work and its recorded Git attribution are preserved, including Marcelo Alcantara's contributions and upstream Omarchy contributors. The root copyright notice remains unchanged. Asahi engine sources are external dependencies identified by [Engine/source-lock.json](../Engine/source-lock.json); their own licenses and notices must accompany distributed artifacts.

## Later imports

The installer changes from 2.0.6 to 2.0.10 were replayed from [maralcbr/omarchy-mx-mac `4db862da..92a9054f`](https://github.com/maralcbr/omarchy-mx-mac/compare/4db862da7a0957758c504c5a3e041202019dbabf...92a9054f4565b37739ac3bd4f0fb4fcf8bd48625), limited to `apps/omarchy-apple-installer`: source PRs #195, #197, #198, #223, #225, #228, #232, #259, #262 and #263. Each was exported with `git format-patch --relative=apps/omarchy-apple-installer` and applied with `git am`, keeping the original author, date and message. Each message ends with `Imported from maralcbr/omarchy-mx-mac@<sha>.` naming the source commit. Conflicts with `Packaging/identity.conf` were resolved in place, and the following commit derives the new identifiers from it and pins the runbook's source links.

The payload download retry from source PR #265 ([`16cb6869`](https://github.com/maralcbr/omarchy-mx-mac/commit/16cb6869ac30d9683ba7daaa2fa04361f169e3e0)) was replayed the same way. The one-page view's two retry hunks were applied by hand, since their context differs by this repository's encryption gate, and one test hunk was already present because this repository had wrapped that line for swift-format. It adds no identity literal.

## Reproducing the import

Use the recorded source revision, not a moving branch. In a dedicated source clone, create a temporary `export/installer` branch at that revision, then export the listed paths with `git fast-export --show-original-ids --signed-tags=strip --tag-of-filtered-object=rewrite --reencode=no --use-done-feature export/installer -- PATHS...`. All paths must be available if using a sparse checkout.

In a separate empty Git repository initialized on `extract/installer`, feed that stream to the recorded `git-filter-repo` version:

```bash
python3 /path/to/git-filter-repo --stdin \
  --preserve-commit-hashes --preserve-commit-encoding \
  --path-rename apps/omarchy-apple-installer/: \
  --refname-callback 'return b"refs/heads/extract/installer"' < installer.fast-export
```

Compare the resulting tree with `extraction_base_tree` in the source record. This operation belongs only in a disposable extraction repository; never filter the shared desktop checkout.

## Boundaries of this change

This split preserves the current application identity, support gates, engine lock, release catalog URLs and public trust root. It does not make the inherited release configuration an Omacom release. Historical design notes and release helpers retain references to their original environment; those references are not setup instructions for the new repository.

The next integration should separately define the shared Linux image and package inputs, encrypted-install handoff, kernel selection, release ownership and validation evidence. In particular, the Linux payload must supply the shared runtime, settings and `omarchy-mac` package before hardware setup. The macOS app and the Linux image remain separate build products.

## Build prerequisites

- `Packaging/build-app.sh` requires the authenticated `installer-v0.9.0-omarchy.14.tar.gz` archive, SHA-256 `9e9277384b6c9e8b269cc79b1b24df7bfcdcbb898a596a677b74d1d18050aebe`, in `Engine/artifacts/`. This binary is not tracked; it is the inspection engine used before any downloads. The source lock records installation engine `.17`; those versions deliberately differ, as documented in `ValidationEngineArtifact.swift`.
- `Engine/build-locked-engine.sh` still reads `downstream_overlay.metadata.path`, while the current source lock omits it and the verifier rejects that field. A complete native engine rebuild has not been validated. The authenticated-base Python overlay rebuild is a separate path; its tests are included.
- The native engine lock records exact tools and machine-specific paths. Keep those reproducibility constraints until deliberately reviewed; silently substituting another toolchain would not validate the recorded artifact.
- Release scripts retain the original publisher's endpoints, signing identity and historical defaults, and are not a release procedure for this repository. The cutover helper accepts an external image via `OMARCHY_OS_PAYLOAD`.
- The exact model `apple,j614s` remains blocked. Availability of an M4 Pro for development does not qualify it as an installation target.

## Engine revisions

Every revision below was rebuilt from the authenticated `.14` base and the locked v0.9.2 engine source graph, and its recorded digest was reproduced byte for byte before being pinned. Reproduce any revision with:

```bash
python3 Engine/rebuild-python-overlay.py /path/to/locked-engine-checkout \
  /path/to/installer-v0.9.0-omarchy.14.tar.gz Engine/artifacts/OUTPUT.tar.gz
```

using macOS `/usr/bin/python3` 3.9.6. Other Python or tarfile versions may encode equivalent tar headers differently and change the archive digest; source and member contents can still be checked on their own. Check the locked checkout with `Engine/verify-source-lock.py` and the result with `Engine/verify-archive-modes.py`. The portable source-lock tests check every downstream input and build recipe against its recorded digest. The generated archives are intentionally untracked.

| Archive | Size (bytes) | SHA-256 | Purpose and changes |
| --- | --- | --- | --- |
| `installer-v0.9.2-omarchy.17.tar.gz` | 17,838,045 | `ecb61645a9c75ba733425fb300b8b53b09f9dbc297a86acce1e0ee41f36e32e5` | M3 inspection: rebuilt from source `8cb67b490fc8ffb4d9b338759403c18238a1b11a`. The older engine marks M3 devices expert-only, so an M3-capable catalog alone cannot admit the host. |
| `installer-v0.9.2-omarchy.18.tar.gz` | 17,839,116 | `aba44d2050ecc84203a3a520ad53a0142e71f95d14245bd0313f1cb85bcbd565` | Tight-disk planner and staging-aware recommendation contract. Compared with `.17`, only `omarchy_asahi.py`, `omarchy_contract.py`, `omarchy_execution.py`, `omarchy_planner.py` and `version.tag` changed. |
| `installer-v0.9.2-omarchy.20.tar.gz` | 17,839,374 | `7d7d87a934c128e501f8f6287d259195238ed1ae7953336b91738ff63514ea93` | macOS reserve policy: hard free-space reserve of 38,000,000,000 bytes for macOS on every disk size. The container minimum is the larger of diskutil's preferred minimum and aligned current usage plus that reserve. The departure from the upstream engine's default policy is that Omarchy can use the Linux partition floor without expert mode; macOS never gives up its reserve. Swift computes the allocation ceiling from the engine's hard minimum plus staging and drift allowances, withholds the resize drift margin before adopting the recommended size as the minimum, and colors the macOS segment with the caution color below the recommended reserve. |
| `installer-v0.9.2-omarchy.27.tar.gz` | 17,839,422 | `4f9241b0139ba6ccdcfdb3484831002e07e36ba50274279c641ca2020593a15a` | Stub probe fix: stub containers carry the version of the macOS they were made from, which admitted them to the limits probes, and one failed probe on a Mac with an existing engine-installed Linux or Omarchy system failed the whole inventory. Only versioned OSes that are not stubs are probed. Compared with `.20`, only `omarchy_runtime.py` and `version.tag` changed. |
| `installer-v0.9.2-omarchy.28.tar.gz` | 17,843,348 | `0cf1aa87760f90a545298b7cef737c9b497f2cad421d79ac59f557a81f2eb146` | Recovery step (from #39) added to the runtime. Compared with `.27`, only `omarchy_asahi.py`, `omarchy_runtime.py` and `version.tag` changed. The bundled inspection pins and `Packaging/build-app.sh` select `.28`, so the release scripts publish the engine the templates name. |

Inventory probes cover upstream resizable containers plus GPT/APFS containers holding a versioned macOS, so tight system containers stay visible for an exact shortfall, including any existing reserve deficit and remaining staging requirement. Free-space estimates include staging reserves and are refreshed when planning; the engine remains authoritative at admission. Runtime Python is the authenticated bundled 3.13 runtime.

This inspection work does not add replacement support for legacy installations with only one Linux partition.

## Installer and catalog gating

Ship installer **2.1.0 or later** together with the new engine and a signed catalog whose `installer.minimumVersion` is at least **2.1.0**. Both release-input templates carry this gate, and the catalog generator refuses a lower minimum for `.18` or newer engines in this lineage. Older installers show the update-required message before decoding recommendation fields. Signed production catalogs and frozen private-test catalogs are not changed by these source updates; publishing a catalog that admits a new engine is a separate release step, as are artifact publication, catalog signing and physical installation qualification.

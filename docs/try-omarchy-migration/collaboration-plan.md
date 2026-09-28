# Try Omarchy → native Omarchy: proposed collaboration plan

Prepared for Eduardo by Scott, 2026-09-27. Proposed ownership and interfaces for discussion; implementation is in progress.

Eduardo — I have worked through the migration requirements and started testing the underlying pieces. Here is the detailed division of work I would propose. Try would own the source VM and export workflow; Scott would own the shared migration engine, Omarchy Installer staging, and native restore.

## Intended user experience

1. In Omarchy Installer, choose **Continue from Try Omarchy** on the same supported Mac.
2. Try identifies the selected persistent VM and Linux account. If export support is missing, offer installation/update inside the existing guest without resetting it or requiring SSH.
3. The user approves inventory in Try, reviews categories and estimated sizes, and chooses what to bring. Recognized credential stores and browser profiles require explicit inclusion. The installer never receives the source Linux login password.
4. The user saves work and closes applications as needed. Try coordinates application preparation and a stable final capture; temporary VM shutdown is acceptable. Export encrypts everything with a separate transfer passphrase.
5. A completed encrypted bundle is retained locally on the Mac. The installer verifies the handoff and available space before beginning disk changes. No migration data goes through a cloud service or requires a USB drive.
6. Omarchy Installer installs the ordinary native image and stages the bundle into storage that survives reboot and first-boot encryption. After the destination account and native defaults are ready, the user enters the transfer passphrase and restores their selection.
7. Compatible applications download again. Missing packages, unsupported applications, or interrupted import produce a report and retry path while leaving the desktop usable. Retrying preserves subsequent destination edits. Keep the original VM and completed export until the user explicitly chooses cleanup.

Initial scope: one persistent source user and one fresh native destination user on the same Mac. Files, projects, themes, personal configuration, and supported application data are eligible. Display, graphics, boot, hardware identities, and VM integrations are excluded. Unknown personal configuration is preserved; a general interpreter for arbitrary dotfiles is outside the scope of this project. Shared Mac folder contents require explicit selection rather than blindly following links.

## Proposed ownership

| Area | Eduardo / Try | Omarchy Installer / Scott |
| --- | --- | --- |
| Existing-VM setup | Package and deliver a pinned exporter through Try integrations; report actual capabilities. | Supply the shared exporter, dependencies, protocol fixtures, and supported category definitions. |
| Source preparation | Own VM/account selection, consent, lifecycle, locking, and any maintenance boot. | Supply application preparation hooks, capture validation, and file-selection policy. |
| Local export | Connect the guest to a private export destination; surface progress, cancellation, and recovery. | Own bundle construction, encryption, validation, and completion semantics in the shared module. |
| App communication | Implement the Try endpoint. | Implement the installer client; agree on authentication and protocol together. |
| Try-specific configuration | Review product-owned additions and version boundaries. | Implement and test exclusion/transformation rules, preserving unrelated edits. |
| Native migration | Provide completed export and source capability information. | Own target staging, provisioning hooks, restore, application reinstall, and native qualification. |

The shared Linux command is planned as **omarchy-migration**, with inventory/export/plan/apply/report operations. Both products consume the same pinned implementation. These operations are design targets, not a finished API. Existing **omarchy-migrate** remains the separate Omarchy release-migration command.

## What Try needs to collect and hand over

Added 2026-09-28 UTC. This is the concrete collection checklist for the proposed work split. The tables specify required information and behavior; production JSON field names and transport are not frozen. The runnable fixture has its own deliberately smaller, synthetic-only schema. It must not be mistaken for the production data contract.

Try supplies the selected VM/account context, consent, stable capture environment, and local export connection. **Scott's shared Linux exporter owns discovery of files and applications, category policy, exclusions, metadata, archive construction, and encryption.** Eduardo should wire that exporter into Try rather than build a second home scanner, application collector, or archive format. For now, that integration can use the runnable synthetic fixture.

### A. Information Try supplies or obtains from the selected guest

| Item | Required information | Use and handling |
| --- | --- | --- |
| Selected VM | Opaque persistent VM identity; current storage resolution; enough disk identity/change information to detect replacement; current running/stopped state. | Try resolves moved storage and keeps local filesystem references private. A display name or remembered path alone must not bind an export. Agree on the actual identity mechanism together. |
| Selected Linux account | Actual username, UID/GID, and home location, obtained inside that VM for the approved account. | One account per export. Usernames and paths are private inventory, not public status text. Source IDs are provenance; native restore maps ownership to the new account. |
| Installed capabilities | Try app version/build, delivered integration revision, actual guest architecture and Omarchy versions, installed exporter/protocol/bundle/policy versions, supported category/adapter IDs and versions, and setup/update requirements. | The guest exporter reports its own capabilities. Missing or unknown support is explicit; app version alone never enables a category. |
| Shared folders | Available share identities, guest mount/link locations, current availability, and the user's explicitly selected shared content. | Host paths/bookmarks remain local to Try where possible; an opaque share reference binds the private selection. Expose only approved content to capture. Do not recursively follow every external link. |
| User approval | Opaque request identity, VM/account binding, approved inventory/selection revision, selected categories and roots, separately selected credential/profile stores, approved shares, and an expiring authorization binding. | Authorization belongs to this request and source. A changed account, replaced disk, changed selection, or expired approval requires revalidation. The production selection is more specific than the fixture's single credential boolean. |
| Capture lifecycle | One job/lifecycle owner and disk lock; application-preparation results from the exporter; capture identity and cutover time; stable-source mechanism and its outcome. | Record enough evidence to distinguish prepared, capturing, finalized, cancelled, and failed. Do not combine an old inventory/preparation receipt with an unrelated capture. The stable-capture mechanism is a joint decision. |
| Export destination and capacity | A private job-scoped output connection/location, host free space, and capture-environment scratch capacity supplied to preflight. | The exporter supplies bundle/scratch estimates. Exported personal payload reaches macOS only as ciphertext; application dumps and plaintext scratch remain inside the controlled capture environment. A dedicated export connection must work without enabling personal folder sharing. |
| Try-owned changes | Versioned descriptions/examples of injected configuration, menu actions, repository-refresh hooks, share links, and VM/display integration files. | Eduardo reviews which additions belong to Try and their version boundaries. Scott implements the precise exclusion/transformation rules and preserves unrelated user edits. |

Selected Mac shares need a separate capture identity and consistency/change-detection result for each approved external source. Stopping or locking the VM, or mounting a share read-only in the guest, does not stop Mac applications from changing it. Try coordinates the agreed host-side preparation/capture mechanism and the exporter validates its inputs. A disappearing or changing share requires recapture, an explicitly approved omission, or an unavailable/failed result; completion must not claim that inconsistent shared content was captured successfully.

The installer never collects the source Linux login password. Necessary login or sudo prompts remain inside the guest. Transfer-passphrase entry/confirmation must use the agreed private interaction with the exporter; the passphrase is never an argument, status field, persisted request, receipt, or diagnostic log entry.

### B. Inventory the shared exporter returns through Try

After the user approves read-only inventory, the shared exporter returns the following for the selected account. Try surfaces the results and passes the approved selection back; Scott supplies the collectors and policy.

| Inventory item | Required contents |
| --- | --- |
| Inventory identity | Revision bound to the selected VM/account, collection time, exporter/policy versions, and actual capabilities. Final capture validates that the approved scope still applies; an inventory is not a frozen copy of a live home. |
| Categories and roots | Stable category/root identifiers, eligible/default-selected/unavailable state, logical byte estimates and item counts where measurable, and explicit unknown estimates. Detailed paths are private. |
| Applications and tools | Installed package names/versions, known acquisition source/repository, and explicit-versus-dependency status where available; supported tool-manager declarations such as mise. Unknown/custom sources are reported for later handling. No serialized installation commands or imported hooks are executed. |
| Preparation requirements | Applications that need closure or a supported consistent export, available adapter versions, unsupported stores, and failed or pending preparation steps. A closed application is evidence for its declared adapter, not a guarantee that every database format is supported. |
| External dependencies | Selected shared content and destination mapping, unavailable shares, links outside the approved scope, and other inputs requiring a user decision. |
| Omissions and transformations | Known hardware/VM exclusions, credential/profile holdouts, unsupported file types or metadata, and the versioned rules that would alter selected configuration. Unknown personal configuration is preserved under the agreed portable-file policy. |
| Space estimates | Selected logical data size, expected expanded restore size, temporary capture/dump requirements, and ciphertext estimate with explicit uncertainty. Do not assume compression will make the export fit. |

Detailed inventory can contain sensitive filenames and application information. Keep it in the approved local interaction/private job state. General progress messages and the public ciphertext receipt carry opaque identities and aggregate progress, not personal paths or credential contents. No diagnostic upload is required.

### C. Data the shared exporter is expected to put in the encrypted bundle

These are production requirements, not claims that every adapter is implemented. Ordinary personal files and unfamiliar configuration use the generic portable-file policy; they do not need individual application adapters. Browser profiles, protected stores, databases, and other adapter-dependent categories require qualified support and must advertise unavailable rather than fall through to raw copying.

| Category | Intended collected content | Selection and limits |
| --- | --- | --- |
| Personal files and projects | Selected documents and project trees, including dotfiles, Git history, tracked modifications, and untracked work. | Preserve the selected workspace under explicit policy; a fresh Git clone is insufficient. Do not execute project scripts during capture or restore. |
| Personal settings and themes | Shell/editor settings, selected theme/background assets, supported application preferences, and unfamiliar personal configuration. | Apply only enumerated hardware/display/boot/VM exclusions and known Try transformations. Retain originals and report transformations; do not attempt to interpret all user dotfiles. |
| Applications and development tools | Package/tool inventory and supported declarative acquisition metadata. | The destination may download applications and dependencies again. Source machine binaries, package caches, or installation scripts are not a substitute for supported destination installation. Omission rules belong to the versioned exporter policy. |
| Browser profiles | Selected, supported profile data, with browser/version/profile identity and a consistent capture. | Profiles can contain authentication material and require explicit inclusion. Data-only modes are offered only when an adapter can separate them reliably. Brave Origin is a later acceptance case, not current proven support. |
| Credentials and protected stores | Explicitly selected supported SSH/GPG/keyring material, application credential stores, and authentication-bearing CLI/browser data. | Recognized stores are held out before generic traversal unless their supported export mode is selected. No general secret-free guarantee for arbitrary project files. 1Password desktop/extension and Codex CLI are later acceptance cases; data restoration and continued sign-in are separate outcomes. |
| Databases and container data | Consistent exports or supported volume captures with application/format versions and preparation results. | Require an implemented adapter; copying arbitrary live database files is insufficient. An unavailable adapter must be reported, not bypassed. |
| Selected Mac shared content | Explicitly selected shared files, materialized into an agreed destination directory. | Copy only approved content through the controlled capture environment. Do not preserve a broken dependency on the original Mac mount or follow unrelated external links. |

Inside the encrypted manifest, Scott's module records the export/source/account identities, source versions/architecture, selection and policy revisions, capture time, categories, application inventory, per-entry relative paths/types/content digests/sizes/modes/timestamps, declared link and ownership-mapping information, transformations, and omissions. Directory/link/extended-metadata behavior still needs its production contract; unsupported cases must be explicit. Machine-bound display/graphics/boot/VM settings and source account password databases are excluded from restoration. Device-specific credentials that cannot transfer must be reported accordingly.

### D. What a completed Try handoff contains

Try returns the exporter's completed result only after finalization succeeds. The required meanings are:

1. Opaque request and export identities, bound to the approved source/account and selection revision without exposing private account details in the public receipt.
2. Bundle format/version and the exporter/policy versions needed for compatibility checking.
3. Final ciphertext byte length and SHA-256, plus a scoped local reference/stream from which Omarchy Installer can read those exact bytes.
4. Accurate terminal state and access to the private per-category result/omission report. Unavailable or deselected categories are distinguishable from failures.
5. Defined lifetime and retry behavior: retain the source VM and completed export, reconcile repeated requests with the same job, and require explicit cleanup. An interrupted ciphertext file alone is never a completed export.

The installer verifies the received bytes; the importer separately authenticates the encrypted contents with the transfer passphrase. The checksum is not peer authentication or proof of consent. The result carries neither a passphrase nor a whole raw VM disk. Transport-specific access/expiry behavior and the production receipt fields must be agreed before the two apps depend on them.

### E. First implementation Eduardo can start now

Deliver and run the [synthetic fixture](../../Development/migration_bundle_probe/FIXTURE.md) in an existing guest through Try's integration mechanism, with a private export connection and Try-owned job/lifecycle state. The fixture emits fixed fake inventory, progress, and a real encrypted result; Try must identify that result as synthetic. It does not capture a real account or prove that applications were prepared.

Exercise success, cancellation, repeated completed requests, an active/incomplete duplicate request, unavailable output/low space, moved VM storage, and guest/app interruption. Feed the completed ciphertext and receipt to a verifier and show that the original guest remains usable. Keep unsupported production categories unavailable. Scott then replaces the fixture with the shared production module as its contracts are qualified.

Before real-data collection, agree together on the guest upgrade path, VM/disk identity binding, stable-capture mechanism, transfer-passphrase interaction, authenticated local transport, and versioned production schemas. Those are explicit integration decisions, not extra collectors Eduardo must invent.

## Try work packages

### T1. Deliver export support to existing guests

Extend the reviewed integration delivery mechanism with the pinned exporter and declared dependencies. Detect actual installed module/protocol/category capabilities, including missing adapters. Installation approval and any Linux sudo prompt stay inside the guest. Preserve unrelated configuration and support retry after interrupted setup.

**Done when:** an existing guest gains export support without reset or SSH; old/current/unsupported capability fixtures produce explicit outcomes; cancelled or repeated setup preserves unrelated configuration. Deliver packaging changes and capability fixtures.

The inspected [integration updater documentation](https://github.com/omacom/try-omarchy/blob/28f4722fab3e16ae26a7cb8fab2ab7908b1833e4/docs/integration-updates.md) looks like the starting point. My installed M4 app reports 0.4.0/build 5 but lacks the payload described by that checkout. Scott and Eduardo need to identify the correct development build and upgrade path; app version alone is insufficient.

### T2. Coordinate consent and a consistent capture

Resolve the selected VM through Try, including moved storage. Bind approval to one account, selection, and export request. Coordinate the shared module's application preparation hooks, then capture from a stable source. Application preparation followed, where needed, by a clean stop and controlled maintenance capture is the proposed direction. I would like your recommendation on the exact mechanism and how it fits Try's recovery/boot support.

Keep one lifecycle owner and disk lock. Copying an actively written disk cannot establish consistency. Handle already-running/stopped guests and cancellation during preparation or shutdown, without forced power-off after a timeout.

**Done when:** capture represents the agreed cutover; preparation failure or unexpected source changes cannot produce a completed export; cancellation/restart preserve a usable source; duplicate requests cannot create a second VM writer. Deliver the lifecycle state model and failure tests.

### T3. Produce a completed local export

Give the exporter a dedicated private output location scoped to the migration job. Personal folder sharing must not be required. Personal payload leaves the guest encrypted; application dumps or plaintext scratch stay within the controlled capture environment. The shared module constructs and encrypts the archive; Try owns the connection and job lifecycle.

Expose preparation/capture/finalization progress. Publish completion only after the whole ciphertext is durably finalized and checked. Return an opaque export identity, format version, ciphertext size/digest, and scoped access to the output. The receiver verifies bytes against the receipt; private filenames stay inside the encrypted manifest. Agree on transfer-passphrase interaction with the shared exporter and keep the secret out of command arguments, logs, persisted requests, and staged files.

**Done when:** a synthetic export completes locally; disk-full, guest failure, and cancellation cannot report incomplete output as complete. Repeated requests attach/resume where supported or explicitly require restart. Preserve completed exports and clean only known migration-owned partial artifacts. Deliver the fixture flow and failure evidence.

### T4. Connect Try to the installer

Add a dedicated local interface for capability discovery, inventory requests, export start, status/result retrieval, and cancellation. Try retains guest approval. Scott implements the Omarchy Installer client against the same fixtures.

Choose transport together after checking actual signing/packaging. Authenticate peers and bind requests to the source, consent, and expiry. Existing Touch ID/settings/status channels keep their current roles; the advisory integration status channel must not become an arbitrary command runner.

**Done when:** the genuine installer completes the fixture flow; wrong peers, expired/replayed authorization, and mismatched VM/account requests fail before export. App restarts reconcile with the existing job; duplicates attach to it. Deliver the Try endpoint and shared request/result fixtures.

## Initial contract to agree together

These are proposed semantics; exact field names and transport remain open.

| Exchange | Required information or behavior |
| --- | --- |
| Capabilities | Protocol/module/policy versions, source identity, supported categories/adapters, and setup/update requirements. |
| Inventory | Approved read-only account inventory: category sizes, applications, shared-folder dependencies, exclusions, and unavailable features. Detailed inventory belongs to the approved interaction, not public logs. |
| Export request | Opaque request ID, VM/account binding, inventory/selection revision, explicit credential selections, and expiring authorization binding. Source or selection changes require revalidation. |
| Status | Monotonic event sequence, phase, measurable progress, cancellation availability, and bounded actionable errors. Suggested phases: awaiting approval, preparing, capturing, finalizing, complete/cancelled/failed. |
| Completed result | Export ID, request/source binding, format, ciphertext size/digest, and restricted output reference. A checksum checks bytes; it does not authenticate or authorize export. |
| Retry/cancel | Same request and parameters attach to the same job; conflicting reuse fails. Cancellation is idempotent and eventually returns an accurate terminal result. Partial output is never complete. |

Try owns source consent and the VM lifecycle journal. The shared module owns export validation/publication; the installer/importer own separate staging and restore journals. Receipts must let each component recover without inventing another component's success.

## Delivery sequence

1. **Agree on the boundary and fixture.** Scott has supplied a [runnable synthetic exporter and sample request](../../Development/migration_bundle_probe/FIXTURE.md) with progress, cancellation, and completed-job reuse. Together choose production capture sequencing, passphrase interaction, and local transport. Try lifecycle and delivery review can begin against this explicit test-only interface.
2. **Try-only export milestone.** T1–T3 run synthetic projects/configuration through an existing VM and produce an encrypted bundle locally. A development action inside Try is sufficient. Test success, cancel, interruption, low space, moved storage, and duplicate requests.
3. **Installer coordination milestone.** Add T4 and the Omarchy Installer client. Test authenticated requests, source/account binding, app restart, status, and cancellation against synthetic data.
4. **Shared exporter integration.** Replace the fixture once production portable export/restore passes. Test a custom theme, unknown personal configuration, and Git work including uncommitted/untracked files; then qualify profiles, credentials, and databases through supported adapters.
5. **Native handoff acceptance.** Scott connects staging/import after proving survival through the actual reboot/encryption flow. Test the complete journey against an immutable cross-repository candidate and separately qualify supported physical hardware.

Milestones 1–3 can progress independently of native target staging. Their success establishes Try integration, not end-to-end migration. Production file/crypto contracts must settle before milestone 4.

## Current progress

Requirements and source inventory are documented. The age-based bundle has 18 behavioral tests, staging has 44 cases, and the runnable fixture adds 10 request/result and cancellation checks. The [additive restoration experiment](../../Development/migration_bundle_probe/RESTORE.md) adds authenticated staging, file restoration into disposable destinations, conflict preservation, and retry after interruption. Its [v2 tree extension](../../Development/migration_bundle_probe/TREE.md) adds explicit directories, selected relative links, inert unsupported links, and a real synthetic Git repository roundtrip preserving committed, modified, and untracked work. Actual SIGKILL tests cover file and symlink publication. Source directory metadata remains deferred. The [validation record](validation.md) identifies which checks ran and any optional skip. An [isolated M4 experiment](m4-hvf-experiment.md) also passed Btrfs growth, interrupted-copy resume, and authentication after a clean second boot. The production exporter/importer, application adapters, and complete native reboot/encryption handoff remain unfinished; the probe does not restore a user's home.

My M4 with Try is available for synthetic experiments. Later real examples are Brave Origin, 1Password desktop/extension, Codex CLI through mise, and theme/custom settings. Restoring app data and retaining an authenticated session are separate outcomes; fresh sign-in may be necessary. M4 VM testing does not establish native hardware support.

The proposal is that you take T1–T4 on the Try side, starting with delivery/lifecycle review and the fixture milestone. Scott supplies the fixture and then the shared production module, and owns the Omarchy Installer client and native staging/restore work. The first joint decisions are the guest upgrade path, stable-capture mechanism, passphrase interaction, and authenticated local interface.

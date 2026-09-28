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

Requirements and source inventory are documented. The age-based bundle has 18 behavioral tests, staging has 44 cases, and the runnable fixture adds 10 request/result and cancellation checks. A new [additive restoration experiment](../../Development/migration_bundle_probe/RESTORE.md) adds authenticated staging, file restoration into disposable destinations, conflict preservation, and retry after interruption, including a fresh-process SIGKILL recovery test. The [validation record](validation.md) identifies which checks ran and any optional skip. An [isolated M4 experiment](m4-hvf-experiment.md) also passed Btrfs growth, interrupted-copy resume, and authentication after a clean second boot. The production exporter/importer, application adapters, and complete native reboot/encryption handoff remain unfinished; the probe does not restore a user's home.

My M4 with Try is available for synthetic experiments. Later real examples are Brave Origin, 1Password desktop/extension, Codex CLI through mise, and theme/custom settings. Restoring app data and retaining an authenticated session are separate outcomes; fresh sign-in may be necessary. M4 VM testing does not establish native hardware support.

The proposal is that you take T1–T4 on the Try side, starting with delivery/lifecycle review and the fixture milestone. Scott supplies the fixture and then the shared production module, and owns the Omarchy Installer client and native staging/restore work. The first joint decisions are the guest upgrade path, stable-capture mechanism, passphrase interaction, and authenticated local interface.

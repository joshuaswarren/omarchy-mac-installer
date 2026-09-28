# Authenticated, additive restoration experiment

This extends the existing synthetic bundle probe with a library interface for regular-file restoration into a disposable destination. It is not a real-home importer or an installed command. The production module still belongs in the shared Omarchy runtime at `install/migration/omarchy_migration/`, exposed by `bin/omarchy-migration`; Try and native installation must consume one pinned implementation. These experiments settle behavior before that promotion, rather than establishing an independent installer-side import engine.

## Interface

`verified_bundle(age, secret, ciphertext)` is a context manager. It streams numbered objects into a private temporary directory using the existing bounded archive validator. The caller receives a verified handle only after every manifest/content check, authenticated EOF, and successful age exit. Bad passphrases, bad final tags, truncation, or invalid archives release no handle. Plaintext scratch files always have mode 0600, regardless of the requested final mode; the scratch directory has mode 0700.

`Restorer(bundle, target, job)` is a context manager for one locked restore job. The caller supplies an existing disposable target directory and a separate, initially empty 0700 job directory on the same filesystem. Both belong to the current unprivileged user. Neither tree may contain the other. The caller owns creation and synchronization of those root directories and their parents. The journal binds the complete manifest digest, export identity, target device/inode/owner, and job device/inode/owner. A copied journal, another bundle with the same export ID but changed metadata, or another destination cannot reuse the job.

`plan()` returns immutable per-path actions without changing destination files. It records file observations and existing parent directory identities. `apply(plan)` accepts only the latest plan from that live job. Changes between planning and application become conflicts; newly created directories are admitted only when created by that same application. `apply` returns a result for each selected file when it completes; an I/O or process failure aborts without claiming completion, leaving the journal for another invocation.

Illustrative Python usage inside a synthetic test harness:

```python
with verified_bundle(age, synthetic_secret, ciphertext) as bundle:
    with Restorer(bundle, disposable_target, private_job_directory) as importer:
        plan = importer.plan()
        report = importer.apply(plan)
```

The fixture intentionally has no command that accepts a home directory. No file is executed, no account is created, and no privilege escalation or application installation occurs. File ownership comes from the current process and destination filesystem, never from imported account IDs.

## File policy

| Situation | Result |
| --- | --- |
| Absent regular file | Copy authenticated bytes, set mode and nanosecond mtime, then publish without replacement. |
| Existing file with matching bytes, mode, and mtime | Report `present`; retain the existing inode. |
| Existing differing file, link, special file, or unsafe parent | Report `conflict`; preserve it. |
| Prior publication still matches its recorded inode, bytes, and metadata | Report `restored`; reconcile completion without republishing. |
| Prior publication edited, deleted, replaced, or no longer verifiable | Report `conflict`; preserve the observed state. |
| File missing after durable publication intent | Report `conflict`; the importer cannot distinguish interruption before creation from a later user deletion. |
| Source mode lacks owner-read permission | Report `conflict`; this probe cannot verify retries without changing that mode. |

Destination traversal uses pinned directory descriptors and refuses symlink components. Newly needed directories use mode 0700. Original directory metadata is not represented in the probe manifest. Only selected regular files are represented; links and special archive entries remain rejected. ACLs, xattrs, sparse layout, hardlink relationships, and atime preservation are outside this experiment.

## Publication and recovery

1. Recheck the planned destination observation and directory identities.
2. Copy an authenticated scratch object into a new private job file, recheck its size/digest, apply final metadata, and synchronize the file and its directory entry.
3. Persist and synchronize publication intent, including that file's inode/content/metadata witness.
4. Hardlink into the destination without replacing an existing entry, then synchronize the destination directory. Synchronize each newly created parent directory entry as well.
5. Persist completed state, then remove the job's temporary link and synchronize the job directory.

After step 4, the pending job file and destination share an inode. Retry never rewrites, chmods, or repairs a pending inode: doing so would modify the destination too. Recovery after uncertain publication requires positive evidence from the destination, not merely a surviving pending file. A completed user deletion also stays deleted. Unrelated entries can proceed while a conflicting entry remains unresolved.

The job lock excludes another cooperative importer using the same job directory. Atomic non-replacing publication also protects against a leaf file appearing just before publication. The destination namespace must remain quiescent during each operation: directory descriptors and symlink refusal do not protect against an arbitrary concurrent same-user directory rename outside the target. Between `plan` and `apply`, nested directory replacements are detected. This is not a privileged extractor for hostile users.

Normal context exit and exceptions remove verified plaintext scratch. SIGKILL or host failure can leave that private scratch and unreferenced private job objects; recovery does not sweep them automatically. Pending conflicts deliberately retain their evidence. Production cleanup, encrypted scratch placement, space budgeting, and power-loss qualification remain required. The caller must not use these experimental plaintext paths for real personal data.

## Checks and next work

With the [verified age dependency](README.md#run-checks) configured, run:

```bash
python3 -W error::ResourceWarning -m unittest Development.migration_bundle_probe.test_restore -v
```

The cases cover byte/metadata roundtrip, no destination writes before authentication, private scratch cleanup, existing files/links/FIFOs, nested parent replacement, changed plans, wrong job/target/manifest binding, duplicate jobs, post-import edits/deletions, publication races, interrupted hardlinks, journal synchronization failures, and recovery by a fresh process after an actual SIGKILL immediately after publication. That process test does not simulate filesystem or host power loss. The shared crypto tests remain necessary because restoration reuses their validator.

The next production work includes stable source capture and early credential holdouts, explicit directory/link/extended-metadata policy, user-approved replacement with durable backups, Try-specific configuration transformations, scalable journals/capacity checks, safe plaintext lifecycle, packaging, and the shared public command. Tickets 04 and 05 remain incomplete. Native owner setup and reboot/encryption integration are separate gates.

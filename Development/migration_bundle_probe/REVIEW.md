# Reviewable import plans and reports

`review.py` turns the [restorer](RESTORE.md) into the two documents the installer's review screen needs: a [`plan/1`](../migration_contract/CONTRACT.md#public-documents) before anything changes, and a `report/1` afterwards. It restores only into a caller-owned disposable target, exactly like the restorer it wraps; it is not a real-home importer.

## Run

Use Linux, Python 3.11+ and the verified age dependency from [README.md](README.md). Export a bundle with the [fixture](FIXTURE.md) first, then:

```bash
python3 -m Development.migration_bundle_probe.review plan \
  --bundle job/bundle.age --receipt job/receipt.json \
  --target /path/to/disposable-target --job /path/to/private-restore-job \
  --passphrase-fd 3 3<passphrase-file

python3 -m Development.migration_bundle_probe.review apply --plan-id <plan_id from the plan> \
  --bundle job/bundle.age --receipt job/receipt.json \
  --target /path/to/disposable-target --job /path/to/private-restore-job \
  --passphrase-fd 3 3<passphrase-file
```

The passphrase is read from a file descriptor, never from arguments: at most 1024 bytes plus one optional trailing newline; empty input, CR, NUL or a second line is refused as `passphrase_invalid`. The descriptor must reach end of file. Operational errors print one JSON object with an `error` code to standard error and exit 1; command-line usage errors, including `--plan-id` on `plan` or its absence on `apply`, exit 2 with usage text. Errors never include the passphrase or destination paths.

## What the plan binds

The plan is computed after the bundle is fully authenticated. Its `bundle_sha256` is the digest of the exact ciphertext bytes that age authenticated, hashed while they were fed to age, not a separate read of the file. The public receipt must name the same export and ciphertext digest or planning fails with `receipt_mismatch`. `plan_id` is derived from that digest, the destination account, the restorer's pinned job binding (manifest digest, export, target and job directory identities, approved replacements), the canonical receipt including its policy revision, and every planned action. It changes when the destination, job directory, receipt or any planned action changes. An empty export cannot be planned (`empty_bundle`). `apply` re-plans in its own process and refuses with `plan_changed`, writing nothing, unless the result has the reviewed `plan_id`.

Counts map every restorer action, including directories, onto the contract: `create`, `present` (including entries this job already restored), `replace`, `conflict` and `inert`. `omit` stays 0 because unselected categories never enter the bundle. `required_bytes` is the size of files to be written; private backups for approved replacements are not yet included. Package reinstall counts are zero until application support exists.

## What the report says

`report/1` groups results by [category](categories.py). Directories count as restored entries. Any status other than the restorer's known results is refused rather than guessed. A category is `restored` when everything selected is in place, `partial` when some entries restored and some conflicted, `failed` when nothing restored because of conflicts, and `skipped` when everything was omitted. `omitted` counts inert entries, such as a link into the Mac shared folder. Reasons are stable codes mapped from the restorer's messages (`destination_exists`, `destination_changed`, `dependency_unavailable`, `link_not_restorable` and others); a test fails if the restorer gains a message without a code. `job_id` is derived from the restorer's job binding, so retries of one job report under the same id. Per-file detail stays in the private job.

## Limits

Directory metadata (mode, mtime) is still deferred by the restorer, although directories are counted. If `apply` fails partway, for example because a destination directory disappears, the command exits 1 with an error code and no report; the restore journal keeps what was published, and running `plan` and `apply` again continues the same job. Plans are summaries for review, not a substitute for the restorer's own journal and conflict checks, which still run during `apply`. The command inherits every restorer boundary: synthetic or disposable data only, a quiescent destination, and no privilege, account creation or application installation.

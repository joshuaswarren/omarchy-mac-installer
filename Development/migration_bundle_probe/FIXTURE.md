# Runnable synthetic exporter for integration development

This command supplies the first executable fixture in the [collaboration plan](../../docs/try-omarchy-migration/collaboration-plan.md). It creates fixed fake project/configuration/credential files, encrypts them with the existing probe, and emits line-delimited JSON progress and a completed result. It has no source-home argument, does not discover a real account, and is not the production migration API.

## Run

Use Linux and Python 3.11+. For export, configure the independently verified age 1.3.2 executable and hash described in [README.md](README.md). Capabilities and inventory need no crypto dependency.

```bash
python3 -m Development.migration_bundle_probe.fixture capabilities
python3 -m Development.migration_bundle_probe.fixture inventory

python3 -m Development.migration_bundle_probe.fixture export \
  --request Development/migration_bundle_probe/fixture-request.json \
  --output-directory /absolute/path/to/a/new-private-job
```

The parent directory must exist; the command creates the job directory with mode 0700. The [sample request](fixture-request.json) uses a public fixture UUID. Assign a new canonical UUID for a new integration job. Requests require exactly the schema, request ID, and explicit boolean credential selection. Unknown fields, duplicate JSON keys, unsupported schema, and requests larger than 8 KiB fail before creating output.

All generated contents and the transfer passphrase are deliberately public test data. The passphrase is **synthetic-only-otter-maple-window-cobalt**. Setting `include_credentials` to true adds fake SSH and browser entries; it does not enable an actual credential adapter. Do not use this command or passphrase for personal data.

## Observable behavior

An export emits `preparing`, `capturing`, `finalizing`, then `complete`. Each JSON event carries the fixture schema, `synthetic: true`, request ID, and a sequence number scoped to this CLI invocation. The completed event contains a receipt with the exact request, export ID, age format, ciphertext byte count/SHA-256, and fixed `bundle.age` filename. Private manifest filenames remain encrypted.

The job directory contains `request.json`, `bundle.age`, and `receipt.json`. Completion requires the entire bundle to be authenticated and its decoded manifest compared with the selected synthetic input. Ciphertext, receipt, and directory entries are synchronized before the completed event. A bare ciphertext file is not a completed job; consumers require the receipt and verify bytes against it. Receipt/digest checking is not app authentication or proof of user consent.

Repeating the same request against a completed job validates the receipt, ciphertext, and export identity, then returns the same result with `reused: true`. It does not rewrite the bundle. A changed selection/request, changed ciphertext, symlinked job, or unrelated directory fails. A concurrent or interrupted job without a complete receipt returns `job_incomplete_use_new_directory`; the fixture does not start another writer or resume incomplete encryption. The Try controller remains responsible for identifying/attaching to its own active process. Use a new job directory after an incomplete fixture run, retaining the old one for inspection.

SIGINT/SIGTERM request cooperative cancellation. Checks occur between phases and archive writes; cancellation may wait for the current bounded age operation. Cancellation before receipt publication returns exit 130 and a `cancelled` event without a completed receipt. Once durable receipt publication starts, completion may win the race. SIGKILL, controller death, and power loss are not recovered by this fixture. Ordinary failure returns exit 1 and a `failed` event; command-line syntax errors use argparse's exit 2.

For deterministic cancellation/UI experiments, add `--pause-before-capture 30` and signal the owned process after its `preparing` event. The delay is limited to 30 seconds and is fixture-only. No real VM or application is stopped by this command.

## Limits

This is an explicit synthetic protocol, separate from the proposed production `omarchy-migration` command. It supplies inventory/export examples and a completed-job retry contract, not real consent, VM/account binding, authenticated IPC, application quiescence, importer/extraction, or arbitrary job recovery. The caller must own the output location; the fixture is not hardened against another same-user process maliciously replacing paths during an operation. The existing probe's PTY, process/resource, link/metadata, and live-capture limitations still apply.

The tests exercise the actual CLI and age executable, default/explicit fake-credential selection, repeated completion, changed request/ciphertext, unrelated directories/symlinks, malformed requests, cancellation, and duplicate invocation while active. These checks make the integration fixture usable for development; they do not qualify real user-data migration.

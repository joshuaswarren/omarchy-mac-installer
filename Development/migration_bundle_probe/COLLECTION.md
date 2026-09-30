# Credential-aware disposable collection

This synthetic library captures a caller-created, quiescent fixture tree into a private temporary snapshot. The existing v2 exporter consumes only those copied objects. It advances collection behavior for tickets 04–05 without installing a scanner, accepting a real-home CLI argument, or claiming supported application exports. The runnable Try fixture remains unchanged.

## Separate selection and trusted policy

The request chooses source roots, archive names, and explicitly selected synthetic adapters:

```json
{
  "schema": "omarchy-migration-collection-request/1",
  "request_id": "00000000-0000-4000-8000-000000000001",
  "selection": [{"source": "", "archive": ""}],
  "selected_adapters": []
}
```

The trusted fixture creator separately supplies a versioned layout; the request cannot change protected paths:

```json
{
  "schema": "omarchy-migration-fixture-layout/1",
  "policy_revision": "fixture-holdouts/1",
  "layout_id": "synthetic-example/1",
  "stores": [
    {"id": "fake-ssh", "roots": [".ssh", "alternate/ssh"], "adapter": "fixture-ssh-bytes/1"},
    {"id": "fake-browser", "roots": [".config/BraveSoftware", "alternate/config/BraveSoftware"], "adapter": "fixture-browser/1"},
    {"id": "fake-codex", "roots": [".codex/auth.json", "alternate/codex/auth.json"], "adapter": null}
  ]
}
```

These are fake-store rules. Actual application locations, alternate paths/environment settings, supported source versions, and supported export modes still need qualification. The generic collector does not run adapters; the trusted capability set can enable a test-only byte-copy policy for a fake store. It must never be advertised as real SSH/browser/Codex support. Unsupported stores remain withheld under explicit selection.

Requests and layouts use exact field sets and bounded normalized paths. Unknown schemas/policies/adapters, overlapping store roots, duplicate selections/adapters, and conflicting source/archive selections reject. An empty source selects fixture-root contents; an empty archive is allowed only with that source. Nonempty archive roots have one path component in this slice; deeper mappings require a later ancestor-metadata contract. Depth is limited to 64 components, entry/report count to the existing probe limit, and captured bytes to the existing expanded-content limit.

## Capture interface and isolation

```python
with collect_fixture(disposable_source, request, trusted_fixture_layout,
                     supported_adapters=("fixture-ssh-bytes/1",),
                     snapshot_parent=private_scratch_parent) as snapshot:
    probe.encrypt(age, synthetic_secret, output,
                  lambda stream: probe.write_archive(stream, snapshot.manifest, snapshot.paths))
```

The caller supplies existing owned directories. The source must not be writable by others, and the snapshot parent must have mode 0700, lie outside the source, and remain caller-controlled and quiescent. Temporary-directory creation uses the checked parent's pathname; this is not a privileged facility for a hostile parent namespace. The collector refuses root execution and symlink root/parent components at the final open. Caller-supplied parent paths are trusted.

Source traversal uses pinned directory descriptors, nofollow opens, owner checks, and Linux descriptor mount identities. Nested mounts, including same-filesystem bind mounts, reject before payload reads or directory enumeration. No test mounts a filesystem; the mount rejection regression injects a differing descriptor identity. All generic regular files with multiple hardlinks are deferred before reading, preventing a protected file from leaking through an ordinary hardlink alias under the current unsupported-hardlink policy.

Protected-path classification happens in source space before stat/open/descendant enumeration and before archive-name remapping. A pruned subtree produces one report item with unknown descendant count; collecting inventory does not inspect the withheld store. Similar-prefix ordinary paths, unfamiliar configuration, and unknown durable data remain eligible. Symlinks are copied as text without traversal. Identity-mapped links use the existing safe/inert v2 rule. If any selection renames a root, all symlinks are deferred with `remapped-link`: v2 cannot explicitly force a source link inert when archive names would accidentally activate it against different data.

Regular files are copied through checked descriptors with size/metadata/identity checks before and after reading. Directories have bounded sorted names and before/after metadata/name checks; a final metadata pass checks captured entries and the original root. Changed sources abort without yielding a handle, and ordinary errors remove only the owned snapshot. These checks require quiescence and do not establish a coherent atomic cutover across live applications, databases, or host shares.

Snapshot files remain 0600 and directories 0700. Original source mode/mtime and link text are recorded in the validated v2 manifest; copied object permissions do not impersonate source final permissions. Original source paths are never supplied to archive writing. Later source edits/deletions cannot change the captured bytes. Mode/mtime/link metadata is the portable scope; ACLs, xattrs, sparse layout, special permission bits, ownership recreation, and hardlink relationships are not preserved. Destination directory metadata remains deferred by the importer.

## Private report and lifetime

`snapshot.report` uses `omarchy-migration-collection-report/1`. It includes request identity, request/layout/capability digests, supported synthetic adapter IDs, policy revision, per-source/archive outcomes and aggregate counts. Outcomes are `included`, `held-out`, `unsupported`, and `inert-link`; reasons distinguish unavailable/unselected stores, multiply linked/unreadable files, special files, remapped links, and unavailable link targets. `complete` means the bounded capture finished with accounted omissions, not that every selected category transferred or that an encrypted export is complete.

The report contains private paths and is not a public receipt. It is not yet stored as authenticated bundle provenance. Production source/account identity, authorization/selection revision binding, capture evidence, metadata/omission representation and encrypted private report handling remain contract work. No diagnostic upload occurs.

The context owns snapshot lifetime and removes it on normal exit or exception. It has no durable restart/resume protocol. SIGKILL or host failure can leave private plaintext scratch; production encrypted scratch placement, capacity, artifact reconciliation, and cleanup remain necessary. Do not use this experiment on real personal data.

## Verification and next work

```bash
python3 -W error::ResourceWarning -m unittest Development.migration_bundle_probe.test_collection -v
```

Most cases require only Linux/Python and temporary files. The encrypted roundtrip additionally requires the verified age dependency. Tests prove held-out descendants are neither opened nor listed, default/alternate roots behave consistently, source remapping cannot bypass policy, symlink/hardlink aliases do not copy fake secrets, supported fake opt-in does not enable unavailable adapters, changed sources and resource limits fail before completion, and encrypted restoration retains captured settings/project bytes after later source edits. Exact Try transformations and authenticated original retention are the next file-policy work; live capture and production runtime integration remain separate gates.

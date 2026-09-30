"""Holdouts precede traversal; private snapshots isolate later source changes."""

import copy
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
import uuid
from unittest.mock import patch

from Development.migration_bundle_probe import collection, probe, restore
from Development.migration_bundle_probe.dependency import configured_age


SECRET = b"synthetic-only-otter-maple-window-cobalt"
MTIME = 1720000000123456789


class CollectionTests(unittest.TestCase):
    def setUp(self):
        if os.geteuid() == 0:
            self.skipTest("unprivileged fixture collector")
        self.scratch = tempfile.TemporaryDirectory(prefix="migration-collection-test-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.source, self.parent = self.root / "source", self.root / "snapshots"
        self.source.mkdir(mode=0o700)
        self.parent.mkdir(mode=0o700)
        self.request = {"schema": collection.REQUEST_SCHEMA, "request_id": str(uuid.uuid4()),
                        "selection": [{"source": "", "archive": ""}], "selected_adapters": []}
        self.layout = {
            "schema": collection.LAYOUT_SCHEMA, "policy_revision": collection.POLICY,
            "layout_id": "synthetic-default-and-alternate/1", "stores": [
                {"id": "fake-ssh", "roots": [".ssh", "alternate/ssh"], "adapter": "fixture-ssh-bytes/1"},
                {"id": "fake-browser", "roots": [".config/BraveSoftware", "alternate/config/BraveSoftware"],
                 "adapter": "fixture-browser/1"},
                {"id": "fake-codex", "roots": [".codex/auth.json", "alternate/codex/auth.json"], "adapter": None},
                {"id": "fake-vault", "roots": [".config/1Password", "alternate/vault"], "adapter": None},
            ],
        }
        self.ordinary = {
            ".config/unknown/settings": b"unfamiliar personal configuration\n",
            ".config/theme/selected": b"custom-theme\n",
            ".codex/config.toml": b"synthetic ordinary CLI preferences\n",
            ".local/share/unknown/data": b"ordinary durable data\n",
            ".ssh-personal-notes/readme": b"similar prefix is ordinary\n",
            "Projects/demo/.git/HEAD": b"ref: refs/heads/main\n",
            "Projects/demo/modified": b"uncommitted synthetic work\n",
            "Projects/demo/untracked": b"untracked synthetic work\n",
            "Projects/demo/run": b"#!/bin/bash\ntouch MUST-NOT-RUN\n",
        }
        self.protected = {
            ".ssh/id_fake": b"FAKE-SSH-SECRET",
            "alternate/ssh/id_fake": b"FAKE-ALTERNATE-SSH-SECRET",
            ".config/BraveSoftware/profile/token": b"FAKE-BROWSER-SECRET",
            "alternate/config/BraveSoftware/profile/token": b"FAKE-ALTERNATE-BROWSER-SECRET",
            ".codex/auth.json": b"FAKE-CODEX-SECRET",
            "alternate/codex/auth.json": b"FAKE-ALTERNATE-CODEX-SECRET",
            ".config/1Password/vault": b"FAKE-VAULT-SECRET",
            "alternate/vault/vault": b"FAKE-ALTERNATE-VAULT-SECRET",
        }
        for name, data in {**self.ordinary, **self.protected}.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            path.write_bytes(data)
            path.chmod(0o750 if name.endswith("/run") else 0o600)
            os.utime(path, ns=(MTIME, MTIME))
        (self.source / "empty").mkdir(mode=0o750)
        (self.source / "readme-link").symlink_to("Projects/demo/modified")
        (self.source / "secret-alias").symlink_to(".ssh/id_fake")
        (self.source / "store-alias").symlink_to(".ssh", target_is_directory=True)

    def capture(self, **kwargs):
        return collection.collect_fixture(self.source, self.request, self.layout,
                                          supported_adapters=("fixture-ssh-bytes/1",),
                                          snapshot_parent=self.parent, **kwargs)

    def assert_private(self, snapshot):
        self.assertEqual(stat.S_IMODE(snapshot.directory.stat().st_mode), 0o700)
        for path in snapshot.paths.values():
            if path.is_file() and not path.is_symlink():
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            elif path.is_dir() and not path.is_symlink():
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)

    def test_default_preserves_unknown_config_and_reports_every_pruned_store(self):
        with self.capture() as snapshot:
            self.assertTrue(set(self.ordinary) <= snapshot.paths.keys())
            self.assertTrue(all(snapshot.paths[name].read_bytes() == data for name, data in self.ordinary.items()))
            self.assertTrue(set(self.protected).isdisjoint(snapshot.paths))
            omitted = {item["source"] for item in snapshot.report["entries"] if item["outcome"] == "held-out"}
            self.assertEqual(omitted, {root for store in self.layout["stores"] for root in store["roots"]})
            self.assertEqual(snapshot.report["counts"]["held-out"], 8)
            self.assertEqual(snapshot.report["status"], "complete")
            self.assert_private(snapshot)
            directory = snapshot.directory
        self.assertFalse(directory.exists())
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_held_out_descendants_are_neither_opened_nor_listed(self):
        blocked = [self.source / root for store in self.layout["stores"] for root in store["roots"]]
        opened, scanned = os.open, os.scandir

        def guard_path(value, dir_fd=None):
            if isinstance(value, int):
                path = Path(f"/proc/self/fd/{value}").resolve()
            else:
                base = Path(f"/proc/self/fd/{dir_fd}").resolve() if dir_fd is not None else Path.cwd()
                path = Path(os.path.abspath(base / value))
            self.assertFalse(any(path.is_relative_to(root) for root in blocked), str(path))

        def guarded_open(value, flags, *args, **kwargs):
            guard_path(value, kwargs.get("dir_fd"))
            return opened(value, flags, *args, **kwargs)

        def guarded_scan(value):
            guard_path(value)
            return scanned(value)

        with patch.object(collection.os, "open", side_effect=guarded_open), patch.object(
                collection.os, "scandir", side_effect=guarded_scan), self.capture() as snapshot:
            self.assertEqual(snapshot.report["counts"]["held-out"], 8)

    def test_unreadable_protected_directory_is_pruned_without_entering_it(self):
        protected = self.source / ".ssh"
        protected.chmod(0o000)
        try:
            with self.capture() as snapshot:
                self.assertNotIn(".ssh", snapshot.paths)
        finally:
            protected.chmod(0o700)

    def test_protected_source_remapped_to_ordinary_name_remains_held_out(self):
        self.request["selection"] = [{"source": "alternate/config/BraveSoftware", "archive": "notes"}]
        self.request["selected_adapters"] = ["fixture-browser/1"]
        with self.capture() as snapshot:
            self.assertEqual(snapshot.paths, {})
            self.assertEqual(snapshot.report["entries"][0]["archive"], "notes")
            self.assertEqual(snapshot.report["entries"][0]["reason"], "adapter-unavailable")

    def test_nested_store_policy_uses_source_names_after_ancestor_remap(self):
        self.request["selection"] = [{"source": "alternate", "archive": "Recovered"}]
        with self.capture() as snapshot:
            self.assertNotIn("Recovered/ssh/id_fake", snapshot.paths)
            held = [item for item in snapshot.report["entries"] if item["outcome"] == "held-out"]
            self.assertEqual({item["source"] for item in held},
                             {"alternate/ssh", "alternate/config/BraveSoftware", "alternate/codex/auth.json", "alternate/vault"})

    def test_explicit_supported_fixture_adapter_includes_only_its_fake_stores(self):
        self.request["selected_adapters"] = ["fixture-ssh-bytes/1", "fixture-browser/1"]
        with self.capture() as snapshot:
            self.assertEqual(snapshot.paths[".ssh/id_fake"].read_bytes(), self.protected[".ssh/id_fake"])
            self.assertEqual(snapshot.paths["alternate/ssh/id_fake"].read_bytes(), self.protected["alternate/ssh/id_fake"])
            self.assertNotIn(".config/BraveSoftware", snapshot.paths)
            self.assertNotIn(".codex/auth.json", snapshot.paths)
            self.assertFalse(any(item["source"] == ".ssh" and item["outcome"] == "held-out"
                                 for item in snapshot.report["entries"]))

    def test_symlink_aliases_are_metadata_only_and_held_out_targets_are_inert(self):
        with self.capture() as snapshot:
            by_path = {entry["path"]: entry for entry in snapshot.manifest["entries"]}
            self.assertEqual(by_path["secret-alias"]["target"], ".ssh/id_fake")
            self.assertEqual(by_path["store-alias"]["kind"], "symlink")
            self.assertIsNone(probe.link_target(by_path["secret-alias"], by_path))
            self.assertIsNotNone(probe.link_target(by_path["readme-link"], by_path))
            self.assertEqual(snapshot.report["counts"]["inert-link"], 2)

    def test_selected_symlink_ancestor_is_never_followed(self):
        self.request["selection"] = [{"source": "store-alias/id_fake", "archive": "notes"}]
        with self.assertRaises(OSError):
            with self.capture():
                self.fail("followed a symlink parent")
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_hardlink_alias_is_deferred_before_any_payload_read(self):
        alias = self.source / "Projects/demo/key-notes"
        os.link(self.source / ".ssh/id_fake", alias)
        opened = os.open

        def guard(value, *args, **kwargs):
            self.assertNotEqual(os.fspath(value), "key-notes")
            return opened(value, *args, **kwargs)

        with patch.object(collection.os, "open", side_effect=guard), self.capture() as snapshot:
            self.assertNotIn("Projects/demo/key-notes", snapshot.paths)
            item = next(item for item in snapshot.report["entries"] if item["source"] == "Projects/demo/key-notes")
            self.assertEqual(item["reason"], "multiply-linked-file")

    def test_remapped_links_are_deferred_instead_of_activating_different_targets(self):
        (self.source / "project").mkdir(mode=0o700)
        (self.source / "other").mkdir(mode=0o700)
        (self.source / "project/link").symlink_to("../ordinary")
        self.request["selection"] = [{"source": "project", "archive": "project"},
                                     {"source": "other", "archive": "ordinary"}]
        with self.capture() as snapshot:
            self.assertNotIn("project/link", snapshot.paths)
            item = next(item for item in snapshot.report["entries"] if item["source"] == "project/link")
            self.assertEqual(item["reason"], "remapped-link")

    def test_special_file_is_reported_without_opening_it(self):
        os.mkfifo(self.source / "fifo")
        with self.capture() as snapshot:
            self.assertNotIn("fifo", snapshot.paths)
            self.assertEqual(next(item["reason"] for item in snapshot.report["entries"] if item["source"] == "fifo"),
                             "special-file")

    def test_changed_source_during_copy_fails_and_removes_private_snapshot(self):
        walk = collection._Snapshot._walk

        def change(snapshot, parent, name, source, archive):
            walk(snapshot, parent, name, source, archive)
            if source == "Projects/demo/modified":
                (self.source / source).write_bytes(b"modified after that file was captured")

        with patch.object(collection._Snapshot, "_walk", change), self.assertRaises(probe.Rejected):
            with self.capture():
                self.fail("changed source accepted")
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_directory_changed_during_traversal_fails_before_snapshot_is_exposed(self):
        walk = collection._Snapshot._walk
        changed = False

        def change(snapshot, parent, name, source, archive):
            nonlocal changed
            walk(snapshot, parent, name, source, archive)
            if source == "Projects/demo/modified" and not changed:
                changed = True
                (self.source / "Projects/demo/later").write_bytes(b"late child")

        with patch.object(collection._Snapshot, "_walk", change), self.assertRaisesRegex(probe.Rejected, "directory changed"):
            with self.capture():
                self.fail("changed directory accepted")
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_nested_mount_identity_rejection_precedes_payload_read(self):
        mount = collection._mount
        source_inode = (self.source / "Projects/demo/modified").stat().st_ino

        def different(fd):
            value = mount(fd)
            return value + 1 if os.fstat(fd).st_ino == source_inode else value

        with patch.object(collection, "_mount", side_effect=different), self.assertRaisesRegex(probe.Rejected, "mount differs"):
            with self.capture():
                self.fail("crossed a nested mount")
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_snapshot_parent_inside_source_or_with_unsafe_permissions_is_rejected(self):
        for parent in (self.source, self.source / "snapshots", self.root / "unsafe"):
            if not parent.exists():
                parent.mkdir(mode=0o700)
            if parent.name == "unsafe":
                parent.chmod(0o755)
            with self.subTest(parent=parent), self.assertRaises(probe.Rejected):
                with collection.collect_fixture(self.source, self.request, self.layout, snapshot_parent=parent):
                    self.fail("unsafe snapshot location accepted")

    def test_request_cannot_change_layout_or_enable_unknown_adapter(self):
        baseline = copy.deepcopy(self.request)
        for key, value in (("layout", {}), ("schema", "unknown"), ("request_id", "bad"),
                           ("selected_adapters", ["real-browser"]), ("selected_adapters", [True]),
                           ("selected_adapters", ["fixture-ssh-bytes/1", "fixture-ssh-bytes/1"])):
            self.request = copy.deepcopy(baseline)
            self.request[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(probe.Rejected):
                with self.capture():
                    self.fail("invalid request accepted")
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_invalid_overlapping_or_unrepresentable_selection_is_rejected(self):
        for selection in ([{"source": "../escape", "archive": "notes"}],
                          [{"source": "/absolute", "archive": "notes"}],
                          [{"source": "Projects", "archive": "nested/notes"}],
                          [{"source": "Projects", "archive": ""}],
                          [{"source": "", "archive": ""}, {"source": "Projects", "archive": "projects"}],
                          [{"source": "Projects", "archive": "notes"}, {"source": ".config", "archive": "notes"}]):
            self.request["selection"] = selection
            with self.subTest(selection=selection), self.assertRaises(probe.Rejected):
                with self.capture():
                    self.fail("invalid selection accepted")

    def test_layout_revision_overlap_or_capability_mismatch_is_rejected(self):
        baseline = copy.deepcopy(self.layout)
        for damage in ("revision", "overlap", "adapter"):
            self.layout = copy.deepcopy(baseline)
            if damage == "revision":
                self.layout["policy_revision"] = "future/2"
            elif damage == "overlap":
                self.layout["stores"][0]["roots"].append(".ssh/subdirectory")
            else:
                self.layout["stores"][0]["adapter"] = "real-ssh/1"
            with self.subTest(damage=damage), self.assertRaises(probe.Rejected):
                with self.capture():
                    self.fail("invalid layout accepted")

    def test_private_report_binds_capabilities_that_change_effective_selection(self):
        self.request["selected_adapters"] = ["fixture-ssh-bytes/1"]
        with self.capture() as available:
            first = copy.deepcopy(available.report)
            self.assertIn(".ssh/id_fake", available.paths)
        with collection.collect_fixture(self.source, self.request, self.layout,
                                        snapshot_parent=self.parent) as unavailable:
            second = unavailable.report
            self.assertNotIn(".ssh/id_fake", unavailable.paths)
        self.assertEqual(first["request_sha256"], second["request_sha256"])
        self.assertEqual(first["layout_sha256"], second["layout_sha256"])
        self.assertNotEqual(first["capabilities_sha256"], second["capabilities_sha256"])

    def test_depth_limit_rejects_before_recursive_capture(self):
        self.request["selection"] = [{"source": "/".join(["dir"] * 65), "archive": "notes"}]
        with self.assertRaisesRegex(probe.Rejected, "relative path"):
            with self.capture():
                self.fail("unbounded depth accepted")
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_root_permission_change_before_capture_is_rejected_for_partial_selection(self):
        self.request["selection"] = [{"source": "Projects", "archive": "Projects"}]
        capture = collection._Snapshot.capture

        def change(snapshot):
            self.source.chmod(0o777)
            return capture(snapshot)

        try:
            with patch.object(collection._Snapshot, "capture", change), self.assertRaisesRegex(probe.Rejected, "unsafe source"):
                with self.capture():
                    self.fail("writable source root accepted")
        finally:
            self.source.chmod(0o700)
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_limits_abort_collection_and_remove_snapshot(self):
        for limit in ("MAX_TOTAL", "MAX_ENTRIES"):
            with self.subTest(limit=limit), patch.object(probe, limit, 1), self.assertRaises(probe.Rejected):
                with self.capture():
                    self.fail("limit exceeded")
            self.assertEqual(list(self.parent.iterdir()), [])

    def test_encrypted_snapshot_roundtrip_survives_source_edits_preserves_metadata_and_holdouts(self):
        age = configured_age()
        if age is None:
            self.skipTest("set verified age for encrypted roundtrip")
        ciphertext = self.root / "snapshot.age"
        target, job = self.root / "destination", self.root / "job"
        target.mkdir(mode=0o700)
        job.mkdir(mode=0o700)
        with self.capture() as snapshot:
            manifest = copy.deepcopy(snapshot.manifest)
            report = copy.deepcopy(snapshot.report)
            for name in self.ordinary:
                (self.source / name).write_bytes(b"source changed after capture")
            probe.encrypt(age, SECRET, ciphertext,
                          lambda stream: probe.write_archive(stream, manifest, snapshot.paths))
            self.assert_private(snapshot)
        with restore.verified_bundle(age, SECRET, ciphertext) as bundle:
            with restore.Restorer(bundle, target, job) as importer:
                restored = importer.apply(importer.plan())
        self.assertNotIn("conflict", {action.status for action in restored})
        for name, content in self.ordinary.items():
            self.assertEqual((target / name).read_bytes(), content)
            self.assertEqual((target / name).stat().st_mtime_ns, MTIME)
        self.assertEqual(stat.S_IMODE((target / "Projects/demo/run").stat().st_mode), 0o750)
        self.assertFalse((target / "MUST-NOT-RUN").exists())
        self.assertFalse((target / "secret-alias").exists())
        self.assertEqual((target / "readme-link").read_bytes(), self.ordinary["Projects/demo/modified"])
        self.assertEqual(report["counts"]["held-out"], 8)
        self.assertTrue(set(self.protected).isdisjoint(entry["path"] for entry in manifest["entries"]))
        self.assertNotIn(b"FAKE-SSH-SECRET", ciphertext.read_bytes())


if __name__ == "__main__":
    unittest.main()

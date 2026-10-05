"""The survey reads metadata only and agrees with what collection would export."""

import contextlib
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import uuid

from omarchy_migration import collection, survey
from omarchy_migration import contract, policy as migration_policy

DOCUMENT = json.loads(survey.POLICY_PATH.read_bytes())


class SurveyTests(unittest.TestCase):
    def setUp(self):
        if os.geteuid() == 0:
            self.skipTest("unprivileged survey")
        scratch = tempfile.TemporaryDirectory(prefix="migration-survey-test-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / "home"
        self.home.mkdir(mode=0o700)
        self.files = {
            "Documents/report.md": b"quarterly\n",
            "Projects/app/main.py": b"print('hi')\n",
            ".config/nvim/init.lua": b"vim.o.number = true\n",
            ".config/hypr/monitors.lua": b"monitor = Virtual-1\n",
            ".config/hypr/input.lua": b"input {}\n",
            ".cache/thumbnails/a.png": b"\x89PNG cache",
            ".ssh/id_ed25519": b"FAKE-SECRET",
            ".config/chromium/Default/Cookies": b"FAKE-COOKIES",
            ".local/share/omarchy/bin/tool": b"runtime\n",
        }
        for name, data in self.files.items():
            path = self.home / name
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            path.write_bytes(data)
            path.chmod(0o600)
        (self.home / "Work").symlink_to("/mnt/mac")
        (self.home / "notes-link").symlink_to("Documents/report.md")
        self.policy = migration_policy.Policy(DOCUMENT)

    def run_survey(self):
        result = survey.Survey(self.policy)
        result.run(self.home)
        return result

    def test_metadata_only_no_file_is_opened_and_protected_trees_are_not_listed(self):
        protected = [self.home / ".ssh", self.home / ".config/chromium", self.home / ".local/share/omarchy",
                     self.home / ".config/hypr/monitors.lua"]
        opened, scanned = os.open, os.scandir

        def resolve(value, dir_fd=None):
            if isinstance(value, int):
                return Path(f"/proc/self/fd/{value}").resolve()
            base = Path(f"/proc/self/fd/{dir_fd}").resolve() if dir_fd is not None else Path.cwd()
            return Path(os.path.abspath(base / value))

        def guarded_open(value, flags, *args, **kwargs):
            path = resolve(value, kwargs.get("dir_fd"))
            self.assertTrue(flags & os.O_DIRECTORY and flags & os.O_NOFOLLOW, f"non-directory open: {path}")
            self.assertEqual(flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT), 0)
            self.assertFalse(any(path == root or path.is_relative_to(root) for root in protected), str(path))
            return opened(value, flags, *args, **kwargs)

        def guarded_scan(value):
            path = resolve(value)
            self.assertFalse(any(path == root or path.is_relative_to(root) for root in protected), str(path))
            return scanned(value)

        before = {path: path.stat(follow_symlinks=False).st_atime_ns for path in self.home.rglob("*")}
        with patch.object(survey.os, "open", side_effect=guarded_open), \
                patch.object(survey.os, "scandir", side_effect=guarded_scan):
            result = self.run_survey()
        self.assertEqual(set(result.stores), {"ssh", "chromium"})
        self.assertEqual({path for path in self.home.rglob("*")}, set(before))

    def test_outcomes_follow_the_try_policy(self):
        result = self.run_survey()
        examples = {outcome: {item["path"] for item in bucket["examples"]} for outcome, bucket in result.outcomes.items()}
        self.assertEqual(examples["excluded"], {".config/hypr/monitors.lua", ".local/share/omarchy"})
        self.assertEqual(examples["transform"], {".config/hypr/input.lua"})
        self.assertEqual(examples["share-link"], {"Work"})
        self.assertEqual(examples["held-out"], {".ssh", ".config/chromium"})
        self.assertEqual(result.counts["files-and-projects"]["links"], 1)

    def test_inventory_counts_match_what_collection_would_export(self):
        result = self.run_survey()
        document = survey.inventory(result, self.home, "4.0.4", uid=1000)
        self.assertEqual(contract.validate(document), contract.INVENTORY)
        surveyed = {item["id"]: (item["files"], item["bytes"]) for item in document["categories"]}
        parent = self.root / "snapshots"
        parent.mkdir(mode=0o700)
        request = {"schema": collection.REQUEST_SCHEMA, "request_id": str(uuid.uuid4()),
                   "selection": [{"source": "", "archive": ""}], "selected_adapters": [], "selected_mounts": [], "selected_share_stores": []}
        collected = {name: [0, 0] for name in surveyed}
        with collection.collect_fixture(self.home, request, DOCUMENT, snapshot_parent=parent) as snapshot:
            for entry in snapshot.manifest["entries"]:
                if entry.get("kind") == "file":
                    collected[survey.category(entry["path"])][0] += 1
                    collected[survey.category(entry["path"])][1] += entry["bytes"]
        # input.lua has no Try block here, so collection exports it unchanged.
        self.assertEqual(surveyed, {name: tuple(value) for name, value in collected.items()})
        self.assertEqual(surveyed["caches"], (1, len(self.files[".cache/thumbnails/a.png"])))
        stores = {item["id"]: item for item in document["credential_stores"]}
        self.assertTrue(stores["ssh"]["present"] and not stores["ssh"]["adapter_available"])
        self.assertFalse(stores["gnupg"]["present"])

    def test_other_filesystems_unreadable_directories_and_special_files_are_reported(self):
        (self.home / "mnt-like").mkdir(mode=0o700)
        (self.home / "locked").mkdir(mode=0o700)
        (self.home / "locked/secret").write_bytes(b"x")
        (self.home / "locked").chmod(0o000)
        self.addCleanup((self.home / "locked").chmod, 0o700)
        os.mkfifo(self.home / "pipe")
        os.link(self.home / "Documents/report.md", self.home / "Documents/hardlink.md")
        mount = collection._mount
        inode = (self.home / "mnt-like").stat().st_ino

        def different(fd):
            value = mount(fd)
            return value + 1 if os.fstat(fd).st_ino == inode else value

        with patch.object(collection, "_mount", side_effect=different):
            result = self.run_survey()
        reasons = {item["path"]: item.get("reason") for bucket in result.outcomes.values() for item in bucket["examples"]}
        self.assertIn("mnt-like", {item["path"] for item in result.outcomes["other-filesystem"]["examples"]})
        self.assertIn("locked", {item["path"] for item in result.outcomes["unreadable"]["examples"]})
        self.assertEqual(reasons["pipe"], "special-file")
        self.assertEqual(reasons["Documents/hardlink.md"], "multiply-linked-file")

    def test_clipboard_history_is_excluded_and_large_dot_folders_are_broken_down(self):
        for name, data in {".local/state/omarchy/clipboard-images/1.png": b"x" * 5000,
                           ".local/share/mise/installs/node/bin/node": b"y" * 7000,
                           ".local/share/zoxide/db.zo": b"z" * 30}.items():
            path = self.home / name
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            path.write_bytes(data)
        result = self.run_survey()
        excluded = {item["path"] for item in result.outcomes["excluded"]["examples"]}
        self.assertTrue({".local/state/omarchy/clipboard-images", ".local/share/mise"} <= excluded)
        self.assertEqual(result.top_level[".local/share/zoxide"], 30)
        self.assertNotIn(".local/share/mise", result.top_level)
        self.assertEqual(result.top_level["Documents"], len(self.files["Documents/report.md"]))
        self.assertFalse(any(key.startswith(".cache") for key in result.top_level))

    def test_refuses_a_home_owned_by_someone_else_and_bounds_entries(self):
        with patch.object(survey.os, "geteuid", return_value=os.geteuid() + 1):
            with self.assertRaisesRegex(survey.SurveyError, "another account"):
                self.run_survey()
        with self.assertRaisesRegex(survey.SurveyError, "entries"):
            survey.Survey(self.policy, max_entries=3).run(self.home)

    def test_command_prints_a_readable_summary_and_json_inventory(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), patch.object(survey.os, "getuid", return_value=1000):
            self.assertEqual(survey.main(["--home", str(self.home), "--omarchy-version", "4.0.4"]), 0)
        text = output.getvalue()
        self.assertIn("no file contents were read", text)
        self.assertIn("~/.config/hypr/monitors.lua", text)
        self.assertIn("Credential stores found", text)
        self.assertNotIn("FAKE", text)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), patch.object(survey.os, "getuid", return_value=1000):
            self.assertEqual(survey.main(["--home", str(self.home), "--json"]), 0)
        self.assertEqual(contract.parse(output.getvalue().encode())["schema"], contract.INVENTORY)


if __name__ == "__main__":
    unittest.main()

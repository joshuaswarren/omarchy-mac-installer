#!/usr/bin/env python3
"""Tests for the release artifact mirror, over an in-memory bucket and canned
GitHub and CDN answers: nothing leaves the machine."""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import sys
import unittest
import unittest.mock
import urllib.error
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mirror_release_artifact", SCRIPTS / "mirror_release_artifact.py")
mirror = importlib.util.module_from_spec(spec)
sys.modules["mirror_release_artifact"] = mirror
spec.loader.exec_module(mirror)

DATA = b"engine archive bytes"
SHA = hashlib.sha256(DATA).hexdigest()
REPO = "omacom/omarchy-mac-installer"


def artifact() -> mirror.Artifact:
    return mirror.Artifact(tag="engine-v1", file_name="installer-v1.tar.gz", size=len(DATA), sha256=SHA,
                           key=f"{mirror.base_prefix()}engine/v1/installer-v1.tar.gz", content_type="application/gzip")


class FakeEndpoint:
    bucket = "omarchy-mac"

    def __init__(self, store: dict):
        self.store = store
        self.puts: list[str] = []
        self.race: bytes | None = None

    def request(self, method, key, *, headers=None, body=None, size=0, payload_sha256=None, timeout=600, query=None):
        if method == "GET":
            if key not in self.store:
                raise urllib.error.HTTPError(key, 404, "Not Found", None, io.BytesIO(b""))
            return io.BytesIO(self.store[key])
        if method == "PUT":
            self.puts.append(key)
            if self.race is not None:
                self.store[key] = self.race
                raise urllib.error.HTTPError(key, 412, "Precondition Failed", None, io.BytesIO(b""))
            assert headers["If-None-Match"] == "*" and headers["Cache-Control"] == mirror.IMMUTABLE
            data = body.read()
            assert len(data) == size and hashlib.sha256(data).hexdigest() == payload_sha256
            self.store[key] = data
            return io.BytesIO(b"")
        raise AssertionError(f"unexpected {method}")


class MirrorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.release = {"tag_name": "engine-v1", "draft": False, "assets": [
            {"name": "installer-v1.tar.gz", "state": "uploaded", "size": len(DATA), "digest": f"sha256:{SHA}",
             "browser_download_url": "https://github.com/x/releases/download/engine-v1/installer-v1.tar.gz"}]}
        self.store: dict[str, bytes] = {}
        self.served = self.store
        self.downloaded = DATA
        original = mirror.urllib.request.urlopen
        mirror.urllib.request.urlopen = self.urlopen
        self.addCleanup(setattr, mirror.urllib.request, "urlopen", original)
        sleep, mirror.time.sleep = mirror.time.sleep, lambda seconds: None
        self.addCleanup(setattr, mirror.time, "sleep", sleep)

    def urlopen(self, request, timeout=None):
        url = request.full_url
        if url.startswith("https://api.github.com/"):
            if self.release is None:
                raise urllib.error.HTTPError(url, 404, "Not Found", None, io.BytesIO(b""))
            return io.BytesIO(json.dumps(self.release).encode())
        if url.startswith("https://github.com/"):
            return io.BytesIO(self.downloaded)
        key = mirror.base_prefix() + url.removeprefix(mirror.catalog_release.identity()["INSTALLER_CATALOG_BASE"].rstrip("/") + "/")
        if key not in self.served:
            raise urllib.error.HTTPError(url, 404, "Not Found", None, io.BytesIO(b""))
        return io.BytesIO(self.served[key])

    def run_mirror(self, endpoint=None):
        endpoint = endpoint or FakeEndpoint(self.store)
        with unittest.mock.patch("sys.stdout", io.StringIO()), unittest.mock.patch("sys.stderr", io.StringIO()):
            return mirror.mirror(artifact(), endpoint, REPO, "token"), endpoint

    def test_a_published_matching_engine_lands_once_under_the_catalog_base(self) -> None:
        url, endpoint = self.run_mirror()
        self.assertEqual(self.store[artifact().key], DATA)
        self.assertEqual(url, mirror.catalog_release.identity()["INSTALLER_CATALOG_BASE"] + "/engine/v1/installer-v1.tar.gz")
        self.assertTrue(artifact().key.startswith(mirror.base_prefix() + "engine/"))
        self.assertTrue(url.startswith(tuple(mirror.catalog_release.artifact_bases())), "catalogs may pin it")
        _, again = self.run_mirror()
        self.assertEqual(again.puts, [], "a re-run writes nothing")

    def test_a_draft_or_missing_release_is_refused_before_any_write(self) -> None:
        self.release["draft"] = True
        with self.assertRaisesRegex(mirror.Refusal, "not a published release"):
            self.run_mirror()
        self.release = None
        with self.assertRaisesRegex(mirror.Refusal, "no published engine-v1 release"):
            self.run_mirror()
        self.assertEqual(self.store, {})

    def test_an_asset_unlike_the_lock_is_refused(self) -> None:
        good = dict(self.release["assets"][0])
        for change, reason in (({"digest": "sha256:" + "0" * 64}, "has digest"), ({"size": 1}, "is 1 bytes"),
                               ({"state": "starter"}, "incomplete upload"), ({"digest": None}, "has digest None")):
            with self.subTest(reason):
                self.release["assets"][0] = {**good, **change}
                with self.assertRaisesRegex(mirror.Refusal, reason):
                    self.run_mirror()
                self.assertEqual(self.store, {})

    def test_downloaded_bytes_unlike_the_digest_are_refused(self) -> None:
        self.downloaded = b"something else"
        with self.assertRaisesRegex(mirror.Refusal, "downloaded as"):
            self.run_mirror()
        self.assertEqual(self.store, {})

    def test_other_bytes_already_stored_are_never_replaced(self) -> None:
        self.store[artifact().key] = b"older bytes"
        with self.assertRaisesRegex(mirror.Refusal, "already holds other bytes"):
            self.run_mirror()
        self.assertEqual(self.store[artifact().key], b"older bytes")

    def test_a_concurrent_write_is_read_back_after_the_412(self) -> None:
        endpoint = FakeEndpoint(self.store)
        endpoint.race = DATA
        self.run_mirror(endpoint)
        endpoint = FakeEndpoint({})
        endpoint.race = b"other"
        with self.assertRaisesRegex(mirror.Refusal, "already holds other bytes"):
            self.run_mirror(endpoint)

    def test_a_cached_404_is_waited_out_and_a_rerun_writes_nothing(self) -> None:
        answers = iter([urllib.error.HTTPError("u", 404, "Not Found", None, io.BytesIO(b""))] * 7)
        serve = self.urlopen

        def cached_404_first(request, timeout=None):
            if request.full_url.startswith(mirror.catalog_release.identity()["INSTALLER_CATALOG_BASE"]):
                failure = next(answers, None)
                if failure is not None:
                    raise failure
            return serve(request, timeout)
        mirror.urllib.request.urlopen = cached_404_first
        _, endpoint = self.run_mirror()
        self.assertEqual(endpoint.puts, [artifact().key])
        self.assertGreaterEqual(sum(mirror.PUBLIC_DELAYS), 240, "Cloudflare keeps a 404 for up to three minutes")
        mirror.urllib.request.urlopen = serve
        _, again = self.run_mirror()
        self.assertEqual(again.puts, [])

    def test_a_file_stored_but_not_served_fails(self) -> None:
        self.served = {}
        with self.assertRaisesRegex(mirror.Refusal, "does not serve installer-v1.tar.gz"):
            self.run_mirror()

    def test_the_engine_is_the_locks(self) -> None:
        lock = json.loads(mirror.catalog_release.SOURCE_LOCK.read_text())
        engine = mirror.pinned_engine()
        self.assertEqual((engine.tag, engine.file_name, engine.size, engine.sha256),
                         (f"engine-{lock['downstream_overlay']['version']}", lock["validation_artifact"]["filename"],
                          lock["validation_artifact"]["size_bytes"], lock["validation_artifact"]["sha256"]))
        self.assertEqual(engine.key, f"{mirror.base_prefix()}engine/{lock['downstream_overlay']['version']}/{engine.file_name}")



class AppMirrorTests(unittest.TestCase):
    STEM = mirror.catalog_release.identity()["INSTALLER_FILE_STEM"]
    DMG = b"notarized disk image"

    def setUp(self) -> None:
        self.dmg = f"{self.STEM}-2.4.0.dmg"
        self.files = {self.dmg: self.DMG,
                      f"{self.dmg}.sha256": f"{hashlib.sha256(self.DMG).hexdigest()}  {self.dmg}\n".encode()}
        self.release = {"tag_name": "v2.4.0", "draft": False, "prerelease": True, "assets": [
            {"name": name, "state": "uploaded", "size": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
             "browser_download_url": f"https://github.com/x/releases/download/v2.4.0/{name}"}
            for name, data in self.files.items()]}
        self.store: dict[str, bytes] = {}
        original = mirror.urllib.request.urlopen
        mirror.urllib.request.urlopen = self.urlopen
        self.addCleanup(setattr, mirror.urllib.request, "urlopen", original)
        sleep, mirror.time.sleep = mirror.time.sleep, lambda seconds: None
        self.addCleanup(setattr, mirror.time, "sleep", sleep)

    def urlopen(self, request, timeout=None):
        url = request.full_url
        if url.startswith("https://api.github.com/"):
            return io.BytesIO(json.dumps(self.release).encode())
        if url.startswith("https://github.com/"):
            return io.BytesIO(self.files[url.rsplit("/", 1)[1]])
        base = mirror.catalog_release.identity()["INSTALLER_CATALOG_BASE"].rstrip("/") + "/"
        return io.BytesIO(self.store[mirror.base_prefix() + url.removeprefix(base)])

    def run_app(self):
        endpoint = FakeEndpoint(self.store)
        with unittest.mock.patch("sys.stdout", io.StringIO()), unittest.mock.patch("sys.stderr", io.StringIO()):
            for item in mirror.published_app("2.4.0", REPO, "token"):
                mirror.mirror(item, endpoint, REPO, "token")
        return endpoint

    def test_the_dmg_then_its_sidecar_land_under_the_installer_path(self) -> None:
        endpoint = self.run_app()
        prefix = f"{mirror.base_prefix()}installer/2.4.0/"
        self.assertEqual(endpoint.puts, [prefix + self.dmg, prefix + self.dmg + ".sha256"])
        self.assertEqual(self.store[prefix + self.dmg], self.DMG)
        url = mirror.public_url(prefix + self.dmg)
        self.assertTrue(url.startswith(tuple(mirror.catalog_release.installer_bases())), "catalogs may name it")

    def test_a_sidecar_naming_another_digest_or_file_or_malformed_is_refused(self) -> None:
        digest = hashlib.sha256(self.DMG).hexdigest()
        for line in (f"{'0' * 64}  {self.dmg}\n", f"{digest}  other.dmg\n", f"{digest} {self.dmg}\n",
                     f"{digest}\n{self.dmg}\n", f"{digest}  {self.dmg}\n\n", f"{digest}  *{self.dmg}\n"):
            with self.subTest(line):
                self.files[f"{self.dmg}.sha256"] = line.encode()
                self.release["assets"][1].update(size=len(line), digest="sha256:" + hashlib.sha256(line.encode()).hexdigest())
                with self.assertRaisesRegex(mirror.Refusal, "does not read"):
                    self.run_app()
                self.assertEqual(self.store, {})

    def test_an_asset_without_a_github_digest_is_refused(self) -> None:
        self.release["assets"][0]["digest"] = None
        with self.assertRaisesRegex(mirror.Refusal, "has no GitHub digest"):
            self.run_app()

    def test_a_draft_release_or_a_bad_version_is_refused(self) -> None:
        with self.assertRaisesRegex(mirror.Refusal, "X.Y.Z"):
            mirror.published_app("2.4.0-beta", REPO, "token")
        self.release["draft"] = True
        with self.assertRaisesRegex(mirror.Refusal, "not a published release"):
            self.run_app()
        self.assertEqual(self.store, {})

    def test_a_sidecar_without_a_final_newline_is_accepted(self) -> None:
        line = f"{hashlib.sha256(self.DMG).hexdigest()}  {self.dmg}".encode()
        self.files[f"{self.dmg}.sha256"] = line
        self.release["assets"][1].update(size=len(line), digest="sha256:" + hashlib.sha256(line).hexdigest())
        self.run_app()

    def run_main(self, endpoint):
        environment = {"GH_TOKEN": "token", "R2_ENDPOINT": "https://a.r2.cloudflarestorage.com",
                       "R2_ACCESS_KEY_ID": "id", "R2_SECRET_ACCESS_KEY": "secret",
                       # A fork's Actions env names the fork; the publish guard must see its own repo.
                       "GITHUB_REPOSITORY": mirror.catalog_release.stopgap_repo()}
        with unittest.mock.patch.dict("os.environ", environment), \
                unittest.mock.patch.object(mirror.r2_s3.Endpoint, "parse", return_value=endpoint), \
                unittest.mock.patch("sys.stdout", io.StringIO()), unittest.mock.patch("sys.stderr", io.StringIO()):
            return mirror.main(["app", "2.4.0"])

    def test_a_dmg_that_is_not_served_publishes_no_sidecar_and_a_retry_resumes(self) -> None:
        endpoint = FakeEndpoint(self.store)
        serve = self.urlopen
        prefix = f"{mirror.base_prefix()}installer/2.4.0/"

        def dmg_not_served(request, timeout=None):
            if request.full_url == mirror.public_url(prefix + self.dmg):
                raise urllib.error.HTTPError(request.full_url, 404, "Not Found", None, io.BytesIO(b""))
            return serve(request, timeout)
        mirror.urllib.request.urlopen = dmg_not_served
        self.assertEqual(self.run_main(endpoint), 1)
        self.assertEqual(sorted(self.store), [prefix + self.dmg], "no sidecar before the dmg is served")
        mirror.urllib.request.urlopen = serve
        again = FakeEndpoint(self.store)
        self.assertEqual(self.run_main(again), 0)
        self.assertEqual(again.puts, [prefix + self.dmg + ".sha256"], "the stored dmg is not written again")

    def test_the_command_line_takes_engine_or_app_version(self) -> None:
        with unittest.mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(mirror.main([]), 64)
            self.assertEqual(mirror.main(["app"]), 64)
            self.assertEqual(mirror.main(["dmg", "2.4.0"]), 64)


if __name__ == "__main__":
    unittest.main()

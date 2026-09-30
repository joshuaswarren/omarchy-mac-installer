"""Credential-aware snapshots of caller-owned disposable fixture trees.

No home CLI or production adapter. Sources must be quiescent; change detection
does not establish an atomic application/database snapshot.
"""

import contextlib
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import uuid

from . import probe


REQUEST_SCHEMA = "omarchy-migration-collection-request/1"
LAYOUT_SCHEMA = "omarchy-migration-fixture-layout/1"
REPORT_SCHEMA = "omarchy-migration-collection-report/1"
POLICY = "fixture-holdouts/1"
MAX_DEPTH = 64
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK


def _json_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def _path(value, *, empty=False):
    try:
        if (type(value) is not str or (not value and not empty) or "\0" in value
                or len(value.encode("utf-8")) > 4096
                or value.count("/") >= MAX_DEPTH
                or (value and any(part in ("", ".", "..") or len(part.encode("utf-8")) > 255
                                  for part in value.split("/")))):
            raise probe.Rejected("invalid collection relative path")
    except UnicodeError as error:
        raise probe.Rejected("invalid collection path encoding") from error
    return value


def _beneath(path, root):
    return not root or path == root or path.startswith(root + "/")


def _label(value):
    return type(value) is str and 0 < len(value) <= 128 and all(
        char.isascii() and (char.isalnum() or char in "-_/.") for char in value
    )


def _contracts(request, layout, supported):
    if (not isinstance(request, dict) or set(request) != {"schema", "request_id", "selection", "selected_adapters"}
            or request["schema"] != REQUEST_SCHEMA):
        raise probe.Rejected("collection request fields/schema")
    try:
        if type(request["request_id"]) is not str or str(uuid.UUID(request["request_id"])) != request["request_id"]:
            raise ValueError()
    except ValueError as error:
        raise probe.Rejected("collection request identity") from error
    selection = request["selection"]
    if not isinstance(selection, list) or not 1 <= len(selection) <= 32:
        raise probe.Rejected("collection selections")
    for item in selection:
        if not isinstance(item, dict) or set(item) != {"source", "archive"}:
            raise probe.Rejected("collection selection fields")
        _path(item["source"], empty=True)
        _path(item["archive"], empty=True)
        # This slice remaps whole roots, without inventing ancestor metadata.
        if (not item["archive"] and item["source"]) or "/" in item["archive"]:
            raise probe.Rejected("collection archive root requires one component")
    for index, item in enumerate(selection):
        for previous in selection[:index]:
            if any(_beneath(item[key], previous[key]) or _beneath(previous[key], item[key])
                   for key in ("source", "archive")):
                raise probe.Rejected("overlapping collection selections")
    if (not isinstance(layout, dict) or set(layout) != {"schema", "policy_revision", "layout_id", "stores"}
            or layout["schema"] != LAYOUT_SCHEMA or layout["policy_revision"] != POLICY
            or not _label(layout["layout_id"]) or not isinstance(layout["stores"], list)
            or not 1 <= len(layout["stores"]) <= 32):
        raise probe.Rejected("trusted fixture layout fields/schema")
    stores, roots, adapters = set(), [], set()
    for store in layout["stores"]:
        if (not isinstance(store, dict) or set(store) != {"id", "roots", "adapter"}
                or not _label(store["id"]) or store["id"] in stores
                or not isinstance(store["roots"], list) or not 1 <= len(store["roots"]) <= 32):
            raise probe.Rejected("trusted fixture store fields")
        stores.add(store["id"])
        adapter = store["adapter"]
        if adapter is not None:
            if not _label(adapter) or not adapter.startswith("fixture-") or adapter in adapters:
                raise probe.Rejected("fixture adapter identity")
            adapters.add(adapter)
        for root in store["roots"]:
            _path(root)
            if any(_beneath(root, previous) or _beneath(previous, root) for previous in roots):
                raise probe.Rejected("overlapping fixture store roots")
            roots.append(root)
    chosen = request["selected_adapters"]
    if (not isinstance(chosen, list) or any(type(value) is not str for value in chosen)
            or len(set(chosen)) != len(chosen) or not set(chosen) <= adapters
            or not isinstance(supported, (tuple, list, set, frozenset))
            or any(type(value) is not str for value in supported) or not set(supported) <= adapters):
        raise probe.Rejected("fixture adapter selection/capability")
    for contract in (request, layout):
        if len(_json_bytes(contract)) > probe.MAX_MANIFEST:
            raise probe.Rejected("collection contract size")


def _metadata(value):
    return tuple(getattr(value, key) for key in (
        "st_dev", "st_ino", "st_mode", "st_uid", "st_gid", "st_size",
        "st_mtime_ns", "st_ctime_ns", "st_nlink",
    ))


def _mount(fd):
    # st_dev alone cannot detect bind mounts of the same filesystem.
    with open(f"/proc/self/fdinfo/{fd}", encoding="ascii") as info:
        for line in info:
            if line.startswith("mnt_id:"):
                return int(line.split(":", 1)[1])
    raise probe.Rejected("source mount identity unavailable")


class _Snapshot:
    def __init__(self, root_fd, root, directory, request, layout, supported):
        self.root_fd, self.root, self.directory = root_fd, root, directory
        self.request, self.layout = request, layout
        self.supported = frozenset(supported)
        self.mount = _mount(root_fd)
        self.paths, self.metadata, self.history = {}, {}, {}
        self.items, self.total = [], 0
        self.report = None
        self.manifest = None

    def _guard(self, fd):
        metadata = os.fstat(fd)
        if _mount(fd) != self.mount or metadata.st_uid != os.geteuid():
            raise probe.Rejected("source owner or mount differs")
        if stat.S_ISDIR(metadata.st_mode) and metadata.st_mode & 0o022:
            raise probe.Rejected("unsafe source directory")

    def _store(self, path):
        for store in self.layout["stores"]:
            if any(_beneath(path, root) for root in store["roots"]):
                adapter = store["adapter"]
                if adapter is None or adapter not in self.supported:
                    return store["id"], "adapter-unavailable"
                if adapter not in self.request["selected_adapters"]:
                    return store["id"], "unselected-store"
        return None

    def _report(self, source, archive, outcome, reason, store=None):
        if len(self.items) >= probe.MAX_ENTRIES:
            raise probe.Rejected("collection item limit")
        self.items.append({"source": source, "archive": archive, "outcome": outcome,
                           "reason": reason, "store": store})

    @contextlib.contextmanager
    def _parent(self, path):
        fd = os.dup(self.root_fd)
        prefix = []
        try:
            for part in path.split("/")[:-1]:
                prefix.append(part)
                child = os.open(part, DIRECTORY_FLAGS, dir_fd=fd)
                os.close(fd)
                fd = child
                self._guard(fd)
                metadata = os.fstat(fd)
                if metadata.st_mode & 0o022:
                    raise probe.Rejected("unsafe source ancestor")
                self.history.setdefault("/".join(prefix), _metadata(metadata))
            yield fd
        finally:
            os.close(fd)

    def _names(self, fd):
        names = []
        with os.scandir(fd) as entries:
            for entry in entries:
                _path(entry.name)
                names.append(entry.name)
                if len(names) > probe.MAX_ENTRIES:
                    raise probe.Rejected("source directory item limit")
        return sorted(names)

    def _directory(self, fd, source, archive, metadata):
        self._guard(fd)
        if metadata.st_mode & 0o022:
            raise probe.Rejected("unsafe source directory")
        names = self._names(fd)
        self.history[source] = _metadata(metadata)
        for name in names:
            self._walk(fd, name, f"{source}/{name}" if source else name,
                       f"{archive}/{name}" if archive else name)
        if _metadata(os.fstat(fd)) != _metadata(metadata) or self._names(fd) != names:
            raise probe.Rejected("source directory changed during capture")

    def _walk(self, parent, name, source, archive):
        _path(source)
        _path(archive)
        excluded = self._store(source)
        if excluded:
            self._report(source, archive, "held-out", excluded[1], excluded[0])
            return
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if before.st_uid != os.geteuid():
            raise probe.Rejected("source entry owner differs")
        destination = self.directory / str(len(self.paths))
        if stat.S_ISDIR(before.st_mode):
            fd = os.open(name, DIRECTORY_FLAGS, dir_fd=parent)
            try:
                if _metadata(os.fstat(fd)) != _metadata(before):
                    raise probe.Rejected("source directory replaced")
                destination.mkdir(mode=0o700)
                self.paths[archive], self.metadata[archive] = destination, before
                self._report(source, archive, "included", "directory")
                self._directory(fd, source, archive, before)
            finally:
                os.close(fd)
        elif stat.S_ISREG(before.st_mode):
            if before.st_nlink != 1 or not before.st_mode & 0o400:
                self._report(source, archive, "unsupported",
                             "multiply-linked-file" if before.st_nlink != 1 else "unreadable-owner-file")
                return
            if before.st_size > probe.MAX_TOTAL - self.total:
                raise probe.Rejected("collection byte limit")
            fd = os.open(name, FILE_FLAGS, dir_fd=parent)
            with os.fdopen(fd, "rb") as source_file:
                self._guard(fd)
                if _metadata(os.fstat(fd)) != _metadata(before):
                    raise probe.Rejected("source file replaced before capture")
                count = 0
                output_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(output_fd, "wb") as output:
                    while piece := source_file.read(min(probe.CHUNK, before.st_size - count + 1)):
                        count += len(piece)
                        if count > before.st_size:
                            raise probe.Rejected("source file grew during capture")
                        output.write(piece)
                if count != before.st_size or _metadata(os.fstat(fd)) != _metadata(before):
                    raise probe.Rejected("source file changed during capture")
            self.total += count
            self.paths[archive], self.metadata[archive] = destination, before
            self._report(source, archive, "included", "regular-file")
        elif stat.S_ISLNK(before.st_mode):
            if any(item["source"] != item["archive"] for item in self.request["selection"]):
                # V2 has no explicit inert-link flag. A renamed selection
                # could make an old target accidentally refer to new data.
                self._report(source, archive, "unsupported", "remapped-link")
                return
            target = os.readlink(name, dir_fd=parent)
            if not target or "\0" in target or len(target.encode("utf-8")) > 4096:
                raise probe.Rejected("source link target limit")
            destination.symlink_to(target)
            self.paths[archive], self.metadata[archive] = destination, before
            self._report(source, archive, "included", "link-metadata")
        else:
            self._report(source, archive, "unsupported", "special-file")
            return
        after = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if _metadata(after) != _metadata(before):
            raise probe.Rejected("source entry changed during capture")
        self.history[source] = _metadata(before)

    def capture(self):
        self._guard(self.root_fd)
        root_metadata = os.fstat(self.root_fd)
        self.history[""] = _metadata(root_metadata)
        for selection in self.request["selection"]:
            source, archive = selection["source"], selection["archive"]
            excluded = self._store(source)
            if excluded:
                self._report(source, archive, "held-out", excluded[1], excluded[0])
            elif source:
                with self._parent(source) as parent:
                    self._walk(parent, source.split("/")[-1], source, archive)
            elif not archive:
                self._directory(self.root_fd, "", "", root_metadata)
            else:
                destination = self.directory / str(len(self.paths))
                destination.mkdir(mode=0o700)
                self.paths[archive], self.metadata[archive] = destination, root_metadata
                self._report("", archive, "included", "directory")
                self._directory(self.root_fd, "", archive, root_metadata)
        # Reopen through the pinned root without following aliases. Metadata
        # checks detect changes but cannot prove a single atomic cutover.
        for source, expected in self.history.items():
            if source:
                with self._parent(source) as parent:
                    actual = os.stat(source.split("/")[-1], dir_fd=parent, follow_symlinks=False)
            else:
                actual = os.fstat(self.root_fd)
            if _metadata(actual) != expected:
                raise probe.Rejected("source changed before snapshot completion")
        reopened = os.open(self.root, DIRECTORY_FLAGS)
        try:
            if _metadata(os.fstat(reopened)) != _metadata(root_metadata):
                raise probe.Rejected("source root changed before completion")
        finally:
            os.close(reopened)
        self.manifest = probe.make_tree_manifest(self.paths)
        by_path = {entry["path"]: entry for entry in self.manifest["entries"]}
        for entry in self.manifest["entries"]:
            metadata = self.metadata[entry["path"]]
            entry["mtime_ns"] = metadata.st_mtime_ns
            if probe.entry_kind(entry) != "symlink":
                entry["mode"] = stat.S_IMODE(metadata.st_mode) & 0o777
        probe.validate_manifest(self.manifest)
        for item in self.items:
            entry = by_path.get(item["archive"])
            if item["reason"] == "link-metadata" and probe.link_target(entry, by_path) is None:
                item.update(outcome="inert-link", reason="target-unavailable")
        outcomes = ("included", "held-out", "unsupported", "inert-link")
        self.report = {
            "schema": REPORT_SCHEMA, "request_id": self.request["request_id"],
            "request_sha256": hashlib.sha256(_json_bytes(self.request)).hexdigest(),
            "layout_sha256": hashlib.sha256(_json_bytes(self.layout)).hexdigest(),
            "supported_adapters": sorted(self.supported),
            "capabilities_sha256": hashlib.sha256(_json_bytes(sorted(self.supported))).hexdigest(),
            "policy_revision": POLICY, "status": "complete",
            "entries": self.items, "counts": {outcome: sum(item["outcome"] == outcome for item in self.items)
                                               for outcome in outcomes},
        }


@contextlib.contextmanager
def collect_fixture(root, request, layout, *, supported_adapters=(), snapshot_parent):
    """Capture only an explicitly supplied, caller-created synthetic source."""
    _contracts(request, layout, supported_adapters)
    request, layout = json.loads(_json_bytes(request)), json.loads(_json_bytes(layout))
    if os.geteuid() == 0:
        raise probe.Rejected("fixture collection requires an unprivileged owner")
    root, parent = Path(root).absolute(), Path(snapshot_parent).absolute()
    root_fd = os.open(root, DIRECTORY_FLAGS)
    try:
        metadata = os.fstat(root_fd)
        if metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022:
            raise probe.Rejected("unsafe fixture root")
        parent_fd = os.open(parent, DIRECTORY_FLAGS)
        try:
            parent_metadata = os.fstat(parent_fd)
            if parent_metadata.st_uid != os.geteuid() or stat.S_IMODE(parent_metadata.st_mode) != 0o700:
                raise probe.Rejected("snapshot parent must be private and owned")
            if parent.resolve().is_relative_to(root.resolve()):
                raise probe.Rejected("snapshot parent must be outside source")
            with tempfile.TemporaryDirectory(prefix="migration-collected-", dir=parent) as temporary:
                directory = Path(temporary)
                if directory.resolve().is_relative_to(root.resolve()) or root.resolve().is_relative_to(directory.resolve()):
                    raise probe.Rejected("snapshot and source must be separate")
                snapshot = _Snapshot(root_fd, root, directory, request, layout, supported_adapters)
                snapshot.capture()
                yield snapshot
        finally:
            os.close(parent_fd)
    finally:
        os.close(root_fd)

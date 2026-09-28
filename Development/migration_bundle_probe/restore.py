"""Synthetic, additive restoration experiment; never a real-home CLI.

Authenticate once into private scratch, then plan/apply against a caller-owned
disposable destination. Existing differing files are conflicts, never replaced.
"""

import contextlib
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import uuid

from . import probe


JOURNAL_SCHEMA = "omarchy-migration-restore-probe/1"
JOURNAL_LIMIT = 4 * 1024 * 1024
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK


def _json_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


@dataclass(frozen=True)
class Action:
    path: str
    status: str
    reason: str


class _VerifiedBundle:
    def __init__(self, manifest, directory):
        self._manifest = manifest
        self._directory = directory
        self._active = True
        self._digest = hashlib.sha256(_json_bytes(manifest)).hexdigest()

    def _check(self):
        if not self._active:
            raise probe.Rejected("verified bundle has been closed")


@contextlib.contextmanager
def verified_bundle(age, secret, ciphertext):
    """Yield only after complete authentication; remove plaintext on every exit."""
    with tempfile.TemporaryDirectory(prefix="migration-verified-") as directory:
        root = Path(directory)

        @contextlib.contextmanager
        def objects(entry):
            # Only the validated numbered object ID is used for scratch names.
            fd = os.open(root / entry["object"].split("/")[1],
                         os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as output:
                yield output

        manifest = probe._decode(
            age, secret, ciphertext,
            probe.MAX_TOTAL + probe.MAX_MANIFEST + 2 * 1024 * 1024,
            objects=objects,
        )
        bundle = _VerifiedBundle(manifest, root)
        try:
            yield bundle
        finally:
            bundle._active = False


def _directory(path):
    fd = os.open(path, DIRECTORY_FLAGS)
    try:
        metadata = os.fstat(fd)
        if metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022:
            raise probe.Rejected("directory must be owned by caller and not writable by others")
        return fd
    except BaseException:
        os.close(fd)
        raise


def _identity(fd):
    metadata = os.fstat(fd)
    return {"device": metadata.st_dev, "inode": metadata.st_ino, "uid": metadata.st_uid}


def _metadata(metadata):
    return {
        "device": metadata.st_dev, "inode": metadata.st_ino,
        "uid": metadata.st_uid, "gid": metadata.st_gid,
        "bytes": metadata.st_size, "mode": stat.S_IMODE(metadata.st_mode),
        "mtime_ns": metadata.st_mtime_ns,
    }


def _fingerprint(fd):
    before = os.fstat(fd)
    if not stat.S_ISREG(before.st_mode) or before.st_size > probe.MAX_TOTAL:
        raise probe.Rejected("unsupported destination file")
    checksum = hashlib.sha256()
    count = 0
    while piece := os.read(fd, probe.CHUNK):
        count += len(piece)
        if count > probe.MAX_TOTAL:
            raise probe.Rejected("destination file exceeds probe limit")
        checksum.update(piece)
    after = os.fstat(fd)
    if _metadata(before) != _metadata(after) or before.st_ctime_ns != after.st_ctime_ns:
        raise probe.Rejected("destination changed while reading")
    return {**_metadata(after), "sha256": checksum.hexdigest()}


def _matches(entry, observed):
    return observed is not None and all(
        observed.get(key) == entry[key] for key in ("bytes", "mode", "mtime_ns", "sha256")
    )


class Restorer:
    """One locked job, one authenticated bundle, one pinned disposable target.

    The caller creates an empty 0700 job directory outside the destination on
    the same filesystem. plan() writes nothing in the target; apply(plan)
    accepts only this session's latest plan. No ownership or paths come from
    the archive except validated relative file names.
    """

    def __init__(self, bundle, target, job):
        bundle._check()
        if os.geteuid() == 0:
            raise probe.Rejected("run this experiment as an unprivileged owner")
        self.bundle = bundle
        self.target = Path(target).absolute()
        self.job = Path(job).absolute()
        self._stack = contextlib.ExitStack()
        self._plan = None
        self._closed = False
        self._created_parents = {}
        try:
            # Caller paths are trusted, but the final component must not be a
            # symlink. Resolve parents only for containment checks.
            self._target_fd = _directory(self.target)
            self._stack.callback(os.close, self._target_fd)
            self._job_fd = _directory(self.job)
            self._stack.callback(os.close, self._job_fd)
            resolved_target, resolved_job = self.target.resolve(), self.job.resolve()
            if resolved_target.is_relative_to(resolved_job) or resolved_job.is_relative_to(resolved_target):
                raise probe.Rejected("job and target must be separate trees")
            if stat.S_IMODE(os.fstat(self._job_fd).st_mode) != 0o700:
                raise probe.Rejected("job directory must have mode 0700")
            if os.fstat(self._target_fd).st_dev != os.fstat(self._job_fd).st_dev:
                raise probe.Rejected("job and target must share a filesystem")
            try:
                fcntl.flock(self._job_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise probe.Rejected("restore job is already active") from error
            self._binding = {
                "schema": JOURNAL_SCHEMA,
                "manifest_sha256": bundle._digest,
                "export_id": bundle._manifest["export_id"],
                "target": _identity(self._target_fd),
                "job": _identity(self._job_fd),
            }
            self._journal = self._load()
        except BaseException:
            self._stack.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self._closed = True
        self._stack.close()

    def _check(self):
        self.bundle._check()
        if self._closed:
            raise probe.Rejected("restore job is closed")
        for path, expected in ((self.target, self._binding["target"]), (self.job, self._binding["job"])):
            fd = _directory(path)
            try:
                if _identity(fd) != expected:
                    raise probe.Rejected("restore directory identity changed")
            finally:
                os.close(fd)
        if stat.S_IMODE(os.fstat(self._job_fd).st_mode) != 0o700:
            raise probe.Rejected("job directory must remain private")

    def _load(self):
        try:
            fd = os.open("journal.json", FILE_FLAGS, dir_fd=self._job_fd)
        except FileNotFoundError:
            if os.listdir(self._job_fd):
                raise probe.Rejected("unrecognized nonempty restore job")
            return {**self._binding, "entries": {}}
        with os.fdopen(fd, "rb") as source:
            metadata = os.fstat(fd)
            if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                    or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_nlink != 1):
                raise probe.Rejected("unsafe restore journal")
            raw = source.read(JOURNAL_LIMIT + 1)
        if len(raw) > JOURNAL_LIMIT:
            raise probe.Rejected("restore journal size")
        try:
            journal = json.loads(raw, object_pairs_hook=probe.unique_json_pairs)
        except (ValueError, UnicodeError) as error:
            raise probe.Rejected("invalid restore journal") from error
        if (not isinstance(journal, dict) or set(journal) != {*self._binding, "entries"}
                or any(journal[key] != value for key, value in self._binding.items())):
            raise probe.Rejected("restore journal binding differs")
        entries = journal["entries"]
        allowed = {entry["object"] for entry in self.bundle._manifest["entries"]}
        if not isinstance(entries, dict) or not set(entries) <= allowed:
            raise probe.Rejected("restore journal entries")
        fingerprint_keys = {"device", "inode", "uid", "gid", "bytes", "mode", "mtime_ns", "sha256"}
        for entry in entries.values():
            if (not isinstance(entry, dict) or set(entry) != {"state", "file", "temporary"}
                    or entry["state"] not in ("pending", "applied")
                    or not isinstance(entry["file"], dict) or set(entry["file"]) != fingerprint_keys):
                raise probe.Rejected("restore journal entry")
            temporary = entry["temporary"]
            try:
                if not isinstance(temporary, str) or str(uuid.UUID(temporary)) != temporary:
                    raise ValueError()
            except ValueError as error:
                raise probe.Rejected("restore journal temporary identity") from error
            expected = entry["file"]
            if any(type(expected[key]) is not int or expected[key] < 0
                   for key in fingerprint_keys - {"sha256"}):
                raise probe.Rejected("restore journal metadata")
            if (not isinstance(expected["sha256"], str) or len(expected["sha256"]) != 64
                    or any(c not in "0123456789abcdef" for c in expected["sha256"])):
                raise probe.Rejected("restore journal digest")
        return journal

    def _save(self):
        temporary = f".journal-{uuid.uuid4()}"
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=self._job_fd)
        try:
            with os.fdopen(fd, "wb") as output:
                output.write(_json_bytes(self._journal))
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, "journal.json", src_dir_fd=self._job_fd, dst_dir_fd=self._job_fd)
            os.fsync(self._job_fd)
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary, dir_fd=self._job_fd)

    @contextlib.contextmanager
    def _parent(self, path, *, create=False, identities=None):
        fd = os.dup(self._target_fd)
        components = []
        try:
            for part in path.split("/")[:-1]:
                components.append(part)
                created = False
                if create:
                    try:
                        os.mkdir(part, 0o700, dir_fd=fd)
                    except FileExistsError:
                        pass
                    else:
                        os.fsync(fd)
                        created = True
                try:
                    child = os.open(part, DIRECTORY_FLAGS, dir_fd=fd)
                except FileNotFoundError:
                    yield None
                    return
                os.close(fd)
                fd = child
                metadata = os.fstat(fd)
                if metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022:
                    raise probe.Rejected("unsafe destination parent")
                prefix = "/".join(components)
                identity = _identity(fd)
                if identities is not None:
                    identities.append((prefix, identity))
                if created:
                    self._created_parents[prefix] = identity
            yield fd
        finally:
            os.close(fd)

    def _observe(self, path, parents):
        try:
            with self._parent(path, identities=parents) as parent:
                if parent is None:
                    return None
                try:
                    fd = os.open(path.split("/")[-1], FILE_FLAGS, dir_fd=parent)
                except FileNotFoundError:
                    return None
                try:
                    metadata = os.fstat(fd)
                    if metadata.st_uid != os.geteuid() or not metadata.st_mode & 0o400:
                        raise probe.Rejected("destination is not a readable owner file")
                    return _fingerprint(fd)
                finally:
                    os.close(fd)
        except (OSError, probe.Rejected):
            return {"blocked": True}

    def plan(self):
        self._check()
        actions, observations = [], []
        for entry in self.bundle._manifest["entries"]:
            parents = []
            observed = self._observe(entry["path"], parents)
            saved = self._journal["entries"].get(entry["object"])
            if not entry["mode"] & 0o400:
                status, reason = "conflict", "unreadable source mode is unsupported by this probe"
            elif saved:
                if observed == saved["file"] and _matches(entry, observed):
                    status, reason = "restored", "prior publication matches journal"
                else:
                    # Missing after intent is ambiguous: a user may have
                    # deleted the file after link() but before completion.
                    status, reason = "conflict", "destination changed or publication outcome is uncertain"
            elif observed is None:
                status, reason = "create", "new file"
            elif _matches(entry, observed):
                status, reason = "present", "matching file already exists"
            else:
                status, reason = "conflict", "existing file or unsafe path preserved"
            actions.append(Action(entry["path"], status, reason))
            observations.append((observed, parents))
        self._plan = tuple(actions)
        self._observations = observations
        return self._plan

    def _prepare(self, entry):
        temporary = str(uuid.uuid4())
        fd = os.open(temporary, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=self._job_fd)
        try:
            with os.fdopen(fd, "w+b") as output:
                path = self.bundle._directory / entry["object"].split("/")[1]
                source_fd = os.open(path, FILE_FLAGS)
                with os.fdopen(source_fd, "rb") as source:
                    if not stat.S_ISREG(os.fstat(source_fd).st_mode):
                        raise probe.Rejected("verified scratch is not a regular file")
                    remaining = entry["bytes"]
                    while remaining:
                        piece = source.read(min(remaining, probe.CHUNK))
                        if not piece:
                            raise probe.Rejected("verified scratch is truncated")
                        output.write(piece)
                        remaining -= len(piece)
                    if source.read(1):
                        raise probe.Rejected("verified scratch grew")
                output.flush()
                os.fchmod(fd, entry["mode"])
                os.utime(fd, ns=(entry["mtime_ns"], entry["mtime_ns"]))
                os.fsync(fd)
                output.seek(0)
                fingerprint = _fingerprint(fd)
                if not _matches(entry, fingerprint):
                    raise probe.Rejected("verified scratch digest differs")
            os.fsync(self._job_fd)
            return {"state": "pending", "file": fingerprint, "temporary": temporary}
        except BaseException:
            os.unlink(temporary, dir_fd=self._job_fd)
            raise

    def _cleanup(self, saved):
        # A pending object may be hardlinked to a now user-edited destination.
        # Never mutate its bytes or permissions, and only unlink our own inode.
        try:
            metadata = os.stat(saved["temporary"], dir_fd=self._job_fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        expected = saved["file"]
        if stat.S_ISREG(metadata.st_mode) and (metadata.st_dev, metadata.st_ino) == (expected["device"], expected["inode"]):
            os.unlink(saved["temporary"], dir_fd=self._job_fd)
            os.fsync(self._job_fd)

    def apply(self, plan):
        self._check()
        if plan is not self._plan or plan is None:
            raise probe.Rejected("apply requires this session's latest plan")
        if self._load() != self._journal:
            raise probe.Rejected("restore journal changed after planning")
        self._plan = None
        self._created_parents = {}
        self._save()
        report = []
        for entry, action, before in zip(self.bundle._manifest["entries"], plan, self._observations):
            self._check()
            parents = []
            observed = self._observe(entry["path"], parents)
            previous_file, planned_parents = before
            parents_match = parents[:len(planned_parents)] == planned_parents and all(
                self._created_parents.get(path) == identity
                for path, identity in parents[len(planned_parents):]
            )
            if observed != previous_file or not parents_match:
                report.append(Action(entry["path"], "conflict", "destination changed after planning"))
                continue
            if action.status in ("present", "conflict"):
                report.append(action)
                continue
            previous = self._journal["entries"].get(entry["object"])
            if action.status == "restored":
                # Re-establish directory durability if the earlier process
                # stopped between link publication and its directory fsync.
                with self._parent(entry["path"]) as parent:
                    os.fsync(parent)
                previous["state"] = "applied"
                self._save()
                self._cleanup(previous)
                report.append(action)
                continue
            saved = self._prepare(entry)
            self._journal["entries"][entry["object"]] = saved
            self._save()  # Durable witness must precede target publication.
            with self._parent(entry["path"], create=True) as parent:
                try:
                    os.link(saved["temporary"], entry["path"].split("/")[-1],
                            src_dir_fd=self._job_fd, dst_dir_fd=parent, follow_symlinks=False)
                except FileExistsError:
                    report.append(Action(entry["path"], "conflict", "destination appeared during publication"))
                    continue
                os.fsync(parent)
            saved["state"] = "applied"
            self._save()
            self._cleanup(saved)
            report.append(Action(entry["path"], "restored", "new file published"))
        return tuple(report)

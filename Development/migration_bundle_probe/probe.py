"""Disposable bundle experiment. Not a shipped exporter or home-directory importer.

Uses an independently verified age executable. Passphrases cross a private PTY
only; this experimental adapter is for synthetic tests, not a stable GUI API.
"""

import base64
import binascii
import contextlib
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import pty
import select
import stat
import subprocess
import tarfile
import tempfile
import termios
import threading
import time
import uuid


SCHEMA = "omarchy-migration-probe/1"
MAX_MANIFEST = 1024 * 1024
MAX_ENTRIES = 1024
MAX_TOTAL = 1024 * 1024 * 1024
CHUNK = 64 * 1024
# Narrow probe profile, matching the pinned age CLI's default. This is not a
# general-purpose age parser or cryptographic verifier.
SCRYPT_LOG_N = b"18"
MAX_AGE_LINE = 80
# Fixture-only holdouts. Real adapter paths/aliases still require qualification.
HOLDOUTS = (".ssh", ".gnupg", ".config/BraveSoftware", ".config/1Password", ".codex")


class Rejected(ValueError):
    pass


def checked_age_header(source):
    """Bound work before starting age; age still authenticates the entire file."""
    lines = []
    for _ in range(4):
        line = source.readline(MAX_AGE_LINE + 1)
        if not line.endswith(b"\n") or len(line) > MAX_AGE_LINE:
            raise Rejected("unsupported or oversized age header")
        lines.append(line)
    if lines[0] != b"age-encryption.org/v1\n":
        raise Rejected("unsupported age version")
    arguments = lines[1][:-1].split(b" ")
    if len(arguments) != 4 or arguments[:2] != [b"->", b"scrypt"]:
        raise Rejected("only one passphrase recipient is supported")
    if arguments[3] != SCRYPT_LOG_N:
        raise Rejected("unsupported scrypt work factor")

    def canonical_base64(value, length):
        try:
            decoded = base64.b64decode(value + b"=" * (-len(value) % 4), validate=True)
        except binascii.Error as error:
            raise Rejected("invalid age header encoding") from error
        if len(decoded) != length or base64.b64encode(decoded).rstrip(b"=") != value:
            raise Rejected("noncanonical age header encoding")

    canonical_base64(arguments[2], 16)
    canonical_base64(lines[2][:-1], 32)
    if not lines[3].startswith(b"--- "):
        raise Rejected("extra or unsupported age recipient")
    canonical_base64(lines[3][4:-1], 32)
    return b"".join(lines)


def digest_file(path):
    with open(path, "rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def selected_files(files, include_credentials=False):
    return {
        name: path
        for name, path in files.items()
        if include_credentials
        or not any(name == root or name.startswith(root + "/") for root in HOLDOUTS)
    }


def make_manifest(files):
    entries = []
    for index, (name, source) in enumerate(sorted(files.items())):
        metadata = source.stat()
        entries.append({
            "path": name,
            "object": f"objects/{index:08d}",
            "bytes": metadata.st_size,
            "sha256": digest_file(source),
            "mode": metadata.st_mode & 0o777,
            "mtime_ns": metadata.st_mtime_ns,
        })
    return {"schema": SCHEMA, "export_id": str(uuid.uuid4()), "entries": entries}


def validate_manifest(manifest):
    if not isinstance(manifest, dict) or set(manifest) != {"schema", "export_id", "entries"}:
        raise Rejected("manifest fields")
    if manifest["schema"] != SCHEMA:
        raise Rejected("unsupported schema")
    if not isinstance(manifest["export_id"], str):
        raise Rejected("export identity")
    try:
        if str(uuid.UUID(manifest["export_id"])) != manifest["export_id"]:
            raise ValueError()
    except ValueError as error:
        raise Rejected("export identity") from error
    entries = manifest["entries"]
    if not isinstance(entries, list) or len(entries) > MAX_ENTRIES:
        raise Rejected("entry count")
    paths = set()
    total = 0
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict) or set(entry) != {
            "path", "object", "bytes", "sha256", "mode", "mtime_ns"
        }:
            raise Rejected("entry fields")
        name = entry["path"]
        if not isinstance(name, str) or not name or len(name.encode("utf-8")) > 4096:
            raise Rejected("path size/type")
        if any(part in ("", ".", "..") for part in name.split("/")) or "\0" in name:
            raise Rejected("unsafe path")
        if name in paths or entry["object"] != f"objects/{index:08d}":
            raise Rejected("duplicate path or object identity")
        if type(entry["bytes"]) is not int or not 0 <= entry["bytes"] <= MAX_TOTAL:
            raise Rejected("entry size")
        if type(entry["mode"]) is not int or not 0 <= entry["mode"] <= 0o777:
            raise Rejected("mode")
        if type(entry["mtime_ns"]) is not int or not 0 <= entry["mtime_ns"] < 2**63:
            raise Rejected("mtime")
        checksum = entry["sha256"]
        if not isinstance(checksum, str) or len(checksum) != 64 or any(
            char not in "0123456789abcdef" for char in checksum
        ):
            raise Rejected("digest")
        paths.add(name)
        total += entry["bytes"]
        if total > MAX_TOTAL:
            raise Rejected("expanded size")
    for name in paths:
        if any(str(parent) in paths for parent in PurePosixPath(name).parents):
            raise Rejected("file used as parent")


class AgeProcess:
    """Keep payload pipes separate from a bounded, non-echoing prompt channel."""

    def __init__(self, age, arguments, secret, stdin, stdout):
        if not secret or any(char in secret for char in (b"\n", b"\r", b"\0")):
            raise Rejected("invalid probe passphrase")
        self.master, slave = pty.openpty()
        attributes = termios.tcgetattr(slave)
        attributes[3] &= ~termios.ECHO
        termios.tcsetattr(slave, termios.TCSANOW, attributes)

        def attach_tty():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        self.process = subprocess.Popen(
            [str(age), *arguments], stdin=stdin, stdout=stdout,
            stderr=subprocess.PIPE, pass_fds=(slave,), preexec_fn=attach_tty,
            env={"PATH": "/usr/bin:/bin", "LANG": "C"},
        )
        os.close(slave)
        self.prompt_error = None

        def respond():
            pending = b""
            responses = 0
            deadline = time.monotonic() + 60
            prompts = (
                b"Enter passphrase (leave empty to autogenerate a secure one):",
                b"Confirm passphrase:", b"Enter passphrase:",
            )
            try:
                while self.process.poll() is None:
                    if time.monotonic() > deadline:
                        raise Rejected("prompt deadline")
                    if not select.select([self.master], [], [], 0.05)[0]:
                        continue
                    try:
                        data = os.read(self.master, 4096)
                    except OSError:
                        break
                    if not data:
                        break
                    pending += data
                    if len(pending) > 8192:
                        raise Rejected("unexpected prompt output")
                    for prompt in prompts:
                        if prompt in pending:
                            responses += 1
                            if responses > 2:
                                raise Rejected("unexpected prompt count")
                            # ECHO is disabled before starting the process as well.
                            os.write(self.master, secret + b"\n")
                            pending = pending.split(prompt, 1)[1]
                            break
            except Exception as error:
                self.prompt_error = error
                self.process.kill()

        self.thread = threading.Thread(target=respond, daemon=True)
        self.thread.start()

    def finish(self):
        status = self.process.wait(timeout=65)
        self.thread.join(timeout=1)
        if status or self.prompt_error:
            # Deliberately do not expose raw terminal/error output to callers.
            raise Rejected("age rejected the transfer")

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=5)
        self.thread.join(timeout=1)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream:
                # Cancellation may leave producer input buffered after age exits.
                # Close every descriptor without masking the original failure.
                with contextlib.suppress(OSError):
                    stream.close()
        os.close(self.master)


def write_archive(stream, manifest, files):
    """Numbered regular tar members; personal paths/metadata live in the manifest."""
    with tarfile.open(fileobj=stream, mode="w|", format=tarfile.USTAR_FORMAT) as archive:
        data = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
        metadata = tarfile.TarInfo("manifest.json")
        metadata.mode, metadata.size = 0o600, len(data)
        archive.addfile(metadata, io.BytesIO(data))
        for entry in manifest["entries"]:
            metadata = tarfile.TarInfo(entry["object"])
            metadata.mode, metadata.size = 0o600, entry["bytes"]
            with open(files[entry["path"]], "rb") as source:
                archive.addfile(metadata, source)


def encrypt(age, secret, output, writer):
    """Commit ciphertext only after the producer and age both succeed."""
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".partial-", dir=output.parent) as sink:
            temporary = Path(sink.name)
            with contextlib.closing(AgeProcess(age, ["--passphrase"], secret, subprocess.PIPE, sink)) as child:
                writer(child.process.stdin)
                child.process.stdin.close()
                child.finish()
            sink.flush()
            os.fsync(sink.fileno())
            receipt = {
                "format": "age-v1", "bytes": sink.tell(),
                "sha256": digest_file(temporary),
            }
            # Hard-link publication is atomic and cannot overwrite an existing file.
            os.link(temporary, output)
            return receipt
    finally:
        if temporary and temporary.exists():
            temporary.unlink()


def read_exact(stream, count):
    parts = bytearray()
    while len(parts) < count:
        piece = stream.read(min(CHUNK, count - len(parts)))
        if not piece:
            raise Rejected("truncated archive")
        parts.extend(piece)
    return bytes(parts)


def read_header(stream, expected_name, limit):
    block = read_exact(stream, 512)
    try:
        header = tarfile.TarInfo.frombuf(block, "utf-8", "strict")
    except (tarfile.HeaderError, UnicodeError, ValueError) as error:
        raise Rejected("invalid tar header") from error
    if header.type != tarfile.REGTYPE or header.name != expected_name:
        raise Rejected("unexpected archive entry")
    if header.pax_headers or header.linkname or not 0 <= header.size <= limit:
        raise Rejected("invalid archive metadata")
    return header.size


def consume_padding(stream, length):
    if any(read_exact(stream, (-length) % 512)):
        raise Rejected("invalid archive padding")


def unique_json_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Rejected("duplicate JSON key")
        result[key] = value
    return result


def validate_archive(stream):
    length = read_header(stream, "manifest.json", MAX_MANIFEST)
    try:
        manifest = json.loads(read_exact(stream, length), object_pairs_hook=unique_json_pairs)
        validate_manifest(manifest)
    except (ValueError, UnicodeError, TypeError) as error:
        raise Rejected("invalid manifest") from error
    consume_padding(stream, length)
    for entry in manifest["entries"]:
        length = read_header(stream, entry["object"], entry["bytes"])
        if length != entry["bytes"]:
            raise Rejected("entry size differs from manifest")
        checksum = hashlib.sha256()
        remaining = length
        while remaining:
            piece = read_exact(stream, min(CHUNK, remaining))
            checksum.update(piece)
            remaining -= len(piece)
        if checksum.hexdigest() != entry["sha256"]:
            raise Rejected("entry digest differs from manifest")
        consume_padding(stream, length)
    # Consume through EOF, including the final age authentication tag. Do not
    # treat tar's end marker as successful completion of the encrypted stream.
    tail_size = 0
    while piece := stream.read(CHUNK):
        tail_size += len(piece)
        if any(piece) or tail_size > 10240:
            raise Rejected("trailing archive data")
    if tail_size < 1024 or tail_size % 512:
        raise Rejected("archive end marker")
    return manifest


def decode(age, secret, ciphertext, limit=MAX_TOTAL + MAX_MANIFEST + 2 * 1024 * 1024):
    fd = os.open(ciphertext, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb", buffering=0) as source:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode):
            raise Rejected("ciphertext must be a regular file")
        if type(limit) is not int or limit <= 0 or metadata.st_size > limit:
            raise Rejected("ciphertext size limit")
        header = checked_age_header(source)
        errors = []
        with contextlib.closing(AgeProcess(age, ["--decrypt"], secret, subprocess.PIPE, subprocess.PIPE)) as child:
            def feed():
                try:
                    # Send the checked bytes, never let age reread a header
                    # another writer could replace with an expensive one.
                    child.process.stdin.write(header)
                    count = len(header)
                    while data := source.read(CHUNK):
                        count += len(data)
                        if count > limit:
                            raise Rejected("ciphertext grew beyond its limit")
                        child.process.stdin.write(data)
                except (OSError, Rejected) as error:
                    errors.append(error)
                finally:
                    with contextlib.suppress(OSError):
                        child.process.stdin.close()

            feeder = threading.Thread(target=feed, daemon=True)
            feeder.start()
            try:
                manifest = validate_archive(child.process.stdout)
                child.finish()
                feeder.join(timeout=1)
                if errors or feeder.is_alive():
                    raise Rejected("ciphertext input failed")
                # No decoded result escapes before complete authentication.
                return manifest
            finally:
                if child.process.poll() is None:
                    child.process.kill()
                feeder.join(timeout=5)

"""Runnable integration fixture: generates fake data, never scans a home."""

import argparse
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

from . import probe
from .dependency import configured_age


SCHEMA = "omarchy-migration-fixture/1"
SECRET = b"synthetic-only-otter-maple-window-cobalt"
EXAMPLES = {
    "Projects/demo/changed.txt": b"SYNTHETIC modified project file\n",
    "Projects/demo/untracked.txt": b"SYNTHETIC untracked draft\n",
    ".config/example-theme/selected": b"catppuccin\n",
    ".config/unfamiliar-example/settings": b"preserve-this-unknown-setting=true\n",
    ".ssh/id_example": b"FAKE-SSH-SECRET-NOT-A-PRIVATE-KEY\n",
    ".config/BraveSoftware/Brave-Origin/Default/example": b"FAKE-BROWSER-TOKEN\n",
}


class FixtureError(ValueError):
    pass


class Cancelled(Exception):
    pass


def request_document(value):
    if not isinstance(value, dict) or set(value) != {"schema", "request_id", "include_credentials"}:
        raise FixtureError("invalid_request_fields")
    if value["schema"] != SCHEMA or type(value["include_credentials"]) is not bool:
        raise FixtureError("unsupported_request")
    try:
        if str(uuid.UUID(value["request_id"])) != value["request_id"]:
            raise ValueError()
    except (ValueError, AttributeError, TypeError):
        raise FixtureError("invalid_request_id") from None
    return value


def sync_directory(directory):
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_document(path, value):
    # Publication cannot overwrite any caller-supplied file. The output
    # directory is owned by this synthetic job, not an arbitrary home.
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".fixture-") as temporary:
        temporary.write((json.dumps(value, sort_keys=True) + "\n").encode())
        temporary.flush()
        os.fsync(temporary.fileno())
        os.link(temporary.name, path)
        sync_directory(path.parent)
    sync_directory(path.parent)


def private_regular(path):
    metadata = path.lstat()
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
            or metadata.st_nlink != 1 or metadata.st_mode & 0o077):
        raise FixtureError("unsafe_job_file")
    return metadata


def read_document(path):
    if private_regular(path).st_size > 8192:
        raise FixtureError("oversized_job_document")
    return json.loads(path.read_bytes(), object_pairs_hook=probe.unique_json_pairs)


def reuse_complete(directory, request, age):
    metadata = directory.lstat()
    if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid()
            or metadata.st_mode & 0o077):
        raise FixtureError("unsafe_job_directory")
    try:
        if read_document(directory / "request.json") != request:
            raise FixtureError("request_conflict")
        receipt = read_document(directory / "receipt.json")
    except FileNotFoundError:
        raise FixtureError("job_incomplete_use_new_directory") from None
    if (not isinstance(receipt, dict) or set(receipt) != {
        "schema", "request", "export_id", "format", "bytes", "sha256", "filename", "synthetic"
    } or receipt["schema"] != SCHEMA or receipt["request"] != request
            or receipt["filename"] != "bundle.age" or receipt["synthetic"] is not True
            or receipt["format"] != "age-v1" or type(receipt["bytes"]) is not int):
        raise FixtureError("invalid_receipt")
    bundle = directory / "bundle.age"
    if (private_regular(bundle).st_size != receipt["bytes"]
            or probe.digest_file(bundle) != receipt["sha256"]):
        raise FixtureError("ciphertext_changed")
    if probe.decode(age, SECRET, bundle)["export_id"] != receipt["export_id"]:
        raise FixtureError("export_identity_changed")
    sync_directory(directory)
    sync_directory(directory.parent)
    return receipt


def export_fixture(request, directory, age, emit, cancelled, pause=0):
    def check_cancelled():
        if cancelled():
            raise Cancelled()

    request_document(request)
    check_cancelled()
    try:
        directory.mkdir(mode=0o700)
    except FileExistsError:
        receipt = reuse_complete(directory, request, age)
        check_cancelled()
        emit("complete", receipt=receipt, reused=True)
        return receipt
    sync_directory(directory.parent)
    write_document(directory / "request.json", request)
    emit("preparing")
    deadline = time.monotonic() + pause
    while time.monotonic() < deadline:
        check_cancelled()
        time.sleep(max(0, min(0.05, deadline - time.monotonic())))
    check_cancelled()
    with tempfile.TemporaryDirectory(prefix="migration-fixture-source-") as temporary:
        sources = {}
        for index, (name, content) in enumerate(EXAMPLES.items()):
            path = Path(temporary) / str(index)
            path.write_bytes(content)
            path.chmod(0o600)
            sources[name] = path
        selected = probe.selected_files(sources, request["include_credentials"])
        manifest = probe.make_manifest(selected)
        emit("capturing")

        class CancellableWriter:
            def __init__(self, stream):
                self.stream = stream

            def write(self, value):
                check_cancelled()
                return self.stream.write(value)

        encrypted = probe.encrypt(
            age, SECRET, directory / "bundle.age",
            lambda stream: probe.write_archive(CancellableWriter(stream), manifest, selected),
        )
        check_cancelled()
        emit("finalizing")
        check_cancelled()
        if probe.decode(age, SECRET, directory / "bundle.age") != manifest:
            raise FixtureError("validation_failed")
        check_cancelled()
        sync_directory(directory)
        receipt = {
            "schema": SCHEMA, "request": request, "export_id": manifest["export_id"],
            **encrypted, "filename": "bundle.age", "synthetic": True,
        }
        write_document(directory / "receipt.json", receipt)
        emit("complete", receipt=receipt, reused=False)
        return receipt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    commands.add_parser("capabilities")
    commands.add_parser("inventory")
    export = commands.add_parser("export")
    export.add_argument("--request", type=Path, required=True)
    export.add_argument("--output-directory", type=Path, required=True)
    export.add_argument("--pause-before-capture", type=float, default=0)
    args = parser.parse_args(argv)
    if args.operation == "capabilities":
        print(json.dumps({"schema": SCHEMA, "synthetic": True,
                          "operations": ["capabilities", "inventory", "export"],
                          "credential_adapters": "synthetic-only"}))
        return 0
    if args.operation == "inventory":
        ordinary = probe.selected_files(EXAMPLES)
        print(json.dumps({"schema": SCHEMA, "synthetic": True, "categories": {
            "files_and_config": {"files": len(ordinary), "bytes": sum(map(len, ordinary.values()))},
            "credentials": {"files": len(EXAMPLES) - len(ordinary), "default_selected": False},
        }}))
        return 0
    if not 0 <= args.pause_before_capture <= 30:
        parser.error("pause must be between 0 and 30 seconds")
    cancel_requested = False

    def cancel(_signal, _frame):
        nonlocal cancel_requested
        cancel_requested = True

    previous = {number: signal.signal(number, cancel) for number in (signal.SIGINT, signal.SIGTERM)}
    request_id = None
    sequence = 0

    def emit(phase, **fields):
        nonlocal sequence
        sequence += 1
        print(json.dumps({"schema": SCHEMA, "synthetic": True, "request_id": request_id,
                          "sequence": sequence, "phase": phase, **fields}), flush=True)

    try:
        if not args.request.is_file():
            raise FixtureError("request_must_be_regular_file")
        with args.request.open("rb") as stream:
            raw = stream.read(8193)
        if len(raw) > 8192:
            raise FixtureError("oversized_request")
        request = request_document(json.loads(raw, object_pairs_hook=probe.unique_json_pairs))
        request_id = request["request_id"]
        age = configured_age()
        if age is None:
            raise FixtureError("age_dependency_unconfigured")
        export_fixture(request, args.output_directory, age, emit,
                       lambda: cancel_requested, args.pause_before_capture)
        return 0
    except Cancelled:
        emit("cancelled")
        return 130
    except FixtureError as error:
        emit("failed", error=str(error))
        return 1
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        emit("failed", error="fixture_operation_failed")
        return 1
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    sys.exit(main())

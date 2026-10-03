"""Runnable integration fixture: generates a fake Try home, never scans a real one.

Speaks the omarchy-migration contract documents (capabilities, inventory,
export-request, progress, receipt) and collects through the Try policy.
"""

import argparse
import hashlib
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

from . import contract
from . import collection, probe
from .categories import CATEGORIES, DEFAULT_SELECTED, category
from .dependency import configured_age


SECRET = b"synthetic-only-otter-maple-window-cobalt"
MODULE_VERSION = "0.0.0-fixture"
OMARCHY_VERSION = "4.0.4"
# The fixture has no real account; contract identities need a person's UID.
SYNTHETIC_UID = 1000
POLICY_PATH = Path(__file__).resolve().parent / "policies/try-omarchy-82927e9.json"
FIXTURE_ADAPTERS = {"ssh": "fixture-ssh-bytes/1", "brave": "fixture-browser/1"}
SUPPORTED_ADAPTERS = tuple(sorted(FIXTURE_ADAPTERS.values()))
INVENTORY_NAMESPACE = uuid.UUID("5a0e2c1e-7f43-4d1b-9a8e-6c0d3b2f4e17")
MAX_REQUEST = contract.MAX_REQUEST


class FixtureError(ValueError):
    pass


class Cancelled(Exception):
    pass


def fixture_policy():
    """The Try policy with fixture-only byte-copy adapters for two fake stores."""
    document = json.loads(POLICY_PATH.read_bytes())
    document["revision"] += "/fixture"
    for store in document["credential_stores"]:
        store["adapter"] = FIXTURE_ADAPTERS.get(store["id"])
    contract.validate(document)
    return document


def examples(policy):
    """Fixed synthetic home contents, including the files Try itself writes."""
    block = next(rule for rule in policy["rules"] if rule["id"] == "try-hypr-input-overrides")
    files = {
        "Projects/demo/changed.txt": b"SYNTHETIC modified project file\n",
        "Projects/demo/untracked.txt": b"SYNTHETIC untracked draft\n",
        ".config/example-theme/selected": b"catppuccin\n",
        ".config/unfamiliar-example/settings": b"preserve-this-unknown-setting=true\n",
        ".config/hypr/input.lua": b"input {\n  kb_layout = us\n}\n" + block["transform"]["block"].encode(),
        ".config/hypr/monitors.lua": b"monitor = Virtual-1, preferred, auto, 2\n",
        ".config/chromium-flags.conf": b"--ozone-platform=wayland\n--enable-wayland-ime\n",
        ".config/omarchy/extensions/omarchy-menu.jsonc": (
            b'{\n  "setup.try-omarchy": {"label": "Try Omarchy Settings", "action": "omarchy-native-settings"},\n'
            b'  "launch.notes": {"label": "Notes", "action": "obsidian"}\n}\n'),
        ".ssh/id_example": b"FAKE-SSH-SECRET-NOT-A-PRIVATE-KEY\n",
        ".config/BraveSoftware/Brave-Origin/Default/example": b"FAKE-BROWSER-TOKEN\n",
    }
    links = {"Work": "/mnt/mac"}
    return files, links


def materialize(directory, files, links):
    for name, content in files.items():
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_bytes(content)
        path.chmod(0o600)
    for name, target in links.items():
        (directory / name).symlink_to(target)


def inventory_id(policy, files, links):
    digest = hashlib.sha256(json.dumps(
        {"revision": policy["revision"], "files": {name: hashlib.sha256(data).hexdigest() for name, data in files.items()},
         "links": links}, sort_keys=True).encode()).hexdigest()
    return str(uuid.uuid5(INVENTORY_NAMESPACE, digest))


def roots(files, links, categories):
    names = {name.split("/")[0] for name in files} | set(links)
    return [{"source": name, "archive": name} for name in sorted(names) if category(name) in categories]


def capabilities_document(policy):
    adapters = []
    for store in policy["credential_stores"]:
        adapter = {"id": store["adapter"] or f"{store['id']}-adapter", "category": store["category"],
                   "available": store["adapter"] in SUPPORTED_ADAPTERS}
        if not adapter["available"]:
            adapter["reason"] = "adapter_not_implemented"
        adapters.append(adapter)
    document = {
        "schema": contract.CAPABILITIES,
        "module": {"name": "omarchy-migration", "version": MODULE_VERSION},
        "operations": ["inventory", "export"],
        "documents": [contract.CAPABILITIES, contract.INVENTORY, contract.EXPORT_REQUEST,
                      contract.PROGRESS, contract.RECEIPT],
        "bundle_formats": [contract.BUNDLE_FORMAT],
        "policy_revisions": [policy["revision"]],
        "adapters": adapters,
    }
    contract.validate(document)
    return document


def collection_request(request_id, files, links, categories, adapters):
    return {"schema": collection.REQUEST_SCHEMA, "request_id": request_id,
            "selection": roots(files, links, categories), "selected_adapters": sorted(adapters)}


def inventory_document(policy):
    files, links = examples(policy)
    counts = {name: {"files": 0, "bytes": 0} for name in CATEGORIES}
    with tempfile.TemporaryDirectory(prefix="migration-fixture-inventory-") as temporary:
        home, parent = Path(temporary) / "home", Path(temporary) / "snapshots"
        home.mkdir(mode=0o700)
        parent.mkdir(mode=0o700)
        materialize(home, files, links)
        request = collection_request(str(uuid.uuid4()), files, links, CATEGORIES, ())
        with collection.collect_fixture(home, request, policy, supported_adapters=SUPPORTED_ADAPTERS,
                                        snapshot_parent=parent) as snapshot:
            for entry in snapshot.manifest["entries"]:
                # Inventory counts the user's files, not migration-owned copies.
                if probe.entry_kind(entry) == "file" and not entry["path"].startswith(collection.ORIGINALS_ROOT + "/"):
                    counts[category(entry["path"])]["files"] += 1
                    counts[category(entry["path"])]["bytes"] += entry["bytes"]
        present = {store["id"] for store in policy["credential_stores"]
                   if any((home / root).exists() for root in store["roots"])}
    document = {
        "schema": contract.INVENTORY,
        "inventory_id": inventory_id(policy, files, links),
        "source": {"provider": "try-omarchy", "architecture": "aarch64",
                   "omarchy_version": OMARCHY_VERSION, "account_uid": SYNTHETIC_UID},
        "policy_revision": policy["revision"],
        "categories": [{"id": name, **counts[name], "default_selected": DEFAULT_SELECTED[name]}
                       for name in CATEGORIES],
        "credential_stores": [{"id": store["id"], "category": store["category"], "present": store["id"] in present,
                               "adapter_available": store["adapter"] in SUPPORTED_ADAPTERS}
                              for store in policy["credential_stores"]],
    }
    contract.validate(document)
    return document


def check_request(request, policy):
    """Bind an export request to this fixture's inventory and policy."""
    files, links = examples(policy)
    if request["inventory_id"] != inventory_id(policy, files, links):
        raise FixtureError("inventory_changed")
    if request["policy_revision"] != policy["revision"]:
        raise FixtureError("policy_revision_mismatch")
    selection = request["selection"]
    if not set(selection["categories"]) <= set(CATEGORIES):
        raise FixtureError("unknown_category")
    stores = {store["id"]: store for store in policy["credential_stores"]}
    if not set(selection["credential_stores"]) <= set(stores):
        raise FixtureError("unknown_credential_store")
    adapters = [stores[name]["adapter"] for name in selection["credential_stores"]]
    if any(adapter not in SUPPORTED_ADAPTERS for adapter in adapters):
        raise FixtureError("credential_store_unavailable")
    for name in selection["credential_stores"]:
        # A store is collected only inside a selected category's roots.
        if any(category(root) not in selection["categories"] for root in stores[name]["roots"]):
            raise FixtureError("credential_store_outside_selection")
    return files, links, adapters


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
    if private_regular(path).st_size > MAX_REQUEST:
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
    try:
        if contract.validate(receipt) != contract.RECEIPT:
            raise FixtureError("invalid_receipt")
    except contract.ContractError:
        raise FixtureError("invalid_receipt") from None
    if receipt["request_id"] != request["request_id"] or receipt["policy_revision"] != request["policy_revision"]:
        raise FixtureError("invalid_receipt")
    bundle = directory / "bundle.age"
    if (private_regular(bundle).st_size != receipt["bundle"]["bytes"]
            or probe.digest_file(bundle) != receipt["bundle"]["sha256"]):
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

    if contract.validate(request) != contract.EXPORT_REQUEST:
        raise FixtureError("unsupported_request")
    policy = fixture_policy()
    files, links, adapters = check_request(request, policy)
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
        home, parent = Path(temporary) / "home", Path(temporary) / "snapshots"
        home.mkdir(mode=0o700)
        parent.mkdir(mode=0o700)
        materialize(home, files, links)
        selection = collection_request(request["request_id"], files, links,
                                       request["selection"]["categories"], adapters)
        with collection.collect_fixture(home, selection, policy, supported_adapters=SUPPORTED_ADAPTERS,
                                        snapshot_parent=parent) as snapshot:
            manifest = snapshot.manifest
            emit("capturing")

            class CancellableWriter:
                def __init__(self, stream):
                    self.stream = stream

                def write(self, value):
                    check_cancelled()
                    return self.stream.write(value)

            encrypted = probe.encrypt(
                age, SECRET, directory / "bundle.age",
                lambda stream: probe.write_archive(CancellableWriter(stream), manifest, snapshot.paths),
            )
    check_cancelled()
    emit("finalizing")
    check_cancelled()
    if probe.decode(age, SECRET, directory / "bundle.age") != manifest:
        raise FixtureError("validation_failed")
    check_cancelled()
    sync_directory(directory)
    receipt = {
        "schema": contract.RECEIPT, "request_id": request["request_id"], "export_id": manifest["export_id"],
        "policy_revision": policy["revision"],
        "bundle": {"format": contract.BUNDLE_FORMAT, "schema": contract.BUNDLE,
                   "bytes": encrypted["bytes"], "sha256": encrypted["sha256"]},
        "estimates": {"expanded_bytes": sum(entry.get("bytes", 0) for entry in manifest["entries"]),
                      "entries": len(manifest["entries"])},
    }
    contract.validate(receipt)
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
        print(json.dumps(capabilities_document(fixture_policy()), sort_keys=True))
        return 0
    if args.operation == "inventory":
        print(json.dumps(inventory_document(fixture_policy()), sort_keys=True))
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
        event = {"schema": contract.PROGRESS, "request_id": request_id,
                 "sequence": sequence, "phase": phase, **fields}
        contract.validate(event)
        print(json.dumps(event, sort_keys=True), flush=True)

    try:
        if not args.request.is_file():
            raise FixtureError("request_must_be_regular_file")
        with args.request.open("rb") as stream:
            raw = stream.read(MAX_REQUEST + 1)
        if len(raw) > MAX_REQUEST:
            raise FixtureError("oversized_request")
        try:
            request = contract.parse(raw)
        except contract.ContractError:
            raise FixtureError("invalid_request") from None
        if request["schema"] != contract.EXPORT_REQUEST:
            raise FixtureError("unsupported_request")
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

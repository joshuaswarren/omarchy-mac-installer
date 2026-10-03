"""Reviewable import plans and reports in the omarchy-migration contract.

`plan` summarizes what a restore job would do as a plan/1 document; `apply`
runs that exact plan and returns a report/1 document. The command restores
only into a caller-owned disposable target, like the restorer it wraps.
"""

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import sys
import uuid

from ..migration_contract import contract
from . import probe, restore
from .categories import category
from .dependency import configured_age

PLAN_NAMESPACE = uuid.UUID("b6a0f7d2-31c4-4e65-8f0e-6d9a2c41e8b3")
MAX_PASSPHRASE = 1024

# Stable codes for the restorer's reasons. The test suite fails if the
# restorer gains a reason without a code here.
REASONS = {
    "new file": "new_entry",
    "new entry published": "new_entry",
    "matching file already exists": "already_present",
    "prior publication matches journal": "already_restored",
    "approved regular file; private original backup required": "replacement_approved",
    "original retained in private backup": "original_backed_up",
    "unsupported link retained only in encrypted manifest": "link_not_restorable",
    "unreadable source mode is unsupported by this probe": "unreadable_source_mode",
    "destination changed or publication outcome is uncertain": "destination_changed",
    "existing file or unsafe path preserved": "destination_exists",
    "directory or link dependency is unavailable": "dependency_unavailable",
    "directory dependency is unavailable": "dependency_unavailable",
    "link target or traversal directory is unavailable": "dependency_unavailable",
    "directory appeared during creation": "destination_changed",
    "directory changed during application": "destination_changed",
    "destination changed after planning": "destination_changed",
    "destination appeared during publication": "destination_changed",
    "replacement inputs changed": "destination_changed",
    "original backup changed or disappeared": "backup_unavailable",
    "structure retained; source directory metadata deferred": "directory_metadata_deferred",
}
PLAN_COUNTS = {"create": "create", "present": "present", "restored": "present",
               "replace": "replace", "conflict": "conflict", "inert": "inert"}


class ReviewError(ValueError):
    pass


def reason_code(action):
    try:
        return REASONS[action.reason]
    except KeyError:
        raise ReviewError(f"unclassified restore reason: {action.reason}") from None


def _entries(bundle):
    return {entry["path"]: entry for entry in bundle._manifest["entries"]}


def target_identity(target):
    metadata = os.stat(target, follow_symlinks=False)
    return [metadata.st_dev, metadata.st_ino]


def plan_id(bundle, actions, account_uid, target):
    # A reviewed plan applies only to the destination it was computed for.
    material = {"bundle": bundle.ciphertext_sha256, "account_uid": account_uid, "target": target_identity(target),
                "actions": [[action.path, action.status, action.reason] for action in actions]}
    digest = hashlib.sha256(json.dumps(material, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return str(uuid.uuid5(PLAN_NAMESPACE, digest))


def check_receipt(bundle, receipt):
    """The public receipt must describe exactly this authenticated bundle."""
    try:
        if contract.validate(receipt) != contract.RECEIPT:
            raise ReviewError("receipt_invalid")
    except contract.ContractError:
        raise ReviewError("receipt_invalid") from None
    if receipt["export_id"] != bundle.export_id or receipt["bundle"]["sha256"] != bundle.ciphertext_sha256:
        raise ReviewError("receipt_mismatch")


def plan_document(bundle, actions, receipt, account_uid, target):
    check_receipt(bundle, receipt)
    entries = _entries(bundle)
    counts = dict.fromkeys(("create", "present", "replace", "conflict", "omit", "inert"), 0)
    required = 0
    for action in actions:
        reason_code(action)
        counts[PLAN_COUNTS[action.status]] += 1
        if action.status in ("create", "replace") and probe.entry_kind(entries[action.path]) == "file":
            required += entries[action.path]["bytes"]
    document = {
        "schema": contract.PLAN, "plan_id": plan_id(bundle, actions, account_uid, target),
        "export_id": bundle.export_id, "bundle_sha256": bundle.ciphertext_sha256,
        "policy_revision": receipt["policy_revision"], "destination": {"account_uid": account_uid},
        "actions": counts, "packages": {"reinstall": 0, "manual": 0}, "required_bytes": required,
    }
    contract.validate(document)
    return document


def report_document(plan, results, job_id, bundle):
    if plan["export_id"] != bundle.export_id:
        raise ReviewError("plan_mismatch")
    groups = {}
    for result in results:
        code = reason_code(result)
        group = groups.setdefault(category(result.path), {"restored": 0, "conflicts": 0, "omitted": 0, "reasons": set()})
        if result.status == "directory":
            continue
        if result.status in ("restored", "replaced", "present"):
            group["restored"] += 1
        elif result.status == "conflict":
            group["conflicts"] += 1
            group["reasons"].add(code)
        else:
            group["omitted"] += 1
            group["reasons"].add(code)
    categories = []
    for name in sorted(groups):
        group = groups[name]
        if group["conflicts"]:
            outcome = "partial" if group["restored"] else "failed"
        else:
            outcome = "restored" if group["restored"] else "skipped"
        categories.append({"id": name, "outcome": outcome, "restored": group["restored"],
                           "conflicts": group["conflicts"], "omitted": group["omitted"],
                           "reasons": sorted(group["reasons"])})
    document = {"schema": contract.REPORT, "job_id": job_id, "export_id": bundle.export_id,
                "plan_id": plan["plan_id"], "categories": categories}
    contract.validate(document)
    return document


def job_identity(job):
    """A stable id for one restore job directory, so retries report as one job."""
    metadata = os.stat(job, follow_symlinks=False)
    return str(uuid.uuid5(PLAN_NAMESPACE, f"job:{metadata.st_dev}:{metadata.st_ino}"))


def read_passphrase(descriptor):
    data = b""
    while len(data) <= MAX_PASSPHRASE:
        piece = os.read(descriptor, MAX_PASSPHRASE + 1 - len(data))
        if not piece:
            break
        data += piece
    if len(data) > MAX_PASSPHRASE:
        raise ReviewError("passphrase_too_long")
    passphrase = data[:-1] if data.endswith(b"\n") else data
    if not passphrase or any(byte in passphrase for byte in b"\n\r\0"):
        raise ReviewError("passphrase_invalid")
    return passphrase


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("operation", choices=("plan", "apply"))
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--job", type=Path, required=True)
    parser.add_argument("--passphrase-fd", type=int, required=True,
                        help="read the transfer passphrase from this file descriptor")
    parser.add_argument("--plan-id", help="apply only if the current plan has this id")
    arguments = parser.parse_args(argv)
    if arguments.operation == "apply" and not arguments.plan_id:
        parser.error("apply requires --plan-id from a reviewed plan")
    try:
        age = configured_age()
        if age is None:
            raise ReviewError("age_dependency_unconfigured")
        secret = read_passphrase(arguments.passphrase_fd)
        receipt = contract.parse(arguments.receipt.read_bytes())
        account_uid = os.getuid()
        with restore.verified_bundle(age, secret, arguments.bundle) as bundle:
            with restore.Restorer(bundle, arguments.target, arguments.job) as importer:
                actions = importer.plan()
                plan = plan_document(bundle, actions, receipt, account_uid, arguments.target)
                if arguments.operation == "plan":
                    print(json.dumps(plan, indent=2, sort_keys=True))
                    return 0
                if plan["plan_id"] != arguments.plan_id:
                    raise ReviewError("plan_changed")
                results = importer.apply(actions)
                print(json.dumps(report_document(plan, results, job_identity(arguments.job), bundle),
                                 indent=2, sort_keys=True))
                return 0
    except (ReviewError, contract.ContractError, probe.Rejected) as error:
        print(json.dumps({"error": getattr(error, "code", None) or str(error)}), file=sys.stderr)
        return 1
    except OSError:
        print(json.dumps({"error": "review_operation_failed"}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    with contextlib.suppress(BrokenPipeError):
        sys.exit(main())

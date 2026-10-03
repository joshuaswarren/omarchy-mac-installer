"""Explicit dependency admission for the synthetic age experiment."""

import os
from pathlib import Path
import subprocess

from . import probe


def configured_age():
    selected = os.environ.get("OMARCHY_TEST_AGE")
    if not selected:
        return None
    age = Path(selected)
    expected = os.environ.get("OMARCHY_TEST_AGE_SHA256", "")
    if len(expected) != 64 or any(char not in "0123456789abcdef" for char in expected):
        raise RuntimeError("OMARCHY_TEST_AGE_SHA256 must identify the verified executable")
    if not age.is_absolute() or probe.digest_file(age) != expected:
        raise RuntimeError("age path or executable differs from the verified dependency")
    version = subprocess.run(
        [str(age), "--version"], check=True, capture_output=True, text=True, timeout=5,
    ).stdout.strip()
    if version not in ("1.3.2", "v1.3.2"):
        raise RuntimeError("this disposable probe requires age 1.3.2")
    return age

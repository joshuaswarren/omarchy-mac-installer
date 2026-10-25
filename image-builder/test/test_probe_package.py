#!/usr/bin/env python3
"""The probe package passes the engine's own full-OS package admission.

Builds a package from dummy binaries (image-builder/probe-package.py), then
holds the produced metadata and payload to the same validators the installer
engine runs on a Mac: omarchy_asahi.load_metadata, preflight's
_validate_full_os_package, the Stage 1 selection (board_stage1,
common_stage1_allowed, fill_aurora_stage1) and the install-time ESP layout
(esp_board_layout) for j575dap. The pinned engine modules (asahi-installer
v0.9.2, Engine/source-lock.json) are not in this repository; the stand-ins
are the ones image-builder/test/test_engine_contract.py holds to upstream.
"""
from __future__ import annotations

import argparse
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zipfile

from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]


def psize(value, align=None):
    """asahi-installer v0.9.2 src/util.py psize, without alignment."""
    value = value.upper().replace(" ", "")
    base = 1000
    if value[-2] == "I":
        base = 1024
        value = value[:-2] + value[-1]
    for suffix, power in {"TB": 4, "GB": 3, "MB": 2, "KB": 1, "B": 0, "": 0}.items():
        if value.endswith(suffix):
            return int(float(value[:-len(suffix)]) * (base ** power))
    return None


class OSInstaller:
    """What preflight reads of asahi-installer v0.9.2 src/osinstall.py."""

    def __init__(self, dutil, data, template):
        self.template = template

    @property
    def min_size(self):
        return sum(-(-psize(part["size"]) // (1 << 20) << 20) for part in self.template["partitions"])

    @property
    def min_recommended_size(self):
        expandable = any(part.get("expand", False) for part in self.template["partitions"])
        return self.min_size * 2 if expandable else self.min_size


sys.modules.setdefault("asahi_firmware", SimpleNamespace(core=SimpleNamespace(FWPackage=object)))
sys.modules.setdefault("osinstall", SimpleNamespace(OSInstaller=OSInstaller, psize=psize))
sys.modules.setdefault("stub", SimpleNamespace(StubInstaller=object))
sys.modules.setdefault("util", SimpleNamespace(align_down=lambda value, align: value - value % align))
sys.path.insert(0, str(ROOT.parent / "Engine" / "overlay" / "src"))
sys.path.insert(0, str(ROOT.parent / "scripts"))

import omarchy_asahi  # noqa: E402

_loader = importlib.machinery.SourceFileLoader(
    "probe_package", str(ROOT / "probe-package.py")
)
probe = importlib.util.module_from_spec(
    importlib.util.spec_from_loader("probe_package", _loader)
)
_loader.exec_module(probe)

DEVICE_CLASS = "j575dap"
OS_FIRMWARE = "27.0.1"


def dummy_stage1() -> bytes:
    """A minimal image that fill_aurora_stage1 accepts: one config block."""
    body = omarchy_asahi.STAGE1_BODY.pack(
        1, 0,
        omarchy_asahi.PLACEHOLDER_UUID.encode("ascii").ljust(40, b"\0"),
        b";m1n1/boot.bin".ljust(192, b"\0"),
    )
    block = (
        omarchy_asahi.STAGE1_MAGIC + body
        + struct.pack("<I", __import__("zlib").crc32(body))
    )
    return b"\0" * 16 + block + b"\0" * 16 + b"STACKBOT"


def build(output: Path, stage1: bool) -> None:
    bin_dir = Path(tempfile.mkdtemp(dir=output))
    paths = {}
    for name, data in {
        "stage2.bin": b"dummy-probe-m1n1-stage2" * 512,
        "BOOTAA64.EFI": b"dummy-efi-loader" * 512,
        "stage1.bin": dummy_stage1(),
    }.items():
        paths[name] = bin_dir / name
        paths[name].write_bytes(data)
    argv = [
        "probe-package.py",
        "--stage2", str(paths["stage2.bin"]),
        "--bootaa64", str(paths["BOOTAA64.EFI"]),
        "--output", str(output),
        "--device-class", DEVICE_CLASS,
        "--os-firmware", OS_FIRMWARE,
    ]
    if stage1:
        argv[1:1] = ["--stage1", str(paths["stage1.bin"])]
    probe.main.__globals__["sys"].argv = argv
    probe.main()


def engine_adapter(output: Path, package_name: str):
    metadata_path = output / "installer_data.json"
    metadata = omarchy_asahi.load_metadata(metadata_path)
    adapter = omarchy_asahi.AsahiStage1Adapter(
        installer=SimpleNamespace(sysinfo=SimpleNamespace(device_class=DEVICE_CLASS)),
        metadata_path=metadata_path,
        payload_path=output / package_name,
        stub_size=0,
    )
    adapter.template = metadata["os_list"][0]
    adapter.use_helper_recovery = adapter.template.get("recovery_gui") is None
    adapter.osins = SimpleNamespace(pkg=zipfile.ZipFile(output / package_name))
    return adapter


class ProbePackageTest(unittest.TestCase):
    PACKAGE = "omarchy-probe-j575d-os-package.zip"

    def test_probe_package_passes_engine_admission(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            build(output, stage1=True)
            adapter = engine_adapter(output, self.PACKAGE)
            # The engine's package admission, unmodified.
            adapter._validate_full_os_package()

            template = adapter.template
            members = [m.filename for m in adapter.osins.pkg.infolist() if not m.is_dir()]
            esp = [m for m in members if m.startswith("esp/")]
            firmware = OS_FIRMWARE

            # Preflight's Stage 1 decision for this board: the payload's
            # common Stage 1 qualifies and fills (preflight read-back).
            self.assertTrue(
                omarchy_asahi.common_stage1_allowed(template, DEVICE_CLASS, firmware)
            )
            board = omarchy_asahi.board_stage1(
                DEVICE_CLASS, firmware, esp, common_allowed=True
            )
            self.assertIs(board, omarchy_asahi.COMMON_STAGE1)
            image = adapter.osins.pkg.read("esp/aurora/stage1.bin")
            filled = omarchy_asahi.fill_aurora_stage1(
                image, omarchy_asahi.PLACEHOLDER_UUID, template["next_object"],
                board.window_ms,
            )
            self.assertEqual(filled, image)

            # install_stub_and_esp's ESP layout: our Stage 2 lands at
            # m1n1/boot.bin, the Stage 1 stays at aurora/stage1.bin.
            layout = omarchy_asahi.esp_board_layout(
                DEVICE_CLASS, esp, common_allowed=True
            )
            self.assertEqual(layout["esp/m1n1/boot.bin"], "m1n1/boot.bin")
            self.assertEqual(layout["esp/aurora/stage1.bin"], "aurora/stage1.bin")
            self.assertEqual(layout["esp/EFI/BOOT/BOOTAA64.EFI"], "EFI/BOOT/BOOTAA64.EFI")

            # Nothing here claims to boot the OS image: boot.img and root.img
            # are the placeholder images, and the engine's checks above are
            # the only contract they must meet.
            metadata = json.loads((output / "installer_data.json").read_text())
            self.assertEqual(metadata["os_list"][0]["supported_fw"], [OS_FIRMWARE])
            self.assertEqual(
                metadata["os_list"][0]["allowed_device_classes"], [DEVICE_CLASS]
            )
            inputs = json.loads((output / "catalog-inputs.json").read_text())
            self.assertEqual(
                inputs["developer_models"][0]["device_identifiers"], ["apple,j575d"]
            )

    def test_probe_package_without_stage1_keeps_stub_boot_object(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            build(output, stage1=False)
            adapter = engine_adapter(output, self.PACKAGE)
            adapter._validate_full_os_package()
            esp = [
                m.filename for m in adapter.osins.pkg.infolist()
                if not m.is_dir() and m.filename.startswith("esp/")
            ]
            self.assertNotIn("esp/aurora/stage1.bin", esp)
            self.assertIsNone(
                omarchy_asahi.board_stage1(DEVICE_CLASS, OS_FIRMWARE, esp)
            )
            layout = omarchy_asahi.esp_board_layout(DEVICE_CLASS, esp)
            self.assertEqual(layout["esp/m1n1/boot.bin"], "m1n1/boot.bin")


if __name__ == "__main__":
    unittest.main()

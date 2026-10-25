#!/usr/bin/env python3
"""Build the j575dap probe package: an engine-valid full-OS payload whose only
live part is the probe m1n1.

The package has the exact full-OS shape Engine/overlay/src/omarchy_asahi.py's
_validate_full_os_package admits (EFI + Boot + Root, esp/ members, icon,
metadata contract), but boot.img and root.img are minimal placeholder images
and the ESP carries the probe m1n1. After install the Mac boots the probe
m1n1 (USB proxy); it never boots Linux, and nothing here claims to.

The private-test route (docs/probe-package.md): make-unsigned-catalog.py
--developer with the catalog-inputs.json this script writes, sealed into a
developer app build against the lab/developer catalog key. The public
channel is never used.

Usage:
  probe-package.py --stage2 BIN --bootaa64 EFI --output DIR [--stage1 BIN]
                   [--device-class j575dap] [--device-identifier apple,j575d]
                   [--os-firmware 27.0.1] [--image-mib 8]
                   [--name "Omarchy Probe (M3 Ultra)"]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ICON_NAME = "omarchy-volume.icns"
ICON = HERE / "builder" / ICON_NAME
SOURCE_LOCK = HERE.parent / "Engine" / "source-lock.json"
SUPPORTED_MODELS = HERE.parent / "scripts" / "supported-models.json"

# Image members must be non-empty and 4 KiB aligned (engine check); their
# declared partition capacity must be >= the member size. The engine's floor
# is therefore 4096 bytes; the default here keeps a margin above diskutil's
# practical APFS partition minimum.
IMAGE_BLOCK = 4096
DEFAULT_IMAGE_MIB = 8
# Same ESP the real image declares (mkfs volume id and size come from
# Engine/installer_data.json); firmware and installer data are copied into it
# at install time, so the 500 MiB real size is kept.
EFI_SIZE = 524288000
ESP_VOLUME_ID = "0x4f4d5801"
ZIP_EPOCH = (2026, 1, 1, 0, 0, 0)
# The developer group's own metadata name: distinct from the baseline
# metadata the main group pins, so one assets dir holds both.
GROUP_METADATA = "probe-installer_data.json"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1 << 20):
            value.update(block)
    return value.hexdigest()


def placeholder_image(size_bytes: int) -> bytes:
    """A minimal image: zero-filled, non-empty, 4 KiB aligned."""
    if size_bytes < IMAGE_BLOCK or size_bytes % IMAGE_BLOCK:
        raise SystemExit(f"--image-mib must be >= {IMAGE_BLOCK // (1 << 20)} MiB and 4 KiB aligned")
    return bytes(size_bytes)


def zip_member(name: str, data: bytes) -> tuple[zipfile.ZipInfo, bytes]:
    info = zipfile.ZipInfo(name, ZIP_EPOCH)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    return info, data


def build_metadata(args, package_name: str, image_bytes: int) -> dict:
    partitions = [
        {
            "name": "EFI", "type": "EFI", "source": "esp", "format": "fat",
            "size": f"{EFI_SIZE}B", "copy_firmware": True,
            "copy_installer_data": True, "volume_id": ESP_VOLUME_ID,
        },
        {
            "name": "Boot", "type": "Linux",
            "size": f"{image_bytes}B", "image": "boot.img",
        },
        {
            "name": "Root", "type": "Linux",
            "size": f"{image_bytes}B", "image": "root.img", "expand": True,
        },
    ]
    template = {
        "omarchy_target": "apple-silicon-full-os",
        "name": args.name,
        "default_os_name": args.name,
        "boot_object": "m1n1.bin",
        "next_object": "m1n1/boot.bin",
        "icon": ICON_NAME,
        "package": package_name,
        "supported_fw": [args.os_firmware],
        "allowed_device_classes": [args.device_class],
        "partitions": partitions,
    }
    if args.stage1:
        # Only members this Mac qualifies for install; anything else is
        # dropped by the engine's ESP layout, never installed.
        template["aurora_stage1"] = {
            "kind": "common-raw-v1",
            "qualified_machines": {args.device_class: [args.os_firmware]},
        }
    return {"os_list": [template]}


def build_catalog_inputs(args, package_name: str) -> dict:
    """Inputs for scripts/make-unsigned-catalog.py --developer.

    The probe payload rides in a developer group: the main group keeps every
    other supported Mac on the baseline release payload this build pins, the
    group takes the probe board with its own payload and metadata.
    make-unsigned-catalog refuses anything but exact coverage, and the
    manifest (scripts/supported-models.json) must admit the board.
    """
    if args.catalog_baseline_payload is None:
        raise SystemExit(
            "--catalog-baseline-payload is required: the main group must pin "
            "the real release payload the other supported Macs get; the probe "
            "payload must never be offered to them"
        )
    for path in (args.catalog_baseline_payload, args.catalog_baseline_metadata):
        if not path.is_file() or path.is_symlink():
            raise SystemExit(f"missing baseline artifact: {path}")
    lock = json.loads(SOURCE_LOCK.read_text())
    supported = json.loads(SUPPORTED_MODELS.read_text())["supported"]
    # The main group keeps every supported Mac the developer groups do not
    # take; make-unsigned-catalog refuses anything but exact coverage.
    group_boards = [args.device_identifier]
    main_boards = [board for board in supported if board not in group_boards]
    template_inputs = json.loads((HERE.parent / "scripts" / "release-inputs.template.json").read_text())
    # The one live source revision: this checkout (the engine overlay the
    # probe build pins).
    downstream_revision = args.downstream_revision or subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=str(HERE.parent), check=True,
        capture_output=True, text=True,
    ).stdout.strip()
    inputs = {
        "payload_name": args.catalog_baseline_payload.name,
        "metadata_name": args.catalog_baseline_metadata.name,
        "evidence_revision": f"probe-{args.device_identifier.removeprefix('apple,').removesuffix('ap')}-{datetime.now(timezone.utc).strftime('%Y.%m.%d')}",
        "asahi_installer_tag": lock["upstream_installer"]["tag"],
        "asahi_installer_revision": lock["upstream_installer"]["commit"],
        "asahi_installer_data_revision": lock["upstream_metadata"]["commit"],
        "downstream_revision": downstream_revision,
        "device_identifiers": main_boards,
        "installer": {
            "minimum_version": template_inputs["installer"]["minimum_version"],
            "latest_version": template_inputs["installer"]["latest_version"],
            "download_url": template_inputs["installer"]["download_url"],
        },
        "developer_models": [
            {
                "payload_name": package_name,
                "metadata_name": GROUP_METADATA,
                "device_identifiers": group_boards,
            }
        ],
    }
    if any(not value for value in (inputs["asahi_installer_tag"],
                                   inputs["asahi_installer_revision"],
                                   inputs["asahi_installer_data_revision"],
                                   inputs["downstream_revision"])):
        raise SystemExit("Engine/source-lock.json is missing the pin fields the "
                         "catalog inputs need; the engine pin is not ready")
    return inputs


def engine_validate(output: Path, package_name: str) -> None:
    """Run the engine's own package admission on what we just wrote.

    Uses the same stand-ins for the pinned engine modules the repository's
    tests use (image-builder/test/test_engine_contract.py); the validator
    itself is Engine/overlay/src/omarchy_asahi.py, unmodified.
    """
    from types import SimpleNamespace

    def psize(value: str):
        """asahi-installer v0.9.2 src/util.py psize, without alignment."""
        value = value.upper().replace(" ", "")
        base = 1000
        if value[-2] == "I":
            base = 1024
            value = value[:-2] + value[-1]
        for suffix, power in {"TB": 4, "GB": 3, "MB": 2, "KB": 1, "B": 0, "": 0}.items():
            if value.endswith(suffix):
                return int(float(value[: -len(suffix)]) * (base ** power))
        return None

    class OSInstaller:
        def __init__(self, dutil, data, template):
            self.template = template

        @property
        def min_size(self):
            return sum(-(-psize(p["size"]) // (1 << 20) << 20) for p in self.template["partitions"])

        @property
        def min_recommended_size(self):
            expandable = any(p.get("expand", False) for p in self.template["partitions"])
            return self.min_size * 2 if expandable else self.min_size

    sys.modules.setdefault("asahi_firmware", SimpleNamespace(core=SimpleNamespace(FWPackage=object)))
    sys.modules.setdefault("osinstall", SimpleNamespace(OSInstaller=OSInstaller, psize=psize))
    sys.modules.setdefault("stub", SimpleNamespace(StubInstaller=object))
    sys.modules.setdefault("util", SimpleNamespace(align_down=lambda value, align: value - value % align))
    sys.path.insert(0, str(HERE.parent / "Engine" / "overlay" / "src"))
    import omarchy_asahi  # noqa: E402

    metadata_path = output / "installer_data.json"
    payload_path = output / package_name
    metadata = omarchy_asahi.load_metadata(metadata_path)
    template = metadata["os_list"][0]
    adapter = omarchy_asahi.AsahiStage1Adapter(
        installer=SimpleNamespace(sysinfo=SimpleNamespace(device_class="")),
        metadata_path=metadata_path,
        payload_path=payload_path,
        stub_size=0,
    )
    adapter.template = template
    adapter.use_helper_recovery = template.get("recovery_gui") is None
    with zipfile.ZipFile(payload_path) as pkg:
        adapter.osins = SimpleNamespace(pkg=pkg)
        adapter._validate_full_os_package()
        members = sorted(m.filename for m in pkg.infolist() if not m.is_dir())
        device_class = json.loads(metadata_path.read_text())["os_list"][0][
            "allowed_device_classes"
        ][0]
        esp = [m for m in members if m.startswith("esp/")]
        # The install-time ESP layout and Stage 1 selection for this board,
        # exactly as preflight and install_stub_and_esp run them.
        common = "esp/aurora/stage1.bin" in esp and omarchy_asahi.common_stage1_allowed(
            template, device_class, args_os_firmware(template)
        )
        layout = omarchy_asahi.esp_board_layout(device_class, esp, common_allowed=common)
        stage2_target = layout.get("esp/m1n1/boot.bin")
        assert stage2_target == "m1n1/boot.bin", stage2_target
        stage1 = omarchy_asahi.board_stage1(
            device_class, args_os_firmware(template), esp, common_allowed=common
        )
        if "esp/aurora/stage1.bin" in esp:
            image = pkg.read("esp/aurora/stage1.bin")
            omarchy_asahi.fill_aurora_stage1(
                image, omarchy_asahi.PLACEHOLDER_UUID, template["next_object"],
                stage1.window_ms if stage1 else 0,
            )
    expected = sum(1 for m in members if m.startswith("esp/"))
    print(f"engine_validation=pass members={len(members)} esp_members={expected} "
          f"stage1_boot_object={'yes' if stage1 else 'no (stub keeps IPSW m1n1)'}")


def args_os_firmware(template: dict) -> str:
    return template["supported_fw"][0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--stage2", required=True, type=Path,
                        help="probe m1n1 Stage 2 binary (becomes esp/m1n1/boot.bin)")
    parser.add_argument("--stage1", type=Path, default=None,
                        help="probe m1n1 Stage 1 image (becomes esp/aurora/stage1.bin)")
    parser.add_argument("--bootaa64", required=True, type=Path,
                        help="ESP loader member for esp/EFI/BOOT/BOOTAA64.EFI (inert in this package, engine-required)")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--device-class", default="j575dap")
    parser.add_argument("--device-identifier", default="apple,j575d")
    parser.add_argument("--os-firmware", default="27.0.1")
    parser.add_argument("--image-mib", type=int, default=DEFAULT_IMAGE_MIB)
    parser.add_argument("--name", default="Omarchy Probe (M3 Ultra)")
    parser.add_argument("--package-name", default=None)
    parser.add_argument("--downstream-revision", default=None,
                        help="downstream overlay source revision for the catalog inputs "
                             "(default: this checkout's HEAD)")
    parser.add_argument("--catalog-baseline-payload", type=Path, default=None,
                        help="release payload the main catalog group pins for the "
                             "other supported Macs (required for catalog inputs)")
    parser.add_argument("--catalog-baseline-metadata", type=Path,
                        default=Path("installer_data.json"),
                        help="the baseline payload's installer_data.json")
    args = parser.parse_args()

    if not args.package_name:
        board = args.device_class.removesuffix("ap")
        args.package_name = f"omarchy-probe-{board}-os-package.zip"
    for label, path in (("stage2", args.stage2), ("bootaa64", args.bootaa64),
                        ("stage1", args.stage1)):
        if path is not None and (not path.is_file() or path.is_symlink()):
            raise SystemExit(f"--{label} is not a regular file: {path}")
    if not ICON.is_file():
        raise SystemExit(f"missing icon: {ICON}")
    stage2 = args.stage2.read_bytes()
    bootaa64 = args.bootaa64.read_bytes()
    image = placeholder_image(args.image_mib << 20)
    stage1 = args.stage1.read_bytes() if args.stage1 else None

    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    payload_path = output / args.package_name
    members = [
        zip_member("boot.img", image),
        zip_member("root.img", image),
        zip_member("esp/m1n1/boot.bin", stage2),
        zip_member("esp/EFI/BOOT/BOOTAA64.EFI", bootaa64),
        zip_member(ICON_NAME, ICON.read_bytes()),
    ]
    if stage1 is not None:
        members.append(zip_member("esp/aurora/stage1.bin", stage1))
    with zipfile.ZipFile(payload_path, "w") as pkg:
        for info, data in members:
            pkg.writestr(info, data)

    metadata = build_metadata(args, args.package_name, len(image))
    metadata_path = output / "installer_data.json"
    metadata_path.write_text(json.dumps(metadata, indent=1) + "\n")
    # The engine refuses metadata writable by group or others.
    os.chmod(metadata_path, 0o644)
    # The same document under the developer group's name, for the assets dir
    # that also holds the baseline metadata.
    group_metadata_path = output / GROUP_METADATA
    group_metadata_path.write_text(metadata_path.read_text())
    os.chmod(group_metadata_path, 0o644)

    inputs = build_catalog_inputs(args, args.package_name)
    (output / "catalog-inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")

    print(f"package={payload_path}")
    print(f"package_sha256={digest(payload_path)}")
    print(f"package_size={payload_path.stat().st_size}")
    print(f"metadata={metadata_path}")
    print(f"metadata_sha256={digest(metadata_path)}")
    partition_bytes = EFI_SIZE + 2 * len(image)
    mib_floor = -(-partition_bytes // (1 << 20))
    print(f"partition_floor_bytes={partition_bytes} ({mib_floor} MiB; "
          f"admission needs stub_size + this)")
    print(f"boot.img={len(image)} root.img={len(image)} "
          f"stage2={len(stage2)} bootaa64={len(bootaa64)} "
          f"stage1={len(stage1) if stage1 is not None else 0}")
    engine_validate(output, args.package_name)


if __name__ == "__main__":
    main()

#!/bin/bash
# Full probe-chain rebuild on this build host. Run from the build directory:
#   bash rebuild.sh STAGE1_BIN STAGE2_BIN
# STAGE1_BIN/STAGE2_BIN are the m1n1 Stage 1/2 binaries for the probe
# (paths on the build host; the caller rsyncs fresh binaries in before invoking).
# Produces: pkg/, assets/ refresh, re-signed catalog, app-final-r4/, the
# tester .pkg, the macos-private-package test result, and the tester bundle
# zip + SHA256SUMS. Everything under ~15 GB. Each step's seconds go to
# timings.txt and stdout.
set -euo pipefail
(( $# == 2 )) || { echo 'usage: rebuild.sh STAGE1_BIN STAGE2_BIN' >&2; exit 64; }
b="$HOME/code/probe-build-20261025"
board="${BOARD:-j575d}"
case $board in
  j575d) device_class=j575dap; device_identifier=apple,j575d; probe_name="Omarchy Probe (M3 Ultra)"; tester_pkg=${tester_pkg}; gate_board=j575d ;;
  j873g) device_class=j873gap; device_identifier=apple,j873g; probe_name="Omarchy Probe (M6)"; tester_pkg=omarchy-probe-j873g-tester.pkg; gate_board=j873g ;;
  *) echo "unknown board: $board" >&2; exit 64 ;;
esac
export board device_class device_identifier probe_name tester_pkg gate_board
export EVIDENCE_LEAF="probe-${board}-2026.10.25"
cd "$b"
stage1=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
stage2=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
[[ -f $stage1 && -f $stage2 ]] || { echo 'stage binaries missing' >&2; exit 64; }
[[ -f repo/image-builder/probe-package.py ]] || { echo 'repo not synced' >&2; exit 64; }
[[ -f keys/probe-trust-root.key && -f keys/probe-trust-root.pub ]] || { echo 'probe key missing' >&2; exit 64; }
[[ -f release-inputs/trust-root.ed25519.pub && -f release-inputs/release.json ]] || { echo 'release inputs missing' >&2; exit 64; }
[[ -d tester && -f tester/manifest.json ]] || { echo 'tester dir not synced (rsync it from the lane host first)' >&2; exit 64; }
[[ -f .downstream-revision ]] || { printf '%s\n' "507581fcb87c3e177908ea48a8124a7499392b4b" > .downstream-revision; }
rev=$(cat .downstream-revision)
: > timings.txt
total0=$(date +%s)

t() { local name=$1 shift_secs; shift; local t0=$(date +%s); "$@"; local rc=$?; local t1=$(date +%s)
  printf '%-28s %ss\n' "$name" "$((t1 - t0))" | tee -a timings.txt
  if (( rc != 0 )); then printf '%-28s FAILED rc=%s\n' "$name" "$rc" | tee -a timings.txt; exit $rc; fi; }

t probe-package bash -c "cd repo && python3 image-builder/probe-package.py \
  --stage2 '$stage2' --stage1 '$stage1' --bootaa64 ../BOOTAA64.EFI --output ../pkg \
  --catalog-baseline-payload ../assets/edge-payload.zip \
  --catalog-baseline-metadata ../assets/installer_data.json \
  --downstream-revision '$rev' --device-class "$device_class" \
  --device-identifier "$device_identifier" --name "$probe_name" > ../pkg-build.log 2>&1"

t restage-assets bash -c "cp pkg/omarchy-probe-${board}-os-package.zip pkg/probe-installer_data.json assets/"

t derive-pins python3 - <<'PYPINS'
import hashlib, os, re
b = os.path.expanduser("~/code/probe-build-20261025")
pins = {
    "installer-v0.9.2-omarchy.20261025.17e0d750eb6b.tar.gz": os.path.join(b, "assets", "installer-v0.9.2-omarchy.20261025.17e0d750eb6b.tar.gz"),
    "probe-installer_data.json": os.path.join(b, "assets", "probe-installer_data.json"),
    "omarchy-probe-%s-os-package.zip" % os.environ["board"]: os.path.join(b, "pkg", "omarchy-probe-%s-os-package.zip" % os.environ["board"]),
}
def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()
lines = "".join(f"{sha(p)} {os.path.getsize(p)} {n}\n" for n, p in pins.items())
stage = os.path.join(b, "tester", "Stage assets.command")
text = open(stage).read()
text = text.replace("probe-j575d-2026.10.25", os.environ["EVIDENCE_LEAF"])
text = re.sub(r"(<<'PINS'\n).*?(\nPINS\n)", lambda m: m.group(1) + lines + "PINS\n", text, flags=re.S)
open(stage, "w").write(text)
print("pins derived:", lines.splitlines())
PYPINS

t catalog bash -c "cd repo && python3 scripts/make-unsigned-catalog.py --developer \
  --base-url https://mac.omarchy.org/v1/releases/probe-${board}-2026.10.25 \
  --assets-dir ../assets --inputs ../pkg/catalog-inputs.json \
  --output ../assets/probe-catalog-unsigned.json > ../catalog.log 2>&1"

t sign bash -c "./catalog-signing sign keys/probe-trust-root.key assets/probe-catalog-unsigned.json release-inputs/catalog.json.sig && \
  ./catalog-signing verify keys/probe-trust-root.pub assets/probe-catalog-unsigned.json release-inputs/catalog.json.sig && \
  cp assets/probe-catalog-unsigned.json release-inputs/catalog.json"

t stage-engine bash -c "mkdir -p repo/Engine/artifacts && cp assets/installer-v0.9.2-omarchy.20261025.17e0d750eb6b.tar.gz repo/Engine/artifacts/"

t app bash -c "rm -rf '$b/app-final-r4' && cd repo && OMARCHY_PRIVATE_PLAIN_TEST=1 OMARCHY_APP_VERSION=2.3.0 \
  OMARCHY_APP_BUILD_NUMBER=\$(date -u +%y%m%d%H%M) bash Packaging/private-test/build-adhoc-app.sh \
  $b/release-inputs \
  $b/app-final-r4 > ../app-build.log 2>&1"

t narrow-preinstall bash <<'NARROW'
set -euo pipefail
cd repo
sed -i.bak 's/j433|j434|j504|j613|j615|j514s|j514c|j514m|j516s|j516c|j516m|j575d/$gate_board/' Packaging/private-test/scripts/preinstall
python3 - <<'PYGATE'
gate = """ver_ge() {
  local IFS=.
  local -a a=($1) b=($2)
  local i
  for i in 0 1 2; do
    (( ${a[i]:-0} > ${b[i]:-0} )) && return 0
    (( ${a[i]:-0} < ${b[i]:-0} )) && return 1
  done
  return 0
}
ver_ge "$version" "27.0.1" || { echo 'This probe needs macOS 27.0.1 or later: update to 27.0.1 first.' >&2; exit 1; }"""
anchor = "[[ $major =~ ^[0-9]+$ ]] && (( major >= 15 )) || { echo 'macOS 15 or later is required.' >&2; exit 1; }"
path = 'Packaging/private-test/scripts/preinstall'
src = open(path).read()
if '27.0.1 first' not in src:
    assert anchor in src, 'preinstall version anchor missing'
    src = src.replace(anchor, anchor + '\n' + gate)
    open(path, 'w').write(src)
PYGATE
bash -n Packaging/private-test/scripts/preinstall && rm -f Packaging/private-test/scripts/preinstall.bak
NARROW

t tester-pkg bash -c "cd repo && rm -f ../${tester_pkg} && bash Packaging/private-test/build-tester-pkg.sh \
  '$b/app-final-r4/Omarchy Installer.app' \
  $b/${tester_pkg} > ../pkg-build.log 2>&1"

t package-test bash -c "cd repo && bash test/macos-private-package.sh \
  '$b/app-final-r4/Omarchy Installer.app' \
  $b/${tester_pkg} > ../package-test.log 2>&1 && tail -1 ../package-test.log"

t bundle python3 - <<'PYBUNDLE'
import hashlib, json, os, shutil, zipfile
b = os.path.expanduser("~/code/probe-build-20261025")
tester = os.path.join(b, "tester")
shutil.copy2(os.path.join(b, "${tester_pkg}"), os.path.join(tester, "${tester_pkg}"))
payload_name = "omarchy-probe-%s-os-package.zip" % os.environ["board"]
for name in (payload_name, "probe-installer_data.json"):
    shutil.copy2(os.path.join(b, "assets", name), os.path.join(tester, "probe-assets", name))
files = ["${tester_pkg}",
         "probe-assets/installer-v0.9.2-omarchy.20261025.17e0d750eb6b.tar.gz",
         "probe-assets/probe-installer_data.json", "probe-assets/omarchy-probe-${board}-os-package.zip",
         "Preflight.command", "Stage assets.command", "Remove helper.command",
         "README.md", "Feedback.md"]
def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()
manifest = {
  "bundle": "omarchy probe test, Mac Studio (M3 Ultra, j575dap)",
  "installs": "loader-chain diagnostic only: the Mac boots into the m1n1 USB proxy and never boots any OS",
  "admitted_hardware": ["j575d"],
  "package": "${tester_pkg}",
  "staged_assets": {
    "engine": "probe-assets/installer-v0.9.2-omarchy.20261025.17e0d750eb6b.tar.gz",
    "metadata": "probe-assets/probe-installer_data.json",
    "payload": "probe-assets/omarchy-probe-${board}-os-package.zip"},
  "probe_kit": {"name": "omarchy-m3-ultra-probe-kit.zip", "delivered_separately": True,
                "note": "see the separate kit sha256 line"},
  "sealed_catalog_sha256": sha(os.path.join(b, "release-inputs", "catalog.json")),
  "trust_root_fingerprint": "sha256:" + sha(os.path.join(b, "release-inputs", "trust-root.ed25519.pub")),
  "files": {f: {"bytes": os.path.getsize(os.path.join(tester, f)), "sha256": sha(os.path.join(tester, f))} for f in files},
}
with open(os.path.join(tester, "manifest.json"), "w") as out:
    out.write(json.dumps(manifest, indent=2) + "\n")
with open(os.path.join(tester, "SHA256SUMS"), "w") as out:
    for f in files:
        out.write(sha(os.path.join(tester, f)) + "  " + f + "\n")
zpath = os.path.join(b, "omarchy-probe-j575d-tester-bundle.zip")
if os.path.exists(zpath):
    os.unlink(zpath)
with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, names in os.walk(os.path.join(b, "tester")):
        for n in sorted(names):
            p = os.path.join(root, n)
            z.write(p, os.path.relpath(p, b))
print("bundle=" + zpath)
print("bundle_sha256=" + sha(zpath))
print("bundle_bytes=" + str(os.path.getsize(zpath)))
PYBUNDLE

t bundle-pin-check python3 - <<'PYCHECK'
import hashlib, os, re, shutil, subprocess, sys, tempfile, zipfile
b = os.path.expanduser("~/code/probe-build-20261025")
zpath = os.path.join(b, "omarchy-probe-j575d-tester-bundle.zip")
work = tempfile.mkdtemp(prefix="bundle-check-")
with zipfile.ZipFile(zpath) as z:
    z.extractall(work)
extracted = os.path.join(work, "tester")
def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()
# 1. every pin in the extracted Stage assets must match the shipped file.
stage = open(os.path.join(extracted, "Stage assets.command")).read()
pins = re.findall(r"^([0-9a-f]{64}) (\d+) (\S+)$", stage.split("<<'PINS'\n", 1)[1].split("\nPINS\n", 1)[0], re.M)
assert pins, "no pins found"
for digest, size, name in pins:
    path = os.path.join(extracted, "probe-assets", name)
    assert os.path.getsize(path) == int(size), f"size pin mismatch: {name}"
    assert sha(path) == digest, f"sha pin mismatch: {name}"
print(f"pin-check: {len(pins)} pins match the shipped files")
# 2. SHA256SUMS in the bundle must match the extracted files.
for line in open(os.path.join(extracted, "SHA256SUMS")):
    digest, name = line.rstrip("\n").split("  ", 1)
    assert sha(os.path.join(extracted, name)) == digest, f"SHA256SUMS mismatch: {name}"
print("sha256sums-check: all entries match")
# 3. the staging function must finish against the extracted bundle in a temp HOME.
home = tempfile.mkdtemp(prefix="stage-home-")
env = dict(os.environ, OMARCHY_STAGE_SOURCE_ONLY="1", HOME=home)
script = os.path.join(extracted, "Stage assets.command")
subprocess.run(
    ["bash", "-c", 'set -euo pipefail; source "$1"; stage_bundle "$2" "$3"',
     "_", script, extracted, home],
    check=True, env=env,
)
staged = os.path.join(home, "Library", "Application Support",
                      "org.omarchy.installer.private-m3-20260922", "staging",
                      "probe-${board}-2026.10.25")
staged_files = sorted(os.listdir(staged))
assert len(staged_files) == 3, staged_files
print("stage_bundle-run: OK ->", staged_files)
shutil.rmtree(work)
PYCHECK

total1=$(date +%s)
printf '%-28s %ss\n' TOTAL "$((total1 - total0))" | tee -a timings.txt
cat timings.txt
echo "probe kit (unchanged by this script): $(shasum -a 256 ~/code/probe-build-20261025/kit/omarchy-m3-ultra-probe-kit.zip 2>/dev/null || echo 'not on this host')"

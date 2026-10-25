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
  printf '%-28s %ss\n' "$name" "$((t1 - t0))" | tee -a timings.txt; return $rc; }

t probe-package bash -c "cd repo && python3 image-builder/probe-package.py \
  --stage2 '$stage2' --stage1 '$stage1' --bootaa64 ../BOOTAA64.EFI --output ../pkg \
  --catalog-baseline-payload ../assets/edge-payload.zip \
  --catalog-baseline-metadata ../assets/installer_data.json \
  --downstream-revision '$rev' > ../pkg-build.log 2>&1"

t restage-assets bash -c "cp pkg/omarchy-probe-j575d-os-package.zip pkg/probe-installer_data.json assets/"

t catalog bash -c "cd repo && python3 scripts/make-unsigned-catalog.py --developer \
  --base-url https://mac.omarchy.org/v1/releases/probe-j575d-2026.10.25 \
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

t narrow-preinstall bash -c "cd repo && sed -i.bak 's/j433|j434|j504|j613|j615|j514s|j514c|j514m|j516s|j516c|j516m|j575d/j575d/' Packaging/private-test/scripts/preinstall && bash -n Packaging/private-test/scripts/preinstall && rm -f Packaging/private-test/scripts/preinstall.bak"

t tester-pkg bash -c "cd repo && rm -f ../omarchy-probe-j575d-tester.pkg && bash Packaging/private-test/build-tester-pkg.sh \
  '$b/app-final-r4/Omarchy Installer.app' \
  $b/omarchy-probe-j575d-tester.pkg > ../pkg-build.log 2>&1"

t package-test bash -c "cd repo && bash test/macos-private-package.sh \
  '$b/app-final-r4/Omarchy Installer.app' \
  $b/omarchy-probe-j575d-tester.pkg > ../package-test.log 2>&1 && tail -1 ../package-test.log"

t bundle python3 - <<'PYBUNDLE'
import hashlib, json, os, shutil, zipfile
b = os.path.expanduser("~/code/probe-build-20261025")
tester = os.path.join(b, "tester")
shutil.copy2(os.path.join(b, "omarchy-probe-j575d-tester.pkg"), os.path.join(tester, "omarchy-probe-j575d-tester.pkg"))
for name in ("omarchy-probe-j575d-os-package.zip", "probe-installer_data.json"):
    shutil.copy2(os.path.join(b, "assets", name), os.path.join(tester, "probe-assets", name))
files = ["omarchy-probe-j575d-tester.pkg",
         "probe-assets/installer-v0.9.2-omarchy.20261025.17e0d750eb6b.tar.gz",
         "probe-assets/probe-installer_data.json", "probe-assets/omarchy-probe-j575d-os-package.zip",
         "Preflight.command", "Stage assets.command", "Remove helper.command",
         "Remove everything.command", "README.md", "Feedback.md", "manifest.json"]
def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()
manifest = {
  "bundle": "omarchy probe test, Mac Studio (M3 Ultra, j575dap), dry-run build",
  "installs": "loader-chain diagnostic only: the Mac boots into the m1n1 USB proxy and never boots any OS",
  "admitted_hardware": ["j575d"],
  "package": "omarchy-probe-j575d-tester.pkg",
  "staged_assets": {
    "engine": "probe-assets/installer-v0.9.2-omarchy.20261025.17e0d750eb6b.tar.gz",
    "metadata": "probe-assets/probe-installer_data.json",
    "payload": "probe-assets/omarchy-probe-j575d-os-package.zip"},
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

total1=$(date +%s)
printf '%-28s %ss\n' TOTAL "$((total1 - total0))" | tee -a timings.txt
cat timings.txt
echo "probe kit (unchanged by this script): $(shasum -a 256 ~/code/probe-build-20261025/kit/omarchy-m3-ultra-probe-kit.zip 2>/dev/null || echo 'not on this host')"

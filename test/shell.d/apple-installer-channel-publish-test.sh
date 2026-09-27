#!/bin/bash

source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/Packaging/identity.conf"

require_command python3

PUBLISHER="$ROOT/scripts/publish-channels"
[[ -f $PUBLISHER ]] || fail "publish-channels exists"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

BUCKET_DIR="$WORK/bucket"
# Everything the publisher owns lives under the stream path; the bucket root
# holds the MX Mac feeds, which it must never touch.
STREAM_DIR="$BUCKET_DIR/$INSTALLER_STREAM_PATH"
BIN_DIR="$WORK/bin"
CALLS="$WORK/calls.log"
mkdir -p "$BUCKET_DIR" "$BIN_DIR"
: >"$CALLS"

# A bucket-backed aws shim: object keys become paths, so a test can assert both
# what was written and which flags were used.
cat >"$BIN_DIR/aws" <<'SHIM'
#!/bin/bash
printf 'aws %s\n' "$*" >>"$CALLS"
bucket_root=$BUCKET_DIR
if [[ $1 == "s3api" && $2 == "head-object" ]]; then
  key=""
  while (( $# > 0 )); do
    [[ $1 == "--key" ]] && key=$2
    shift
  done
  [[ -f $bucket_root/$key ]] || exit 254
  wc -c <"$bucket_root/$key" | tr -d ' '
  exit 0
fi
if [[ $1 == "s3" && $2 == "cp" ]]; then
  source_path=$3
  destination=$4
  key=${destination#s3://*/}
  mkdir -p "$bucket_root/$(dirname "$key")"
  cp "$source_path" "$bucket_root/$key"
  exit 0
fi
if [[ $1 == "s3" && $2 == "ls" ]]; then
  prefix=${3#s3://*/}
  ( cd "$bucket_root" && find "${prefix:-.}" -type f 2>/dev/null | sed -e "s|^\./||" -e "s|//*|/|g" ) | while read -r rel; do
    printf "2026-09-05 00:00:00 %10d %s\n" "$(wc -c <"$bucket_root/$rel" | tr -d " ")" "$rel"
  done
  exit 0
fi
if [[ $1 == "s3api" && $2 == "get-object-lock-configuration" ]]; then
  if [[ -f $BUCKET_LOCKED ]]; then
    echo '{"ObjectLockConfiguration":{"ObjectLockEnabled":"Enabled"}}'
    exit 0
  fi
  echo "An error occurred (ObjectLockConfigurationNotFoundError) when calling the GetObjectLockConfiguration operation" >&2
  exit 1
fi
if [[ $1 == "s3" && $2 == "rm" ]]; then
  prefix=${3#s3://*/}
  if [[ -f $BUCKET_LOCKED && $prefix == releases/* ]]; then
    echo "delete failed: s3://x/$prefix An error occurred (ObjectLockedByBucketPolicy) when calling the DeleteObject operation: The object is locked by the bucket policy." >&2
    exit 1
  fi
  rm -rf "${bucket_root:?}/${prefix%/}"
  exit 0
fi
exit 0
SHIM

# curl serves the same fake bucket, so a publish is verified back through the
# public path exactly as it would be in production.
cat >"$BIN_DIR/curl" <<'SHIM'
#!/bin/bash
printf 'curl %s\n' "$*" >>"$CALLS"
output=""
head_only=0
write_out=""
url=""
while (( $# > 0 )); do
  case $1 in
    -o) output=$2; shift 2 ;;
    -w) write_out=$2; shift 2 ;;
    -H) shift 2 ;;
    -fsSLI) head_only=1; shift ;;
    -fsSL) shift ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
path=${url#*://*/}
file=$BUCKET_DIR/$path
if [[ ! -f $file ]]; then
  [[ -n $write_out ]] && printf '404'
  exit 22
fi
if (( head_only )); then
  printf 'HTTP/2 200\r\ncontent-length: %s\r\n\r\n' "$(wc -c <"$file" | tr -d ' ')"
  exit 0
fi
if [[ -n $output ]]; then
  cp "$file" "$output"
else
  cat "$file"
fi
[[ -n $write_out ]] && printf '200'
exit 0
SHIM

cat >"$BIN_DIR/pkgutil" <<'SHIM'
#!/bin/bash
printf 'pkgutil %s\n' "$*" >>"$CALLS"
exit 0
SHIM

cat >"$BIN_DIR/xcrun" <<'SHIM'
#!/bin/bash
printf 'xcrun %s\n' "$*" >>"$CALLS"
if [[ $1 == "stapler" ]]; then
  [[ -f $STAPLE_FAILS ]] && exit 1
  exit 0
fi
exit 0
SHIM

# The publisher is a macOS tool and digests with shasum. Provide it where only
# coreutils is present, so this stays runnable on the Linux test hosts.
if ! command -v shasum >/dev/null; then
  cat >"$BIN_DIR/shasum" <<'SHIM'
#!/bin/bash
file=""
while (( $# > 0 )); do
  case $1 in
    -a) shift 2 ;;
    *) file=$1; shift ;;
  esac
done
sha256sum "$file"
SHIM
fi

chmod +x "$BIN_DIR"/*
export PATH="$BIN_DIR:$PATH"
export BUCKET_DIR CALLS
export STAPLE_FAILS="$WORK/staple-fails"
export BUCKET_LOCKED="$WORK/bucket-locked"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
export OMARCHY_R2_BUCKET=test-bucket
export OMARCHY_R2_ENDPOINT=https://example.r2.cloudflarestorage.com
export OMARCHY_PUBLIC_BASE=https://downloads.example.test
export OMARCHY_TRUST_ROOT="$WORK/trust-root.pub"
export OMARCHY_CATALOG_SIGNING_TOOL="$BIN_DIR/signing-tool"

# A stand-in for the Ed25519 tool: a signature is the catalog digest, which is
# enough to prove the publisher refuses content whose signature does not match.
cat >"$BIN_DIR/signing-tool" <<'SHIM'
#!/bin/bash
if [[ $1 == "verify" ]]; then
  expected=$(shasum -a 256 "$3" | cut -d' ' -f1)
  actual=$(cat "$4")
  [[ $expected == "$actual" ]] || exit 1
  echo "catalog_signature=passed"
  exit 0
fi
exit 64
SHIM
chmod +x "$BIN_DIR/signing-tool"
printf 'trust root' >"$OMARCHY_TRUST_ROOT"

sign_catalog() {
  # 64 hexadecimal characters, which is also the 64 bytes the envelope
  # builder requires.
  shasum -a 256 "$1" | cut -d' ' -f1 | tr -d '\n' >"$2"
}

write_catalog() {
  local output=$1 sequence=$2 payload_url=$3 payload_size=$4
  python3 - "$output" "$sequence" "$payload_url" "$payload_size" <<'PY'
import json
import sys

output, sequence, payload_url, payload_size = sys.argv[1:5]
catalog = {
    "schemaVersion": 4,
    "sequence": int(sequence),
    "issuedAt": "2026-09-04T00:00:00Z",
    "models": [
        {
            "deviceIdentifier": "apple,j314s",
            "status": "enabled",
            "payloadArtifact": {
                "sourceURL": payload_url,
                "fileName": "payload.zip",
                "sizeBytes": int(payload_size),
            },
        }
    ],
}
with open(output, "w", encoding="utf-8") as stream:
    json.dump(catalog, stream, indent=2)
PY
}

publish_candidate() {
  local tag=$1 sequence=$2 payload_url=$3 payload_size=$4
  local catalog="$WORK/$tag.catalog" signature="$WORK/$tag.sig"
  write_catalog "$catalog" "$sequence" "$payload_url" "$payload_size"
  sign_catalog "$catalog" "$signature"
  mkdir -p "$STREAM_DIR/releases/$tag"
  "$PUBLISHER" envelope --catalog "$catalog" --signature "$signature" \
    --output "$STREAM_DIR/releases/$tag/catalog.signed.json" >/dev/null
}

stage_payload() {
  local tag=$1 size=$2
  mkdir -p "$STREAM_DIR/releases/$tag"
  head -c "$size" /dev/zero >"$STREAM_DIR/releases/$tag/payload.zip"
}

BASE="https://downloads.example.test/$INSTALLER_STREAM_PATH"

# The MX Mac feeds at the bucket root, as live today: a channel, its release
# set and the MX installer download. Nothing below may change them.
mx_tag=os-v4.0.4-mac.1.20260924-rc
mkdir -p "$BUCKET_DIR/channels/stable" "$BUCKET_DIR/releases/$mx_tag" \
  "$BUCKET_DIR/installer/stable" "$BUCKET_DIR/installer/2.0.10"
printf 'mx stable catalog' >"$BUCKET_DIR/channels/stable/catalog.signed.json"
printf '{"schema_version":1,"channel":"stable","os_tag":"%s"}\n' "$mx_tag" >"$BUCKET_DIR/channels/stable/channel.json"
head -c 64 /dev/zero >"$BUCKET_DIR/releases/$mx_tag/payload.zip"
printf '{"version":"2.0.10"}\n' >"$BUCKET_DIR/installer/stable/installer.json"
head -c 64 /dev/zero >"$BUCKET_DIR/installer/2.0.10/$INSTALLER_FILE_STEM-2.0.10.pkg"
root_digest() {
  ( cd "$BUCKET_DIR" && find . -type f -not -path "./$INSTALLER_STREAM_PATH/*" -print0 | sort -z |
    xargs -0 shasum -a 256 ) | shasum | cut -d" " -f1
}
MX_ROOT_DIGEST=$(root_digest)

# --- the envelope carries the catalog and its signature together ------------
stage_payload "os-v4.0.2-mac.1.20260902" 128
publish_candidate "os-v4.0.2-mac.1.20260902" 100 "$BASE/releases/os-v4.0.2-mac.1.20260902/payload.zip" 128
[[ -f $STREAM_DIR/releases/os-v4.0.2-mac.1.20260902/catalog.signed.json ]] ||
  fail "envelope is written"
python3 -c '
import base64, json, sys
d = json.load(open(sys.argv[1]))
assert set(d) == {"schema_version", "catalog", "signature"}, d.keys()
assert d["schema_version"] == 1
json.loads(base64.b64decode(d["catalog"]))
' "$STREAM_DIR/releases/os-v4.0.2-mac.1.20260902/catalog.signed.json" ||
  fail "envelope decodes to a catalog and a signature"
pass "an envelope holds the catalog and its signature in one object"

# --- promotion writes both channel objects and verifies them back -----------
OMARCHY_PUBLISH_ASSUME_YES=os-v4.0.2-mac.1.20260902 "$PUBLISHER" os-promote --tag os-v4.0.2-mac.1.20260902 --to stable \
  >"$WORK/promote.log" 2>&1 || fail "first promotion succeeds" "$(cat "$WORK/promote.log")"
[[ -f $STREAM_DIR/channels/stable/catalog.signed.json ]] ||
  fail "the stable catalog is published"
[[ -f $STREAM_DIR/channels/stable/channel.json ]] ||
  fail "the stable channel pointer is published"
grep -q "channel_sequence=100" "$WORK/promote.log" ||
  fail "promotion reports the sequence" "$(cat "$WORK/promote.log")"
pass "promotion publishes the channel and reads it back"

grep -q -- "--cache-control no-cache, max-age=0, must-revalidate" "$CALLS" ||
  fail "channel objects are uploaded with no-cache" "$(grep '^aws s3 cp' "$CALLS")"
pass "channel objects carry a no-cache header"

# --- re-promoting identical bytes changes nothing ---------------------------
: >"$CALLS"
OMARCHY_PUBLISH_ASSUME_YES=os-v4.0.2-mac.1.20260902 "$PUBLISHER" os-promote --tag os-v4.0.2-mac.1.20260902 --to stable \
  >"$WORK/repromote.log" 2>&1 || fail "re-promotion succeeds"
grep -q "already serves these exact bytes" "$WORK/repromote.log" ||
  fail "an identical promotion is a no-op" "$(cat "$WORK/repromote.log")"
grep -q "^aws s3 cp" "$CALLS" && fail "an identical promotion uploads nothing"
pass "promoting the same bytes twice uploads nothing"

# --- a lower sequence is refused -------------------------------------------
stage_payload "os-v4.0.2-mac.1.20260901" 128
publish_candidate "os-v4.0.2-mac.1.20260901" 50 "$BASE/releases/os-v4.0.2-mac.1.20260901/payload.zip" 128
if OMARCHY_PUBLISH_ASSUME_YES=os-v4.0.2-mac.1.20260901 "$PUBLISHER" os-promote --tag os-v4.0.2-mac.1.20260901 --to stable \
  >"$WORK/older.log" 2>&1; then
  fail "a lower sequence is refused"
fi
grep -q "does not exceed the live stable sequence" "$WORK/older.log" ||
  fail "the refusal names the sequence conflict" "$(cat "$WORK/older.log")"
pass "a catalog older than the live channel is refused"

# --- a sequence below an explicit floor is refused --------------------------
if OMARCHY_PUBLISH_ASSUME_YES=os-v4.0.2-mac.1.20260902 "$PUBLISHER" os-promote --tag os-v4.0.2-mac.1.20260902 --to rc \
  --minimum-sequence 500 >"$WORK/floor.log" 2>&1; then
  fail "a sequence below the floor is refused"
fi
grep -q "required floor 500" "$WORK/floor.log" ||
  fail "the refusal names the floor" "$(cat "$WORK/floor.log")"
pass "a catalog below the required sequence floor is refused"

# --- a broken signature is refused -----------------------------------------
stage_payload "os-v4.0.2-mac.1.20260903" 128
write_catalog "$WORK/bad.catalog" 200 "$BASE/releases/os-v4.0.2-mac.1.20260903/payload.zip" 128
printf 'not the digest' >"$WORK/bad.sig"
python3 - "$WORK/bad.catalog" "$WORK/bad.sig" \
  "$STREAM_DIR/releases/os-v4.0.2-mac.1.20260903/catalog.signed.json" <<'PY'
import base64, json, sys
catalog, signature, output = sys.argv[1:4]
json.dump(
    {
        "schema_version": 1,
        "catalog": base64.b64encode(open(catalog, "rb").read()).decode(),
        "signature": base64.b64encode(open(signature, "rb").read()).decode(),
    },
    open(output, "w"),
)
PY
if OMARCHY_PUBLISH_ASSUME_YES=os-v4.0.2-mac.1.20260903 "$PUBLISHER" os-promote --tag os-v4.0.2-mac.1.20260903 --to stable \
  >"$WORK/badsig.log" 2>&1; then
  fail "a catalog whose signature does not verify is refused"
fi
grep -q "does not verify" "$WORK/badsig.log" ||
  fail "the refusal names the signature" "$(cat "$WORK/badsig.log")"
pass "a catalog whose signature does not verify is refused"

# --- an artifact belonging to another tag is refused ------------------------
stage_payload "os-v4.0.2-mac.1.20260904" 128
publish_candidate "os-v4.0.2-mac.1.20260904" 300 "$BASE/releases/os-v4.0.2-mac.1.20260902/payload.zip" 128
if OMARCHY_PUBLISH_ASSUME_YES=os-v4.0.2-mac.1.20260904 "$PUBLISHER" os-promote --tag os-v4.0.2-mac.1.20260904 --to stable \
  >"$WORK/foreign.log" 2>&1; then
  fail "an artifact outside the tag is refused"
fi
grep -q "outside releases/os-v4.0.2-mac.1.20260904" "$WORK/foreign.log" ||
  fail "the refusal names the foreign artifact" "$(cat "$WORK/foreign.log")"
pass "a catalog naming another tag's artifacts is refused"

# --- an artifact whose size disagrees is refused ----------------------------
stage_payload "os-v4.0.2-mac.1.20260905" 64
publish_candidate "os-v4.0.2-mac.1.20260905" 400 "$BASE/releases/os-v4.0.2-mac.1.20260905/payload.zip" 128
if OMARCHY_PUBLISH_ASSUME_YES=os-v4.0.2-mac.1.20260905 "$PUBLISHER" os-promote --tag os-v4.0.2-mac.1.20260905 --to stable \
  >"$WORK/size.log" 2>&1; then
  fail "a size mismatch is refused"
fi
grep -q "catalog claims 128" "$WORK/size.log" ||
  fail "the refusal names the size conflict" "$(cat "$WORK/size.log")"
pass "a catalog whose artifact size disagrees is refused"

# --- an unpublished artifact is refused -------------------------------------
publish_candidate "os-v4.0.2-mac.1.20260906" 500 "$BASE/releases/os-v4.0.2-mac.1.20260906/missing.zip" 128
if OMARCHY_PUBLISH_ASSUME_YES=os-v4.0.2-mac.1.20260906 "$PUBLISHER" os-promote --tag os-v4.0.2-mac.1.20260906 --to stable \
  >"$WORK/missing.log" 2>&1; then
  fail "an unpublished artifact is refused"
fi
grep -q "not published" "$WORK/missing.log" ||
  fail "the refusal names the missing artifact" "$(cat "$WORK/missing.log")"
pass "a catalog naming an unpublished artifact is refused"

# --- the rc channel is independent of stable ------------------------------
stage_payload "os-v4.0.2-mac.1.20260907" 128
publish_candidate "os-v4.0.2-mac.1.20260907" 600 "$BASE/releases/os-v4.0.2-mac.1.20260907/payload.zip" 128
OMARCHY_PUBLISH_ASSUME_YES=os-v4.0.2-mac.1.20260907 "$PUBLISHER" os-promote --tag os-v4.0.2-mac.1.20260907 --to rc \
  >"$WORK/rc.log" 2>&1 || fail "rc promotion succeeds" "$(cat "$WORK/rc.log")"
stable_sequence=$(python3 -c '
import base64, json, sys
d = json.load(open(sys.argv[1]))
print(json.loads(base64.b64decode(d["catalog"]))["sequence"])
' "$STREAM_DIR/channels/stable/catalog.signed.json")
[[ $stable_sequence == "100" ]] ||
  fail "promoting rc leaves stable alone" "stable is now $stable_sequence"
pass "promoting rc does not disturb stable"

# --- the installer package publishes to an immutable key and the channel ----
PKG="$WORK/Installer.pkg"
head -c 4096 /dev/zero >"$PKG"
OMARCHY_PUBLISH_ASSUME_YES=installer-v2.0.0 "$PUBLISHER" app-publish \
  --pkg "$PKG" --version 2.0.0 >"$WORK/app.log" 2>&1 ||
  fail "app-publish succeeds" "$(cat "$WORK/app.log")"
[[ -f $STREAM_DIR/installer/2.0.0/$INSTALLER_FILE_STEM-2.0.0.pkg ]] ||
  fail "the immutable package is published"
[[ -f $STREAM_DIR/installer/stable/$INSTALLER_FILE_STEM.pkg ]] ||
  fail "the stable package is published"
[[ -f $STREAM_DIR/installer/stable/installer.json ]] ||
  fail "the installer pointer is published"
pass "the installer publishes to both an immutable key and the channel"

grep -qF -- "--content-disposition attachment; filename=\"$INSTALLER_APP_NAME.pkg\"" "$CALLS" ||
  fail "the download keeps its name" "$(grep 'content-disposition' "$CALLS")"
pass "the stable download is served under its readable name"

# --- an unstapled package never reaches the bucket --------------------------
: >"$CALLS"
touch "$STAPLE_FAILS"
if OMARCHY_PUBLISH_ASSUME_YES=installer-v2.0.1 "$PUBLISHER" app-publish \
  --pkg "$PKG" --version 2.0.1 >"$WORK/unstapled.log" 2>&1; then
  fail "an unstapled package is refused"
fi
grep -q "stapled notarization" "$WORK/unstapled.log" ||
  fail "the refusal names notarization" "$(cat "$WORK/unstapled.log")"
grep -q "^aws s3 cp" "$CALLS" && fail "an unstapled package uploads nothing"
rm -f "$STAPLE_FAILS"
pass "an unstapled package is refused before anything is uploaded"

# --- republishing the same immutable version with different bytes is refused -
head -c 8192 /dev/zero >"$WORK/Different.pkg"
if OMARCHY_PUBLISH_ASSUME_YES=installer-v2.0.0 "$PUBLISHER" app-publish \
  --pkg "$WORK/Different.pkg" --version 2.0.0 >"$WORK/clobber.log" 2>&1; then
  fail "rewriting an immutable version is refused"
fi
grep -q "publish a new version" "$WORK/clobber.log" ||
  fail "the refusal explains the immutable rule" "$(cat "$WORK/clobber.log")"
pass "an immutable installer version cannot be rewritten"

# --- a malformed OS tag never reaches the network ---------------------------
if "$PUBLISHER" os-promote --tag 4.0.2-mac.1 --to stable >"$WORK/badtag.log" 2>&1; then
  fail "a malformed OS tag is refused"
fi
grep -q "invalid OS release tag" "$WORK/badtag.log" ||
  fail "the refusal names the tag shape" "$(cat "$WORK/badtag.log")"
pass "a malformed OS release tag is refused"

# --- status reports both channels ------------------------------------------
"$PUBLISHER" channel-status --channel all >"$WORK/status.log" 2>&1 ||
  fail "channel-status succeeds" "$(cat "$WORK/status.log")"
grep -q "catalog_sequence=100" "$WORK/status.log" ||
  fail "status reports the stable sequence" "$(cat "$WORK/status.log")"
grep -q "catalog_sequence=600" "$WORK/status.log" ||
  fail "status reports the rc sequence" "$(cat "$WORK/status.log")"
grep -q "stable_equals_rc=no" "$WORK/status.log" ||
  fail "status compares the channels" "$(cat "$WORK/status.log")"
grep -q "installer_version=2.0.0" "$WORK/status.log" ||
  fail "status reports the installer version" "$(cat "$WORK/status.log")"
pass "channel-status reports both channels and whether they agree"

# --- promoting to stable prunes what it superseded ----------------------------
# Stable is on …20260902 (sequence 100). Promote …20260907 (600) to stable: the
# 20260902 set is what stable served just before, so it stays for rollback, and
# never-promoted sets go. Seed one such set first.
mkdir -p "$STREAM_DIR/releases/os-v4.0.2-mac.1.20260801" && head -c 32 /dev/zero >"$STREAM_DIR/releases/os-v4.0.2-mac.1.20260801/payload.zip"
OMARCHY_PUBLISH_ASSUME_YES=os-v4.0.2-mac.1.20260907 "$PUBLISHER" os-promote --tag os-v4.0.2-mac.1.20260907 --to stable \
  >"$WORK/promote-prune.log" 2>&1 || fail "stable promotion with prune succeeds" "$(cat "$WORK/promote-prune.log")"
grep -q "Pruning release sets" "$WORK/promote-prune.log" || fail "a stable promotion prunes afterwards" "$(cat "$WORK/promote-prune.log")"
[[ ! -d $STREAM_DIR/releases/os-v4.0.2-mac.1.20260801 ]] || fail "the superseded older set is removed"
[[ -d $STREAM_DIR/releases/os-v4.0.2-mac.1.20260902 ]] || fail "the previous stable set is kept for rollback"
[[ -d $STREAM_DIR/releases/os-v4.0.2-mac.1.20260907 ]] || fail "the newly promoted set is kept"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['previous_os_tag']=='os-v4.0.2-mac.1.20260902', d" \
  "$STREAM_DIR/channels/stable/channel.json" || fail "channel.json records what the promotion superseded"
pass "promoting to stable removes never-promoted sets and keeps what it superseded"

# --- a locked bucket does not turn a successful promotion into a failure ---
mkdir -p "$STREAM_DIR/releases/os-v4.0.2-mac.1.20260701" && head -c 32 /dev/zero >"$STREAM_DIR/releases/os-v4.0.2-mac.1.20260701/payload.zip"
touch "$BUCKET_LOCKED"
stage_payload "os-v4.0.2-mac.1.20260908" 128
publish_candidate "os-v4.0.2-mac.1.20260908" 800 "$BASE/releases/os-v4.0.2-mac.1.20260908/payload.zip" 128
OMARCHY_PUBLISH_ASSUME_YES=os-v4.0.2-mac.1.20260908 "$PUBLISHER" os-promote --tag os-v4.0.2-mac.1.20260908 --to stable \
  >"$WORK/promote-locked.log" 2>&1 || fail "promotion succeeds even when pruning is refused" "$(cat "$WORK/promote-locked.log")"
grep -q "channel_sequence=800" "$WORK/promote-locked.log" || fail "the promotion completed" "$(cat "$WORK/promote-locked.log")"
grep -q "pruning was refused" "$WORK/promote-locked.log" || fail "the refused prune is reported" "$(cat "$WORK/promote-locked.log")"
[[ -d $STREAM_DIR/releases/os-v4.0.2-mac.1.20260701 ]] || fail "a locked prune deletes nothing"
rm -f "$BUCKET_LOCKED"
# Restore the fixture state the later prune cases expect: stable back on …20260902.
rm -rf "$STREAM_DIR/releases/os-v4.0.2-mac.1.20260701" "$STREAM_DIR/releases/os-v4.0.2-mac.1.20260908"
publish_candidate "os-v4.0.2-mac.1.20260902" 100 "$BASE/releases/os-v4.0.2-mac.1.20260902/payload.zip" 128
cp "$STREAM_DIR/releases/os-v4.0.2-mac.1.20260902/catalog.signed.json" "$STREAM_DIR/channels/stable/catalog.signed.json"
pass "a bucket lock is reported after promotion, never as a failed release"

# --- prune keeps what a channel can reach and the newest spare set ----------
# Live now: stable -> os-v…20260902 (sequence 100), rc -> os-v…20260907,
# installer/stable -> 2.0.0. Everything else under releases/ and installer/<v>/
# is unreferenced.
head -c 64 /dev/zero >"$WORK/old.pkg"
mkdir -p "$STREAM_DIR/installer/1.9.0" && cp "$WORK/old.pkg" "$STREAM_DIR/installer/1.9.0/$INSTALLER_FILE_STEM-1.9.0.pkg"
mkdir -p "$STREAM_DIR/releases/4.0.1.m.1" && cp "$WORK/old.pkg" "$STREAM_DIR/releases/4.0.1.m.1/other-lane.iso"
"$PUBLISHER" prune >"$WORK/prune-dry.log" 2>&1 || fail "prune dry run succeeds" "$(cat "$WORK/prune-dry.log")"
grep -q "Dry run" "$WORK/prune-dry.log" || fail "prune is a dry run by default" "$(cat "$WORK/prune-dry.log")"
for kept in releases/os-v4.0.2-mac.1.20260902 releases/os-v4.0.2-mac.1.20260907 installer/2.0.0; do
  awk "/^Kept/,/^Delete/" "$WORK/prune-dry.log" | grep -q "$kept" || fail "prune keeps $kept" "$(cat "$WORK/prune-dry.log")"
done
awk "/^Delete/,0" "$WORK/prune-dry.log" | grep -q "installer/1.9.0" || fail "prune would delete the unreferenced installer version"
awk "/^Delete/,0" "$WORK/prune-dry.log" | grep -q "4.0.1.m.1" && fail "prune must not touch another lane's folder"
[[ -d $STREAM_DIR/installer/1.9.0 ]] || fail "a dry run deletes nothing"
pass "prune plans around what the channels reference and leaves other lanes alone"

# --- a bucket lock stops prune with one clear message ----------------------
mkdir -p "$STREAM_DIR/releases/v4.0.2-mac.1.10.090226" && cp "$WORK/old.pkg" "$STREAM_DIR/releases/v4.0.2-mac.1.10.090226/payload.zip"
touch "$BUCKET_LOCKED"
if OMARCHY_PUBLISH_ASSUME_YES=prune "$PUBLISHER" prune --confirm >"$WORK/locked.log" 2>&1; then
  fail "prune stops when the bucket lock refuses"
fi
grep -q "protected by the bucket's lock rule" "$WORK/locked.log" || fail "prune explains the lock" "$(cat "$WORK/locked.log")"
(( $(grep -c "ObjectLockedByBucketPolicy" "$WORK/locked.log") <= 1 )) || fail "prune does not repeat the refusal per object"
[[ -f $STREAM_DIR/installer/1.9.0/$INSTALLER_FILE_STEM-1.9.0.pkg ]] || fail "a locked run deletes nothing else either"
rm -f "$BUCKET_LOCKED"
rm -rf "$STREAM_DIR/releases/v4.0.2-mac.1.10.090226"
pass "prune stops at a bucket lock with one message and no partial deletion"

before=$(find "$STREAM_DIR/channels" "$STREAM_DIR/installer/stable" -type f | sort | shasum | cut -d" " -f1)
OMARCHY_PUBLISH_ASSUME_YES=prune "$PUBLISHER" prune --confirm >"$WORK/prune.log" 2>&1 ||
  fail "prune --confirm succeeds" "$(cat "$WORK/prune.log")"
[[ ! -d $STREAM_DIR/installer/1.9.0 ]] || fail "prune removes the unreferenced installer version"
[[ -d $STREAM_DIR/releases/os-v4.0.2-mac.1.20260902 ]] || fail "prune keeps the stable release set"
[[ -d $STREAM_DIR/releases/os-v4.0.2-mac.1.20260907 ]] || fail "prune keeps the rc release set"
[[ -d $STREAM_DIR/installer/2.0.0 ]] || fail "prune keeps the referenced installer version"
[[ -d $STREAM_DIR/releases/4.0.1.m.1 ]] || fail "prune leaves other lanes alone"
after=$(find "$STREAM_DIR/channels" "$STREAM_DIR/installer/stable" -type f | sort | shasum | cut -d" " -f1)
[[ $before == "$after" ]] || fail "prune never touches channel or download objects"
pass "prune deletes only unreferenced immutable sets and never a channel object"

# --- edge is a channel; the retired rc-aurora lane is not ----------------------
stage_payload "os-v4.0.2-mac.1.20260910" 128
publish_candidate "os-v4.0.2-mac.1.20260910" 900 "$BASE/releases/os-v4.0.2-mac.1.20260910/payload.zip" 128
OMARCHY_PUBLISH_ASSUME_YES=os-v4.0.2-mac.1.20260910 "$PUBLISHER" os-promote --tag os-v4.0.2-mac.1.20260910 --to edge \
  >"$WORK/edge.log" 2>&1 || fail "edge promotion succeeds" "$(cat "$WORK/edge.log")"
[[ -f $STREAM_DIR/channels/edge/catalog.signed.json ]] || fail "the edge catalog is published"
if "$PUBLISHER" os-promote --tag os-v4.0.2-mac.1.20260910 --to rc-aurora >"$WORK/aurora.log" 2>&1; then
  fail "the retired rc-aurora channel is refused"
fi
grep -q "invalid channel: rc-aurora" "$WORK/aurora.log" || fail "the refusal names the channel" "$(cat "$WORK/aurora.log")"
"$PUBLISHER" channel-status --channel edge >"$WORK/edge-status.log" 2>&1 ||
  fail "edge status succeeds" "$(cat "$WORK/edge-status.log")"
grep -q "catalog_sequence=900" "$WORK/edge-status.log" || fail "status reads edge" "$(cat "$WORK/edge-status.log")"
pass "edge publishes like any channel and rc-aurora is no channel any more"

# --- a channel with no Mac release serves a signed empty catalog --------------
"$PUBLISHER" empty-catalog --sequence 1000 --output "$WORK/empty.catalog" >"$WORK/empty.log" 2>&1 ||
  fail "empty-catalog succeeds" "$(cat "$WORK/empty.log")"
python3 -c '
import json, sys
catalog = json.load(open(sys.argv[1]))
assert set(catalog) == {"schemaVersion", "sequence", "issuedAt", "models"}, catalog
assert catalog["schemaVersion"] == 4 and catalog["sequence"] == 1000 and catalog["models"] == []
' "$WORK/empty.catalog" || fail "the empty catalog is a schema-4 catalog without models"
"$PUBLISHER" empty-catalog --sequence 1000 --output "$WORK/empty.catalog" >/dev/null 2>&1 &&
  fail "empty-catalog never overwrites"
"$PUBLISHER" empty-catalog --sequence 0 --output "$WORK/zero.catalog" >/dev/null 2>&1 &&
  fail "empty-catalog refuses a zero sequence"
"$PUBLISHER" empty-catalog --sequence $(( $(date +%s) + 86400 )) --output "$WORK/future.catalog" >/dev/null 2>&1 &&
  fail "empty-catalog refuses a sequence later than now"
before=$(date +%s)
"$PUBLISHER" empty-catalog --output "$WORK/now.catalog" >/dev/null || fail "empty-catalog defaults its sequence"
python3 -c 'import json, sys; s = json.load(open(sys.argv[1]))["sequence"]; assert int(sys.argv[2]) <= s <= int(sys.argv[2]) + 60, s' \
  "$WORK/now.catalog" "$before" || fail "the default sequence is the current Unix time"
sign_catalog "$WORK/empty.catalog" "$WORK/empty.sig"
mkdir -p "$STREAM_DIR/releases/os-v4.0.2-mac.1.20260911-empty"
"$PUBLISHER" envelope --catalog "$WORK/empty.catalog" --signature "$WORK/empty.sig" \
  --output "$STREAM_DIR/releases/os-v4.0.2-mac.1.20260911-empty/catalog.signed.json" >/dev/null ||
  fail "the empty catalog wraps into an envelope"
# Stable prunes after promotion; the empty set must survive it, or rc could
# no longer be promoted from the same tag.
OMARCHY_PUBLISH_ASSUME_YES=os-v4.0.2-mac.1.20260911-empty "$PUBLISHER" os-promote \
  --tag os-v4.0.2-mac.1.20260911-empty --to stable >"$WORK/empty-stable.log" 2>&1 ||
  fail "the empty catalog promotes to stable" "$(cat "$WORK/empty-stable.log")"
[[ -f $STREAM_DIR/releases/os-v4.0.2-mac.1.20260911-empty/catalog.signed.json ]] ||
  fail "the stable prune keeps the set stable now serves" "$(cat "$WORK/empty-stable.log")"
OMARCHY_PUBLISH_ASSUME_YES=os-v4.0.2-mac.1.20260911-empty "$PUBLISHER" os-promote \
  --tag os-v4.0.2-mac.1.20260911-empty --to rc >"$WORK/empty-rc.log" 2>&1 ||
  fail "the empty catalog then promotes to rc" "$(cat "$WORK/empty-rc.log")"
cmp -s "$STREAM_DIR/channels/stable/catalog.signed.json" "$STREAM_DIR/channels/rc/catalog.signed.json" ||
  fail "stable and rc serve the same empty catalog"
pass "a signed empty catalog promotes to stable and rc and survives the stable prune"

# --- replacing an empty catalog keeps it as the rollback set -----------------
"$PUBLISHER" empty-catalog --sequence 1100 --output "$WORK/empty2.catalog" >/dev/null
sign_catalog "$WORK/empty2.catalog" "$WORK/empty2.sig"
mkdir -p "$STREAM_DIR/releases/os-v4.0.2-mac.1.20260912-empty"
"$PUBLISHER" envelope --catalog "$WORK/empty2.catalog" --signature "$WORK/empty2.sig" \
  --output "$STREAM_DIR/releases/os-v4.0.2-mac.1.20260912-empty/catalog.signed.json" >/dev/null
OMARCHY_PUBLISH_ASSUME_YES=os-v4.0.2-mac.1.20260912-empty "$PUBLISHER" os-promote \
  --tag os-v4.0.2-mac.1.20260912-empty --to rc >"$WORK/empty2-rc.log" 2>&1 ||
  fail "a newer empty catalog promotes to rc" "$(cat "$WORK/empty2-rc.log")"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['previous_os_tag']=='os-v4.0.2-mac.1.20260911-empty', d" \
  "$STREAM_DIR/channels/rc/channel.json" || fail "channel.json records the empty set it superseded"
pass "an empty catalog it replaces stays recorded for rollback"

# --- the MX Mac feeds at the bucket root are never touched ---------------------
[[ $(root_digest) == "$MX_ROOT_DIGEST" ]] || fail "the MX Mac feeds are unchanged" "$(cd "$BUCKET_DIR" && find . -type f -not -path "./$INSTALLER_STREAM_PATH/*")"
grep -E "^aws s3 (rm|cp) " "$CALLS" | grep -vE "s3://test-bucket/$INSTALLER_STREAM_PATH/" | grep -q . &&
  fail "no write or delete leaves the stream" "$(grep -E "^aws s3 (rm|cp) " "$CALLS" | grep -vE "s3://test-bucket/$INSTALLER_STREAM_PATH/")"
pass "publishing, promoting and pruning never touch the MX Mac feeds at the bucket root"

# --- only the four documented keys are ever rewritten (writes only) ---------
mapfile -t written < <(grep -E "^aws s3 cp " "$CALLS" | grep -oE "s3://test-bucket/[^ ]+" | sed 's|s3://test-bucket/||' | sort -u)
(( ${#written[@]} > 0 )) || fail "the publisher wrote keys to check"
for bucket_key in "${written[@]}"; do
  [[ $bucket_key == "$INSTALLER_STREAM_PATH/"* ]] || fail "a key outside the stream was written" "$bucket_key"
  key=${bucket_key#"$INSTALLER_STREAM_PATH/"}
  case $key in
    channels/stable/catalog.signed.json | channels/rc/catalog.signed.json | channels/edge/catalog.signed.json) ;;
    channels/stable/channel.json | channels/rc/channel.json | channels/edge/channel.json) ;;
    installer/stable/"$INSTALLER_FILE_STEM.pkg" | installer/rc/"$INSTALLER_FILE_STEM.pkg") ;;
    installer/edge/"$INSTALLER_FILE_STEM.pkg") ;;
    installer/stable/installer.json | installer/rc/installer.json | installer/edge/installer.json) ;;
    installer/*/"$INSTALLER_FILE_STEM"-*.pkg | installer/*/*.pkg.sha256) ;;
    *) fail "an unexpected key was written" "$key" ;;
  esac
done
pass "only immutable keys and the documented mutable keys are written"

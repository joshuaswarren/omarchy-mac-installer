#!/bin/bash
# Build the second-computer probe kit zip from a boot-loader checkout: bash build-probe-kit.sh M1N1_CHECKOUT NEW_OUTPUT.zip
set -euo pipefail
(( $# == 2 )) || { echo 'usage: build-probe-kit.sh M1N1_CHECKOUT NEW_OUTPUT.zip' >&2; exit 64; }
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
src=$(cd "$1" && pwd -P)
out=$2
[[ $out == /* && ! -e $out ]] || { echo 'output must be a new absolute path' >&2; exit 64; }
[[ -f $src/proxyclient/tools/stage1_probe_t6032.py ]] || { echo 'no probe script in that checkout' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT
kit=$work/omarchy-m3-ultra-probe-kit
mkdir -p "$kit/proxyclient/tools"
cp -R "$src/proxyclient/m1n1" "$kit/proxyclient/m1n1"
cp "$src/proxyclient/tools/stage1_probe_t6032.py" "$kit/proxyclient/tools/"
cp "$here/run-probe.py" "$kit/"
find "$kit" -name __pycache__ -prune -exec rm -r {} +
chmod 755 "$kit/run-probe.py"
(cd "$work" && zip -q -r "$out" omarchy-m3-ultra-probe-kit)
(cd "$(dirname "$out")" && shasum -a 256 "$(basename "$out")" 2>/dev/null || sha256sum "$(basename "$out")")

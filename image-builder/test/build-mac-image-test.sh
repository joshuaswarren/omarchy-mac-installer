#!/bin/bash

# The builder's own decisions, without a container: which repositories a
# transaction reads and from where, the order the package set installs in, the
# image-target manifests, the pre-check's refusals and the first-boot contract.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bin/build-mac-image
source "$here/bin/build-mac-image"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# The builder's own work directory, for what it records.
work=$scratch

builder_fail() {
  echo "build-mac-image: $*" >&2
  exit 1
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
}

cat >"$scratch/inputs" <<'EOF'
omarchy_channel=edge
omarchy_server=https://pkgs.omarchy.org/edge/$arch
omarchy_db_sha256=1111111111111111111111111111111111111111111111111111111111111111
asahi_alarm_server=https://github.com/asahi-alarm/asahi-alarm/releases/download/aarch64
asahi_alarm_db_sha256=2222222222222222222222222222222222222222222222222222222222222222
alarm_server=https://ca.us.mirror.archlinuxarm.org/$arch/$repo
alarm_core_db_sha256=3333333333333333333333333333333333333333333333333333333333333333
alarm_extra_db_sha256=4444444444444444444444444444444444444444444444444444444444444444
alarm_alarm_db_sha256=5555555555555555555555555555555555555555555555555555555555555555
alarm_aur_db_sha256=6666666666666666666666666666666666666666666666666666666666666666
EOF
field() {
  sed -n "s/^$1=//p" "$scratch/inputs"
}

# ── repositories ───────────────────────────────────────────────────────────
render_config /repos /cache >"$scratch/pacman.conf"
sections=$(sed -n 's/^\[\(.*\)\]$/\1/p' "$scratch/pacman.conf" | paste -sd' ' -)
[[ $sections == "options omarchy-candidates asahi-alarm core extra alarm aur omarchy omarchy-aarch64" ]] ||
  fail "the candidate set is first, then the Apple profile's order: $sections"
pass "the candidate set comes first, then asahi-alarm, Arch Linux ARM and [omarchy]"

files=$(grep -c '^Server = file://' "$scratch/pacman.conf")
((files == 2)) && grep -Fxq 'Server = file:///repos/omarchy-candidates' "$scratch/pacman.conf" &&
  grep -Fxq 'Server = file:///repos/omarchy-aarch64' "$scratch/pacman.conf" ||
  fail "only the candidate set and the empty fork repository are served from disk"
grep -Fxq 'Server = https://pkgs.omarchy.org/edge/$arch' "$scratch/pacman.conf" &&
  grep -Fxq 'Server = https://ca.us.mirror.archlinuxarm.org/$arch/$repo' "$scratch/pacman.conf" ||
  fail "the remote servers are the record's"
pass "only the set and the empty [omarchy-aarch64] come from disk; the rest from the record's servers"

# ── package set ────────────────────────────────────────────────────────────
candidates=$scratch/candidates
mkdir -p "$candidates"
cat >"$candidates/import.json" <<'EOF'
{"packages": [
  {"name": "omarchy", "version": "4.0.0-1", "filename": "omarchy-4.0.0-1-aarch64.pkg.tar.xz", "group": "runtime"},
  {"name": "omarchy-settings", "version": "4.0.0-1", "filename": "s.pkg.tar.xz", "group": "runtime"},
  {"name": "omarchy-mac", "version": "0.1.0-1", "filename": "m.pkg.tar.xz", "group": "runtime"},
  {"name": "omarchy-mac-boot", "version": "20260921-10", "filename": "b.pkg.tar.xz", "group": "runtime"},
  {"name": "linux-aurora", "version": "7.0-1", "filename": "k.pkg.tar.zst", "group": "boot"},
  {"name": "m1n1-aurora", "version": "1.6.1-1", "filename": "n.pkg.tar.zst", "group": "boot"},
  {"name": "uboot-asahi", "version": "2026.07-1", "filename": "u.pkg.tar.zst", "group": "boot"}
]}
EOF
[[ $(qualified uboot-asahi limine gum | paste -sd' ' -) == "omarchy-candidates/uboot-asahi limine gum" ]] ||
  fail "set packages are installed by their repository-qualified name"
pass "a plain uboot-asahi request cannot resolve to asahi-alarm: set packages are qualified"

# What omarchy-pkg-defaults composes before the Apple list: base, then aarch64 when the runtime ships it.
mkdir -p "$scratch/runtime/usr/share/omarchy/install"
printf '# Base\nhyprland\nzram-generator\n' >"$scratch/runtime/usr/share/omarchy/install/omarchy-base.packages"
printf 'omarchy-mac\n' >"$scratch/runtime/usr/share/omarchy/install/omarchy-apple-silicon.packages"
(cd "$scratch/runtime" && bsdtar -cJf "$candidates/omarchy-4.0.0-1-aarch64.pkg.tar.xz" usr)
[[ $(runtime_lists | paste -sd' ' -) == "hyprland zram-generator" ]] ||
  fail "a runtime without an aarch64 list composes the base list alone"
printf '# aarch64\nzram-generator\n' >"$scratch/runtime/usr/share/omarchy/install/omarchy-aarch64.packages"
(cd "$scratch/runtime" && bsdtar -cJf "$candidates/omarchy-4.0.0-1-aarch64.pkg.tar.xz" usr)
[[ $(runtime_lists | paste -sd' ' -) == "hyprland zram-generator zram-generator" ]] ||
  fail "the aarch64 additions follow the base list"
pass "the runtime's base list, then its aarch64 additions, as omarchy-pkg-defaults composes them"

# The Apple list by upstream's name, else an older runtime's; never a link, which bsdtar reads as empty.
install_dir=$scratch/runtime/usr/share/omarchy/install
apple_layout() {
  rm -f "$install_dir"/omarchy-apple*.packages
  while (($#)); do
    if [[ $2 == @* ]]; then
      ln -s "${2#@}" "$install_dir/$1"
    else
      { echo "# Apple"; tr ' ' '\n' <<<"$2"; } >"$install_dir/$1"
    fi
    shift 2
  done
  (cd "$scratch/runtime" && bsdtar -cJf "$candidates/omarchy-4.0.0-1-aarch64.pkg.tar.xz" usr)
}
chosen_apple() {
  (fail() { builder_fail "$@"; }; read_apple_list && echo "${apple_names[*]}")
}
apple_layout omarchy-apple-silicon.packages 'omarchy-mac wf-recorder'
[[ $(chosen_apple) == "omarchy-mac wf-recorder" ]] || fail "an upstream runtime's omarchy-apple-silicon.packages is the Apple list"
apple_layout omarchy-apple.packages omarchy-mac
[[ $(chosen_apple) == omarchy-mac ]] || fail "an older runtime's omarchy-apple.packages is the Apple list"
apple_layout omarchy-apple-silicon.packages 'omarchy-mac wf-recorder' omarchy-apple.packages omarchy-mac
[[ $(chosen_apple) == "omarchy-mac wf-recorder" ]] || fail "upstream's name wins when a runtime ships both"
apple_layout omarchy-apple-silicon.packages 'omarchy-mac wf-recorder' omarchy-apple.packages @omarchy-apple-silicon.packages
[[ $(chosen_apple) == "omarchy-mac wf-recorder" ]] || fail "a compatibility link beside the list changes nothing"
apple_layout omarchy-apple.packages omarchy-mac omarchy-apple-silicon.packages @omarchy-apple.packages
[[ $(chosen_apple) == omarchy-mac ]] || fail "a link by upstream's name is passed over for the list it names"
pass "the Apple list is omarchy-apple-silicon.packages, else an older runtime's omarchy-apple.packages, never a link"
refused_apple() {
  local output
  if output=$(chosen_apple 2>&1); then
    fail "$2 is refused"
  fi
  [[ $output == "build-mac-image: $1" ]] || fail "$2 is refused with: $1 (got: $output)"
}
apple_layout
refused_apple "the runtime ships no Apple package list (omarchy-apple-silicon.packages or omarchy-apple.packages)" \
  "a runtime with no Apple list"
apple_layout omarchy-apple.packages @omarchy-apple-silicon.packages
refused_apple "the runtime ships no Apple package list (omarchy-apple-silicon.packages or omarchy-apple.packages)" \
  "a runtime whose only Apple list is a link"
apple_layout omarchy-apple-silicon.packages ''
refused_apple "the runtime's omarchy-apple-silicon.packages names no package" "a runtime whose Apple list names nothing"
rm -f "$candidates/omarchy-4.0.0-1-aarch64.pkg.tar.xz"
pass "a runtime with no Apple list, only a link to one, or an empty one stops the build before anything installs"
grep -A3 '^  prepare_repositories$' "$here/bin/build-mac-image" | grep -Fxq '  read_apple_list' ||
  fail "the build reads the Apple list before it creates the images"
pass "the build reads the Apple list once, before it creates the images"

runtime_list() {
  case $1 in
    base) printf 'hyprland\nobs-studio\n' ;;
  esac
}
apple_names=(omarchy-mac omarchy-mac-boot)
resolution=good
target_pacman() {
  local name
  if [[ $1 == -Sp && $3 == x ]]; then
    case $4 in
      obs-studio) echo "error: target not found: obs-studio"; return 1 ;;
      broken) echo "error: failed to prepare transaction (could not satisfy dependencies)"; return 1 ;;
    esac
    return
  fi
  printf '%s\n' "$@" >"$scratch/requested"
  for name in omarchy omarchy-settings omarchy-mac omarchy-mac-boot linux-aurora m1n1-aurora uboot-asahi; do
    if [[ $resolution == stolen && $name == uboot-asahi ]]; then
      echo "asahi-alarm uboot-asahi 2026.07.asahi1-1"
    else
      echo "omarchy-candidates $name 1-1"
    fi
  done
  [[ $resolution != refused ]] || echo "extra linux-asahi 6.16-1"
  echo "extra hyprland 0.56.2-3"
}
logs=$scratch/logs
mkdir -p "$logs"
(fail() { builder_fail "$@"; }; precheck_transaction) >/dev/null || fail "a set that resolves from itself passes the pre-check"
(fail() { builder_fail "$@"; }; precheck_transaction; printf '%s\n' "${base_names[@]}" >"$scratch/base"; printf '%s\n' "${unavailable[@]}" >"$scratch/missing") >/dev/null
[[ $(<"$scratch/base") == hyprland && $(<"$scratch/missing") == obs-studio ]] ||
  fail "base names the pinned repositories lack are left out and recorded"
for name in omarchy omarchy-settings omarchy-mac omarchy-mac-boot linux-aurora m1n1-aurora uboot-asahi; do
  grep -Fxq "omarchy-candidates/$name" "$scratch/requested" || fail "the pre-check resolves $name by its qualified name"
  ! grep -Fxq "$name" "$scratch/requested" || fail "the pre-check also asks for a plain $name"
done
grep -Fxq hyprland "$scratch/requested" && ! grep -Fxq obs-studio "$scratch/requested" ||
  fail "the pre-check resolves the base names the repositories carry, and only those"
grep -Fxq alsa-ucm-conf-asahi "$scratch/requested" && grep -Fxq asahi-audio "$scratch/requested" ||
  fail "the pre-check resolves the speaker stack's profiles and DSP chain"
pass "the pre-check passes a set that resolves from itself and records base names the repositories lack"
runtime_list() {
  case $1 in
    base) printf 'hyprland\nbroken\n' ;;
  esac
}
if (fail() { builder_fail "$@"; }; precheck_transaction) >/dev/null 2>&1; then
  fail "the pre-check drops a base name that exists but does not resolve"
fi
runtime_list() {
  case $1 in
    base) printf 'hyprland\nobs-studio\n' ;;
  esac
}
for resolution in stolen refused; do
  if (fail() { builder_fail "$@"; }; precheck_transaction) >/dev/null 2>&1; then
    fail "the pre-check accepts a $resolution resolution"
  fi
done
pass "the pre-check refuses a set package resolved elsewhere, a refused package, and a base name that does not resolve"

# ── install order ──────────────────────────────────────────────────────────
source_commit=$(printf 'a%.0s' {1..40})
builder_commit=$(printf 'c%.0s' {1..40})
printf 'candidate_set=apple-test-fixture\ncandidate_source_commit=%s\n' "$source_commit" >>"$scratch/inputs"
jq '. + {candidate_only: true}' "$candidates/import.json" >"$scratch/import.json" && mv "$scratch/import.json" "$candidates/import.json"
export MAC_IMAGE_BUILDER_COMMIT=$builder_commit MAC_IMAGE_BUILDER_CLEAN=false
target=$scratch/target
mkdir -p "$target"
mount_api() { :; }
unmount_api() { :; }
chown() { :; }
pacman() { printf 'omarchy 4.0.0-1\nomarchy-settings 4.0.0-1\nomarchy-mac 0.1.0-1\nomarchy-mac-boot 20260921-10\nlinux-aurora 7.0-1\nm1n1-aurora 1.6.1-1\nuboot-asahi 2026.07-1\n'; }
target_pacman() {
  [[ -e $target/var/lib/omarchy/image/target ]] && manifest=yes || manifest=no
  printf '%s manifest=%s\n' "$*" "$manifest" >>"$scratch/transactions"
}
: >"$scratch/transactions"
base_names=(hyprland)
(fail() { builder_fail "$@"; }; install_settings; write_image_target; install_runtime; install_apple_set)
unset -f chown pacman
mapfile -t transactions <"$scratch/transactions"
((${#transactions[@]} == 3)) || fail "three transactions: ${transactions[*]}"
[[ ${transactions[0]} == *" omarchy-candidates/omarchy-settings manifest=no" && ${transactions[0]} != *linux-aurora* ]] ||
  fail "the first transaction is the base and omarchy-settings alone, before the manifest: ${transactions[0]}"
[[ ${transactions[1]} == "-S omarchy-candidates/omarchy hyprland manifest=yes" ]] ||
  fail "the runtime comes next, after the manifest: ${transactions[1]}"
for name in omarchy-mac omarchy-mac-boot linux-aurora m1n1-aurora uboot-asahi; do
  [[ " ${transactions[2]} " == *" omarchy-candidates/$name "* ]] || fail "the Apple set installs $name by its qualified name"
done
[[ " ${transactions[2]} " == *" alsa-ucm-conf-asahi asahi-audio "* ]] ||
  fail "the Apple set installs alsa-ucm-conf-asahi and asahi-audio: ${transactions[2]}"
pass "omarchy-settings installs alone, then the manifest, the runtime and the Apple set, set packages by qualified name"
pass "the Apple set carries the speaker stack's model profiles and DSP chain"

expected_target="format=1
platform=apple-silicon
candidate_set=apple-test-fixture
candidate_source_commit=$source_commit
builder_commit=$builder_commit
builder_tree_clean=false
image_profile=test"
[[ $(<"$target/var/lib/omarchy/image/target") == "$expected_target" ]] ||
  fail "the image-target manifest names the platform, then the set, the builder and the profile" \
    "$(<"$target/var/lib/omarchy/image/target")"
[[ $(stat -c %a "$target/var/lib/omarchy/image/target" 2>/dev/null || stat -f %Lp "$target/var/lib/omarchy/image/target") == 644 ]] ||
  fail "the image-target manifest is mode 0644"
[[ ! -e $target/var/lib/omarchy/image-target ]] || fail "only the one manifest path is written"
pass "the image-target manifest names apple-silicon, mode 0644, at /var/lib/omarchy/image/target"
pass "the image-target manifest records the candidate set, its source commit, the builder commit and tree state, and the test profile"

image_profile_of() {
  (profile=$1; jq "$2" "$candidates/import.json" >"$scratch/import.json.new" &&
    cp "$candidates/import.json" "$scratch/import.json.keep" && mv "$scratch/import.json.new" "$candidates/import.json" &&
    image_profile; mv "$scratch/import.json.keep" "$candidates/import.json")
}
[[ $(image_profile_of lab .) == lab && $(image_profile_of release .) == test &&
  $(image_profile_of release '. + {candidate_only: false}') == release ]] ||
  fail "the image profile is lab for a lab image, else test for a candidate-only set, else release"
pass "the image profile is lab for a lab image, else test for a candidate-only set, else release"

mv "$candidates/import.json" "$scratch/import.json.keep"
if (chown() { :; }; fail() { builder_fail "$@"; }; write_image_target) >/dev/null 2>&1; then
  fail "the image-target manifest is refused when the candidate set cannot be read"
fi
mv "$scratch/import.json.keep" "$candidates/import.json"
pass "the image-target manifest is refused when the candidate set cannot be read"

for unset_variable in MAC_IMAGE_BUILDER_COMMIT MAC_IMAGE_BUILDER_CLEAN; do
  if (unset "$unset_variable"; chown() { :; }; fail() { builder_fail "$@"; }; write_image_target) >/dev/null 2>&1; then
    fail "the image-target manifest is refused without $unset_variable"
  fi
done
pass "the image-target manifest is not written without the builder commit and tree state"

# ── first boot ─────────────────────────────────────────────────────────────
make_first_boot() {
  rm -rf "$target"
  mkdir -p "$target/usr/lib/omarchy/mac-first-boot"
  cat >"$target/usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot" <<EOF
#!/bin/bash
if [[ \$1 == arm ]]; then mkdir -p "\$2/var/lib/omarchy/mac-first-boot"; : >"\$2/var/lib/omarchy/mac-first-boot/pending"; fi
exit 0
run_deferred_steps() { $1; }
EOF
  chmod +x "$target/usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot"
}
make_first_boot "cmp -s \"\$steps\" <(printf '%s\\n' 'install/hardware/apple/limine-boot.sh')"
(fail() { builder_fail "$@"; }; arm_first_boot)
[[ -f $target/var/lib/omarchy/mac-first-boot/pending &&
  $(<"$target/var/lib/omarchy/mac-first-boot/deferred-steps") == install/hardware/apple/limine-boot.sh ]] ||
  fail "a first boot that runs the Limine leaf gets its deferred-steps contract"
make_first_boot "/usr/bin/omarchy-provision-hardware"
(fail() { builder_fail "$@"; }; arm_first_boot)
[[ -f $target/var/lib/omarchy/mac-first-boot/pending && ! -e $target/var/lib/omarchy/mac-first-boot/deferred-steps ]] ||
  fail "a first boot without that contract gets pending only"
pass "first boot is armed by the boot package, with deferred-steps only for the contract it reads"

# ── snapper's subvolume ────────────────────────────────────────────────────
# The build root's btrfs subvolumes, as btrfs subvolume show would find them.
: >"$scratch/subvolumes"
btrfs() {
  case "$1 $2" in
    "subvolume show") grep -Fxq "$3" "$scratch/subvolumes" ;;
    "subvolume create") mkdir "$3" && printf '%s\n' "$3" >>"$scratch/created" ;;
    *) return 1 ;;
  esac
}
carry() {
  rm -rf "$scratch/build" "$scratch/sealed" "$scratch/created"
  mkdir -p "$scratch/build" "$scratch/sealed"
  : >"$scratch/created"
  "$@"
  (fail() { builder_fail "$@"; }; carry_snapshots_subvolume "$scratch/build" "$scratch/sealed") >/dev/null 2>&1
}
carry true || fail "a build root without /.snapshots seals"
[[ ! -s $scratch/created ]] || fail "no /.snapshots is made when the runtime made none"
carry eval 'mkdir "$scratch/build/.snapshots"; echo "$scratch/build/.snapshots" >"$scratch/subvolumes"' ||
  fail "an empty /.snapshots subvolume is carried"
[[ $(<"$scratch/created") == "$scratch/sealed/.snapshots" ]] || fail "the sealed @ gets its own /.snapshots subvolume"
if carry eval 'mkdir "$scratch/build/.snapshots"; : >"$scratch/subvolumes"'; then
  fail "a flattened /.snapshots is carried as a plain directory"
fi
if carry eval 'mkdir -p "$scratch/build/.snapshots/1"; echo "$scratch/build/.snapshots" >"$scratch/subvolumes"'; then
  fail "snapshots taken during the build are carried"
fi
unset -f btrfs carry
pass "snapper's empty /.snapshots subvolume is carried into the sealed @; a plain or non-empty one stops the build"

# ── desktop automounters ───────────────────────────────────────────────────
if ((EUID != 0)); then
  sudo() { return 1; }
  pgrep() { [[ $2 == *udiskie* ]]; }
  if (fail() { builder_fail "$@"; }; hide_loop_devices) >/dev/null 2>&1; then
    fail "a build without root or passwordless sudo runs beside a desktop automounter"
  fi
  pgrep() { return 1; }
  (fail() { builder_fail "$@"; }; hide_loop_devices) || fail "a build without an automounter needs no root"
  unset -f sudo pgrep
  pass "without a way to hide its loop devices, the build refuses to run beside a desktop automounter"
fi

# ── lab access ─────────────────────────────────────────────────────────────
target=$scratch/lab-root
logs=$scratch
mkdir -p "$target/usr/lib/systemd/system" "$scratch/lab-access"
: >"$target/usr/lib/systemd/system/sshd.service"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKm3ZIe3P3NW/VLwzdZ6vgFvk4OAabP02rnxiZKmXG2r lab\n' \
  >"$scratch/lab-access/authorized_keys"
isolated_chroot() { shift; printf '%s\n' "$*" >>"$scratch/chroot"; }
: >"$scratch/chroot"
(fail() { builder_fail "$@"; }; profile=release; apply_lab_access)
[[ ! -e $target/etc/sudoers.d/omarchy-lab && ! -s $scratch/chroot ]] || fail "a release image gets no lab access"
(fail() { builder_fail "$@"; }; profile=lab; lab_access_dir=$scratch/lab-access; apply_lab_access
  [[ $lab_access_sha256 =~ ^[0-9a-f]{64}$ ]] || fail "the lab access digest is recorded")
[[ $(<"$scratch/chroot") == "visudo -cf /etc/sudoers.d/omarchy-lab" ]] || fail "the lab sudoers rule is validated in the image"
python3 -c 'import importlib.util, sys; s = importlib.util.spec_from_file_location("l", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); m.check(__import__("pathlib").Path(sys.argv[2]), "the image", True)' \
  "$here/builder/lab_access.py" "$target" || fail "the builder writes exactly the lab overlay"
unset -f isolated_chroot
pass "a lab build writes the lab overlay and validates its sudoers rule; a release build writes none"

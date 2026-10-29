#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Experimental Debian port of:
# https://github.com/hungarianhc/rog-ally-x20-steamos-speakers
#
# IMPORTANT:
# - Intended only for ASUS ROG Xbox Ally X20 (RC74XA), audio subsystem 1043:1954.
# - Not tested on hardware. Run "preflight" first.
# - Does not touch firmware/boot files unless hardware checks pass.
# - The patched kernel module must build successfully for the exact running kernel.
#
# Usage:
#   ./ally-audio-fix-debian.sh preflight
#   ./ally-audio-fix-debian.sh build       # normal user; requires Debian headers
#   sudo ./ally-audio-fix-debian.sh install
#   sudo ./ally-audio-fix-debian.sh status
#   sudo ./ally-audio-fix-debian.sh uninstall
#
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KVER=$(uname -r)
KEY='acp-audio-config-flag'
LIB=/var/lib/ally-audio-fix
HOOK=$LIB/modprobe-hook.sh
MODCONF=/etc/modprobe.d/ally-audio-fix.conf
ENVCONF=/etc/environment.d/90-ally-audio-fix.conf
MODNAME=snd-soc-acpi-amd-match.ko
SSID=1954
EARLY_CPIO=ally-audio-acpi.cpio
GRUB_DEFAULTS=/etc/default/grub
GRUB_CFG=/boot/grub/grub.cfg
FW_COMMIT=a2dcb924f0897368b0b4f305cbf9808cdda90ce0
FW_URL=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/ti/audio/tas2783
SPEAKER_ID_VAR=/sys/firmware/efi/efivars/SPEAKER_ID-aa61eaaf-6e83-7523-b0d0-7df74bb24a81
KSRC_URL=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain
KSRC_FILES="sound/soc/amd/mach-config.h
sound/soc/amd/acp/amd-acp63-acpi-match.c
sound/soc/amd/acp/amd-acp70-acpi-match.c
sound/soc/amd/acp/soc-acpi-amd-sdca-quirks.c
sound/soc/amd/acp/soc-acpi-amd-sdca-quirks.h"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run this command with sudo"; }
is_debian() { [ -r /etc/os-release ] && . /etc/os-release && [ "${ID:-}" = debian ]; }

fw_sha256() {
    case "$1" in
        1954-0-0-0x8.bin) echo e37c3efa1e92e72614175682c01cdcd4ceb7079878e8bafd3177c5a45dede434 ;;
        1954-0-0-0xB.bin) echo 655eb8754afc7284850988f330b6466ad782b7ae905ab7246621375a4784a8be ;;
        1954-1-0-0x8.bin) echo 677e3d033dcc8effc5247b771a5ecd08484c3740d0086b4cd333b07af06eb563 ;;
        1954-1-0-0xB.bin) echo 0d50eae7ae4f515304f4e8ce14832654ebf3447711c283bdbf7c175c9298de1d ;;
        *) return 1 ;;
    esac
}

acp_path() {
    lspci -Dnd 1022:15e2 2>/dev/null | awk 'NR==1 {print $1}'
}

check_device() {
    is_debian || die "this port is for Debian; detected OS is not Debian"
    [ "$(dpkg --print-architecture)" = amd64 ] || die "only Debian amd64 is supported by this script"
    command -v lspci >/dev/null 2>&1 || die "pciutils is missing; install it with: sudo apt install pciutils"
    ACP=$(acp_path)
    [ -n "$ACP" ] || die "AMD ACP device 1022:15e2 not found; refusing to modify this machine"
    ssid=$(cat "/sys/bus/pci/devices/$ACP/subsystem_device" 2>/dev/null || true)
    case "$ssid" in 0x1954|1954) ;; *) die "AMD ACP subsystem ID is '$ssid', expected 1954; refusing to modify this machine" ;; esac
    product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
    case "$product" in *RC74XA*|*"ROG XBOX Ally X"*) ;; *) note "DMI product name is '$product'; hardware ID matches, but verify this is the Ally X20" ;; esac
}

find_flag() {
    for t in /sys/firmware/acpi/tables/DSDT /sys/firmware/acpi/tables/SSDT*; do
        [ -f "$t" ] || continue
        off=$(grep -abo "$KEY" "$t" 2>/dev/null | head -1 | cut -d: -f1 || true)
        [ -n "$off" ] || continue
        voff=$((off + ${#KEY} + 2))
        prefix=$(od -An -tx1 -j $((voff - 1)) -N1 "$t" | tr -d ' \n')
        val=$(od -An -tx1 -j "$voff" -N1 "$t" | tr -d ' \n')
        [ "$prefix" = 0a ] || die "unexpected AML encoding in $t (prefix $prefix)"
        echo "$t $voff $val"
        return 0
    done
    return 1
}

speaker_id() {
    [ -r "$SPEAKER_ID_VAR" ] || return 1
    od -An -tu4 -j4 -N4 "$SPEAKER_ID_VAR" | tr -d ' \n'
}

module_source() {
    for d in "$REPO/prebuilt/$KVER" "$REPO/build-out/$KVER"; do
        [ -f "$d/$MODNAME" ] && { echo "$d/$MODNAME"; return 0; }
    done
    return 1
}

cmd_preflight() {
    echo "===== Debian Ally X20 audio-fix preflight (read-only) ====="
    echo "OS: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
    echo "Architecture: $(dpkg --print-architecture 2>/dev/null || echo unknown)"
    echo "Kernel: $KVER"
    echo "DMI product: $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
    echo "BIOS: $(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo unknown)"
    echo
    echo "PCI audio-related devices:"
    lspci -nnk 2>/dev/null | grep -A4 -iE 'audio|multimedia|signal processing' || true
    echo
    ACP=$(acp_path || true)
    if [ -n "$ACP" ]; then
        echo "AMD ACP: $ACP"
        echo "Subsystem ID: $(cat "/sys/bus/pci/devices/$ACP/subsystem_device" 2>/dev/null || echo unknown)"
    else
        echo "AMD ACP 1022:15e2: NOT FOUND"
    fi
    echo
    echo "ACPI flag:"
    if info=$(find_flag 2>/dev/null); then echo "$info"; else echo "Not found"; fi
    echo
    echo "Speaker ID: $(speaker_id 2>/dev/null || echo unavailable)"
    echo "Kernel headers: $([ -e "/lib/modules/$KVER/build/Makefile" ] && echo present || echo missing)"
    echo "GRUB config: $([ -f "$GRUB_CFG" ] && echo "$GRUB_CFG" || echo missing)"
    echo
    echo "This command made no changes."
}

build_cpio() {
    table=$1
    voff=$2
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT HUP INT TERM
    mkdir -p "$work/kernel/firmware/acpi"
    python3 -I - "$table" "$voff" "$work/kernel/firmware/acpi/$(basename "$table" | tr A-Z a-z).aml" <<'PY'
import struct, sys
src, voff, dst = sys.argv[1], int(sys.argv[2]), sys.argv[3]
d = bytearray(open(src, 'rb').read())
assert d[voff - 1] == 0x0A and d[voff] == 0x10, "ACPI flag is not 0x10"
d[voff] = 0
struct.pack_into('<I', d, 24, struct.unpack_from('<I', d, 24)[0] + 1)
d[9] = 0
d[9] = (-sum(d)) & 0xff
open(dst, 'wb').write(d)
PY
    (cd "$work" && find kernel -print | cpio -o -H newc --quiet) > "$LIB/$EARLY_CPIO"
    rm -rf "$work"
    trap - EXIT HUP INT TERM
}

install_acpi() {
    [ -f "$GRUB_DEFAULTS" ] && [ -f "$GRUB_CFG" ] || die "Debian GRUB files not found; ACPI override not installed"
    command -v grub-mkconfig >/dev/null 2>&1 || die "grub-mkconfig not found"
    command -v cpio >/dev/null 2>&1 || die "cpio is required (sudo apt install cpio)"
    info=$(find_flag) || die "ACPI flag '$KEY' not found; refusing to patch ACPI"
    set -- $info
    table=$1; voff=$2; value=$3
    case "$value" in
        10) note "ACPI flag is 0x10; preparing early initrd override"; build_cpio "$table" "$voff" ;;
        00) [ -s "$LIB/$EARLY_CPIO" ] || die "ACPI flag is already 0 but no saved override exists"; note "ACPI flag already appears cleared" ;;
        *) die "ACPI flag is 0x$value, expected 0x10; refusing to patch" ;;
    esac
    install -m 0644 "$LIB/$EARLY_CPIO" "/boot/$EARLY_CPIO"
    if ! grep -q '^GRUB_EARLY_INITRD_LINUX_CUSTOM=' "$GRUB_DEFAULTS"; then
        printf '\nGRUB_EARLY_INITRD_LINUX_CUSTOM="%s"\n' "$EARLY_CPIO" >> "$GRUB_DEFAULTS"
    else
        cp "$GRUB_DEFAULTS" "$LIB/grub-defaults.before"
        sed -i "/^GRUB_EARLY_INITRD_LINUX_CUSTOM=/c\\GRUB_EARLY_INITRD_LINUX_CUSTOM=\"$EARLY_CPIO\"" "$GRUB_DEFAULTS"
    fi
    grub-mkconfig -o "$GRUB_CFG"
    note "ACPI early initrd configured in Debian GRUB"
}

install_firmware() {
    id=$(speaker_id) || die "UEFI SPEAKER_ID variable missing; cannot select tuning files"
    case "$id" in 0) vendor=JGX ;; 1) vendor=LS ;; *) die "unexpected SPEAKER_ID '$id'";; esac
    note "Speaker supplier: $vendor (SPEAKER_ID=$id)"
    mkdir -p "$LIB/firmware"
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT HUP INT TERM
    for uid in 8 B; do
        src="$SSID-$id-0-0x$uid.bin"
        dst="$SSID-0-0x$uid.bin"
        curl -fsSL -o "$tmp" "$FW_URL/$src?id=$FW_COMMIT" || die "download failed: $src"
        echo "$(fw_sha256 "$src")  $tmp" | sha256sum -c --quiet || die "firmware checksum mismatch: $src"
        install -m 0644 "$tmp" "$LIB/firmware/$dst"
        echo "Installed $dst"
    done
    rm -f "$tmp"
    trap - EXIT HUP INT TERM
}

install_module() {
    src=$(module_source) || die "No patched module for kernel $KVER. Run '$0 build' as your normal user first."
    vm=$(modinfo -F vermagic "$src" | awk '{print $1}')
    [ "$vm" = "$KVER" ] || die "module vermagic '$vm' does not match running kernel '$KVER'"
    if [ -f "$(dirname "$src")/SHA256SUMS" ]; then
        (cd "$(dirname "$src")" && sha256sum -c --quiet SHA256SUMS) || die "module checksum mismatch"
    fi
    mkdir -p "$LIB/modules/$KVER"
    install -m 0644 "$src" "$LIB/modules/$KVER/$MODNAME"
    depmod -a "$KVER" 2>/dev/null || true
    note "Patched module installed for $KVER"
}

install_ucm() {
    sys=/usr/share/alsa/ucm2
    if [ -f "$sys/sof-soundwire/tas2783.conf" ]; then
        note "System already has TAS2783 UCM profile"
        return
    fi
    [ -f "$REPO/ucm/tas2783.conf" ] || die "missing $REPO/ucm/tas2783.conf; clone the upstream repository with its ucm directory"
    mkdir -p "$LIB/ucm2/sof-soundwire" "$(dirname "$ENVCONF")"
    # Avoid symlink overlaying a live system tree. Copy the system UCM tree, then add one profile.
    rm -rf "$LIB/ucm2"
    cp -a "$sys" "$LIB/ucm2"
    mkdir -p "$LIB/ucm2/sof-soundwire"
    install -m 0644 "$REPO/ucm/tas2783.conf" "$LIB/ucm2/sof-soundwire/tas2783.conf"
    printf 'ALSA_CONFIG_UCM2=%s\n' "$LIB/ucm2" > "$ENVCONF"
}

install_hooks() {
    cat > "$HOOK" <<EOF
#!/bin/sh
LIB=$LIB
case \$1 in
match)
    m=\$LIB/modules/\$(uname -r)/$MODNAME
    if [ -f "\$m" ]; then
        /sbin/modprobe snd_soc_sdca 2>/dev/null || true
        exec /sbin/insmod "\$m"
    fi
    exec /sbin/modprobe --ignore-install snd_soc_acpi_amd_match
    ;;
tas2783)
    p=/sys/module/firmware_class/parameters/path
    if [ -w "\$p" ] && [ -z "\$(cat "\$p")" ]; then
        printf %s "\$LIB/firmware" > "\$p"
    fi
    exec /sbin/modprobe --ignore-install snd_soc_tas2783_sdw
    ;;
esac
exit 1
EOF
    chmod 0755 "$HOOK"
    cat > "$MODCONF" <<EOF
# Installed by ally-audio-fix-debian.sh
install snd_soc_acpi_amd_match /bin/sh $HOOK match
install snd_soc_tas2783_sdw /bin/sh $HOOK tas2783
EOF
}

cmd_build() {
    [ "$(id -u)" -ne 0 ] || die "run build as your normal user, without sudo"
    is_debian || die "Debian only"
    [ "$(dpkg --print-architecture)" = amd64 ] || die "amd64 only"
    [ -f "/lib/modules/$KVER/build/Makefile" ] || die "headers for $KVER not found. Install matching linux-headers first."
    command -v curl >/dev/null || die "curl missing; sudo apt install curl"
    command -v patch >/dev/null || die "patch missing; sudo apt install patch"
    command -v make >/dev/null || die "make missing; sudo apt install build-essential"
    command -v modinfo >/dev/null || die "kmod missing; sudo apt install kmod"
    [ -f "$REPO/patches/0001-ASoC-amd-acp70-add-TAS2783-x2-on-link-0-with-RT721-on-link-1.patch" ] || die "upstream patch file missing; clone the full repository"
    base=${KVER%%-*}
    case "$base" in *+*) base=${base%%+*} ;; esac
    out="$REPO/build-out/$KVER"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT HUP INT TERM
    mkdir -p "$work/src/amd/acp"
    for f in $KSRC_FILES; do
        dst="$work/src/${f#sound/soc/}"
        mkdir -p "$(dirname "$dst")"
        curl -fsSL -o "$dst" "$KSRC_URL/$f?h=v$base" || die "could not download upstream source $f for v$base"
    done
    cp "$REPO/patches/0001-ASoC-amd-acp70-add-TAS2783-x2-on-link-0-with-RT721-on-link-1.patch" "$work/layout.patch"
    cat > "$work/src/amd/acp/Makefile" <<'EOF'
snd-soc-acpi-amd-match-y := amd-acp63-acpi-match.o amd-acp70-acpi-match.o soc-acpi-amd-sdca-quirks.o
obj-m += snd-soc-acpi-amd-match.o
EOF
    note "Checking whether the upstream layout patch applies to Debian kernel source v$base"
    (cd "$work/src" && patch -s -p3 < "$work/layout.patch") || die "upstream patch does not apply to v$base. No module was installed; this kernel needs a separately reviewed patch."
    make -s -C "/lib/modules/$KVER/build" M="$work/src/amd/acp" modules || die "module build failed; no module was installed"
    mod="$work/src/amd/acp/$MODNAME"
    [ -f "$mod" ] || die "build did not produce $MODNAME"
    [ "$(modinfo -F vermagic "$mod" | awk '{print $1}')" = "$KVER" ] || die "built module vermagic mismatch"
    strings "$mod" | grep -q acp70_tas2783x2_l0u8b_rt721_l1u0 || die "built module lacks expected Ally X20 layout"
    mkdir -p "$out"
    install -m 0644 "$mod" "$out/$MODNAME"
    (cd "$out" && sha256sum "$MODNAME" > SHA256SUMS)
    note "Build completed: $out/$MODNAME"
    echo "Next: sudo $0 install"
}

cmd_install() {
    need_root
    check_device
    command -v curl >/dev/null || die "curl missing; install with apt"
    command -v cpio >/dev/null || die "cpio missing; install with apt"
    command -v python3 >/dev/null || die "python3 missing"
    command -v grub-mkconfig >/dev/null || die "GRUB tools missing"
    [ -f "/lib/modules/$KVER/build/Makefile" ] || die "matching kernel headers missing for $KVER"
    module_source >/dev/null || die "no patched module for running kernel $KVER; run '$0 build' as normal user first"
    mkdir -p "$LIB"
    # Validate ACPI and speaker data before installing any component.
    info=$(find_flag) || die "ACPI flag '$KEY' not found; no changes made"
    set -- $info
    [ "$3" = 10 ] || [ "$3" = 00 ] || die "unexpected ACPI flag value 0x$3; no changes made"
    sid=$(speaker_id) || die "UEFI SPEAKER_ID missing; no changes made"
    case "$sid" in 0|1) ;; *) die "unexpected SPEAKER_ID '$sid'; no changes made";; esac
    install_firmware
    install_module
    install_ucm
    install_hooks
    install_acpi
    update-initramfs -u -k "$KVER"
    update-grub
    sync
    echo "Installed. Reboot, then run: sudo $0 status"
}

cmd_status() {
    echo "Device: $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
    echo "Kernel: $KVER"
    ACP=$(acp_path || true)
    if [ -n "$ACP" ]; then
        echo "AMD ACP: $ACP subsystem=$(cat "/sys/bus/pci/devices/$ACP/subsystem_device" 2>/dev/null || echo unknown)"
    else
        echo "AMD ACP: not found"
    fi
    info=$(find_flag 2>/dev/null || true)
    echo "ACPI flag: ${info:-not found}"
    echo "Patched module: $([ -f "$LIB/modules/$KVER/$MODNAME" ] && echo installed || echo absent)"
    echo "Firmware: $(ls "$LIB/firmware" 2>/dev/null | tr '\n' ' ')"
    echo "UCM overlay: $( [ -f "$ENVCONF" ] && cat "$ENVCONF" || echo absent )"
    echo "GRUB early cpio: $(grep '^GRUB_EARLY_INITRD_LINUX_CUSTOM=' "$GRUB_DEFAULTS" 2>/dev/null || echo absent)"
    aplay -l 2>/dev/null | grep '^card' || true
}

cmd_uninstall() {
    need_root
    # Restore the prior GRUB defaults if this installer saved them; otherwise remove only its setting.
    if [ -f "$LIB/grub-defaults.before" ]; then
        cp "$LIB/grub-defaults.before" "$GRUB_DEFAULTS"
    elif [ -f "$GRUB_DEFAULTS" ]; then
        sed -i '/^GRUB_EARLY_INITRD_LINUX_CUSTOM="ally-audio-acpi.cpio"$/d' "$GRUB_DEFAULTS"
    fi
    rm -f "/boot/$EARLY_CPIO" "$MODCONF" "$ENVCONF"
    rm -f "$HOOK"
    rm -rf "$LIB"
    update-grub
    update-initramfs -u -k all
    depmod -a 2>/dev/null || true
    echo "Removed the Debian audio-fix files. Reboot to apply."
}

case "${1:-}" in
    preflight) cmd_preflight ;;
    build) cmd_build ;;
    install) cmd_install ;;
    status) cmd_status ;;
    uninstall) cmd_uninstall ;;
    *) echo "Usage: $0 preflight|build|install|status|uninstall"; exit 2 ;;
esac

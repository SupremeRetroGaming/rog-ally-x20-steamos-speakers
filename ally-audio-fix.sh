#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# ally-audio-fix.sh - internal speakers for the ASUS ROG Xbox Ally X20 on SteamOS.
#
# Four problems keep the speakers silent; this script fixes each one:
#
#  1. The BIOS sets ACPI "acp-audio-config-flag" = 0x10 (legacy, DMIC only), so the
#     SoundWire driver ignores the audio coprocessor. We load a copy of the ACPI table
#     with the flag cleared at boot (kernel ACPI table upgrade via an early initrd).
#  2. The kernel has no machine layout for retail boards, which put the two TAS2783
#     amps on SoundWire link 0. We load a rebuilt snd-soc-acpi-amd-match module with
#     that layout added (patches/0001-*.patch).
#  3. The amps need TI tuning files. We fetch the ones for this model from
#     linux-firmware, picking the speaker supplier variant from the BIOS SPEAKER_ID.
#  4. SteamOS's alsa-ucm-conf predates TAS2783 support, so PipeWire finds no speaker
#     device. We add upstream's sof-soundwire/tas2783.conf through a UCM overlay.
#
# Usage:
#   sudo ./ally-audio-fix.sh install     install or refresh everything (then reboot)
#   sudo ./ally-audio-fix.sh status      show what is active
#   sudo ./ally-audio-fix.sh uninstall   remove everything (then reboot)
#        ./ally-audio-fix.sh build       build the module for the running kernel
#                                        (no sudo; needed after a kernel update)
#
# Only the booted SteamOS slot is changed. After a SteamOS update, run "install" again.

set -eu

REPO=$(cd "$(dirname "$0")" && pwd)
KVER=$(uname -r)

# 1: ACPI override
KEY='acp-audio-config-flag'
EFI=/efi
CFG=$EFI/EFI/steamos/grub.cfg
CPIO_NAME=acpi_override.cpio

# 2-4: speaker support
LIB=/var/lib/ally-audio-fix
HOOK=$LIB/modprobe-hook.sh
MODCONF=/etc/modprobe.d/ally-audio-fix.conf
ENVCONF=/etc/environment.d/90-ally-audio-fix.conf
MODNAME=snd-soc-acpi-amd-match.ko
SSID=1954

# Amp tuning files, pinned to a linux-firmware commit.
FW_COMMIT=a2dcb924f0897368b0b4f305cbf9808cdda90ce0
FW_URL=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/ti/audio/tas2783
SPEAKER_ID_VAR=/sys/firmware/efi/efivars/SPEAKER_ID-aa61eaaf-6e83-7523-b0d0-7df74bb24a81

# Upstream kernel sources the module is built from.
KSRC_URL=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain
KSRC_FILES="sound/soc/amd/mach-config.h
sound/soc/amd/acp/amd-acp63-acpi-match.c
sound/soc/amd/acp/amd-acp70-acpi-match.c
sound/soc/amd/acp/soc-acpi-amd-sdca-quirks.c
sound/soc/amd/acp/soc-acpi-amd-sdca-quirks.h"

ACP=$(lspci -Dnd 1022:15e2 2>/dev/null | awk 'NR==1{print $1}')

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }
need_root() { [ "$(id -u)" = 0 ] || die "run with sudo"; }

fw_sha256() {
	case $1 in
	1954-0-0-0x8.bin) echo e37c3efa1e92e72614175682c01cdcd4ceb7079878e8bafd3177c5a45dede434 ;;
	1954-0-0-0xB.bin) echo 655eb8754afc7284850988f330b6466ad782b7ae905ab7246621375a4784a8be ;;
	1954-1-0-0x8.bin) echo 677e3d033dcc8effc5247b771a5ecd08484c3740d0086b4cd333b07af06eb563 ;;
	1954-1-0-0xB.bin) echo 0d50eae7ae4f515304f4e8ce14832654ebf3447711c283bdbf7c175c9298de1d ;;
	*) return 1 ;;
	esac
}

check_device() {
	[ -n "$ACP" ] || die "no AMD ACP audio device (1022:15e2) found"
	ssid=$(sed 's/^0x//' "/sys/bus/pci/devices/$ACP/subsystem_device")
	[ "$ssid" = "$SSID" ] ||
		die "audio subsystem ID is $ssid, expected $SSID (ROG Xbox Ally X20); not touching it"
}

# Module built for the running kernel: a prebuilt one from the repo, or one from "build".
module_source() {
	for d in "$REPO/prebuilt/$KVER" "$REPO/build-out/$KVER"; do
		[ -f "$d/$MODNAME" ] && { echo "$d/$MODNAME"; return 0; }
	done
	return 1
}

# --- 1: ACPI override ----------------------------------------------------------------

# Print "<table path> <offset of value byte> <value>" for the table holding the flag.
find_flag() {
	for t in /sys/firmware/acpi/tables/DSDT /sys/firmware/acpi/tables/SSDT*; do
		off=$(grep -abo "$KEY" "$t" 2>/dev/null | head -1 | cut -d: -f1) || true
		[ -n "$off" ] || continue
		# name + NUL, then 0x0A (BytePrefix), then the value byte
		voff=$((off + ${#KEY} + 2))
		prefix=$(od -An -tx1 -j $((voff - 1)) -N1 "$t" | tr -d ' ')
		val=$(od -An -tx1 -j "$voff" -N1 "$t" | tr -d ' ')
		[ "$prefix" = 0a ] || die "unexpected AML encoding in $t (prefix $prefix)"
		echo "$t $voff $val"
		return 0
	done
	return 1
}

efi_partuuid() {
	src=$(findmnt -no SOURCE "$EFI" | tail -1)
	[ -n "$src" ] || die "$EFI is not mounted"
	lsblk -no PARTUUID "$src"
}

build_cpio() {
	table=$1 voff=$2
	work=$(mktemp -d)
	mkdir -p "$work/kernel/firmware/acpi"
	python3 -I - "$table" "$voff" "$work/kernel/firmware/acpi/$(basename "$table" | tr A-Z a-z).aml" <<'PY'
import struct, sys
src, voff, dst = sys.argv[1], int(sys.argv[2]), sys.argv[3]
d = bytearray(open(src, 'rb').read())
assert d[voff - 1] == 0x0A and d[voff] == 0x10, "flag is not 0x10"
d[voff] = 0x00
struct.pack_into('<I', d, 24, struct.unpack_from('<I', d, 24)[0] + 1)  # bump OEM revision
d[9] = 0
d[9] = (-sum(d)) & 0xFF                                                  # fix checksum
open(dst, 'wb').write(d)
PY
	(cd "$work" && find kernel | bsdcpio -o -H newc --quiet) > "$work/$CPIO_NAME"
	cp "$work/$CPIO_NAME" "$LIB/$CPIO_NAME"
	rm -rf "$work"
}

install_acpi() {
	[ -f "$CFG" ] || die "$CFG not found (is this SteamOS?)"
	info=$(find_flag) || die "'$KEY' not found in ACPI tables; this fix does not apply"
	set -- $info
	case $3 in
	10)
		note "ACPI: found $KEY=0x10 in $1, building override"
		build_cpio "$1" "$2"
		;;
	00)
		# The override is already active (this boot used it).
		[ -f "$LIB/$CPIO_NAME" ] || [ -f "$EFI/$CPIO_NAME" ] ||
			die "$KEY is already 0 but no override is installed; unexpected firmware"
		[ -f "$LIB/$CPIO_NAME" ] || cp "$EFI/$CPIO_NAME" "$LIB/$CPIO_NAME"
		note "ACPI: override already active"
		;;
	*) die "$KEY=0x$3, expected 0x10; not touching it" ;;
	esac

	cp "$LIB/$CPIO_NAME" "$EFI/$CPIO_NAME"
	if grep -q "$CPIO_NAME" "$CFG"; then
		note "ACPI: boot entry already patched"
	else
		uuid=$(efi_partuuid)
		cp "$CFG" "$CFG.pre-ally-audio-fix"
		sed -i "s|^\(\s*\)initrd\t|\1search --no-floppy --part-uuid --set=acpidev $uuid\n\1initrd\t(\$acpidev)/$CPIO_NAME |" "$CFG"
		if ! grub-script-check "$CFG"; then
			cp "$CFG.pre-ally-audio-fix" "$CFG"
			die "edited grub.cfg failed syntax check; restored original"
		fi
		grep -q "$CPIO_NAME" "$CFG" || die "no initrd lines found in $CFG"
		note "ACPI: patched boot entries:"
		grep -n "$CPIO_NAME" "$CFG"
	fi
}

# --- 2: layout module ----------------------------------------------------------------

install_module() {
	src=$(module_source) || die "no $MODNAME for kernel $KVER.
Build one first (as your normal user, no sudo): $0 build"
	if [ -f "$(dirname "$src")/SHA256SUMS" ]; then
		(cd "$(dirname "$src")" && sha256sum -c --quiet SHA256SUMS) || die "checksum mismatch for $src"
	fi
	vm=$(modinfo -F vermagic "$src" | awk '{print $1}')
	[ "$vm" = "$KVER" ] || die "$src is for kernel $vm, running $KVER"
	mkdir -p "$LIB/modules/$KVER"
	cp "$src" "$LIB/modules/$KVER/$MODNAME"
	note "module: installed for $KVER"
}

# --- 3: amp tuning files -------------------------------------------------------------

speaker_id() {
	[ -r "$SPEAKER_ID_VAR" ] || return 1
	# 4 bytes of EFI attributes, then the value
	od -An -tu4 -j4 -N4 "$SPEAKER_ID_VAR" | tr -d ' '
}

install_firmware() {
	id=$(speaker_id) || die "BIOS SPEAKER_ID variable not found; can't tell which speakers this unit has"
	case $id in
	0) vendor=JGX ;;
	1) vendor=LS ;;
	*) die "unexpected SPEAKER_ID $id" ;;
	esac
	note "firmware: SPEAKER_ID=$id ($vendor speakers)"
	mkdir -p "$LIB/firmware"
	tmp=$(mktemp)
	for uid in 8 B; do
		# linux-firmware names: <ssid>-<speaker id>-<link>-0x<uid>
		# the driver requests:  <ssid>-<link>-0x<uid>
		src="$SSID-$id-0-0x$uid.bin"
		dst="$SSID-0-0x$uid.bin"
		curl -fsSL -o "$tmp" "$FW_URL/$src?id=$FW_COMMIT" || die "download of $src failed"
		echo "$(fw_sha256 "$src")  $tmp" | sha256sum -c --quiet || die "checksum mismatch for $src"
		install -m 0644 "$tmp" "$LIB/firmware/$dst"
		echo "    $src -> $LIB/firmware/$dst"
	done
	rm -f "$tmp"
}

# --- 4: UCM speaker profile ----------------------------------------------------------

install_ucm() {
	sys=/usr/share/alsa/ucm2
	if [ -f "$sys/sof-soundwire/tas2783.conf" ]; then
		note "UCM: SteamOS already ships tas2783.conf; no overlay needed"
		rm -f "$ENVCONF"
		rm -rf "$LIB/ucm2"
		return
	fi
	# A tree of symlinks to the system files, so SteamOS updates to them still apply,
	# plus the one missing profile.
	rm -rf "$LIB/ucm2"
	mkdir -p "$LIB/ucm2/sof-soundwire"
	for f in "$sys"/*; do
		[ "$(basename "$f")" = sof-soundwire ] || ln -s "$f" "$LIB/ucm2/"
	done
	for f in "$sys"/sof-soundwire/*; do
		ln -s "$f" "$LIB/ucm2/sof-soundwire/"
	done
	install -m 0644 "$REPO/ucm/tas2783.conf" "$LIB/ucm2/sof-soundwire/tas2783.conf"
	mkdir -p "$(dirname "$ENVCONF")"
	echo "ALSA_CONFIG_UCM2=$LIB/ucm2" > "$ENVCONF"
	note "UCM: overlay at $LIB/ucm2"
}

# --- hooks that load 2 and 3 at boot -------------------------------------------------

install_hooks() {
	cat > "$HOOK" <<EOF
#!/bin/sh
# Installed by ally-audio-fix.sh. Called by modprobe (see $MODCONF).
LIB=$LIB
case \$1 in
match)
	# Use the module with the Ally X20 layout if one was built for this kernel;
	# otherwise fall back to the stock module (speakers stay off, nothing breaks).
	m=\$LIB/modules/\$(uname -r)/$MODNAME
	if [ -f "\$m" ]; then
		/usr/bin/modprobe snd_soc_sdca && /usr/bin/insmod "\$m" && exit 0
	fi
	exec /usr/bin/modprobe --ignore-install snd_soc_acpi_amd_match
	;;
tas2783)
	# Let the amp driver find its tuning files.
	p=/sys/module/firmware_class/parameters/path
	if [ -w "\$p" ] && [ -z "\$(cat "\$p")" ]; then
		printf %s "\$LIB/firmware" > "\$p"
	fi
	exec /usr/bin/modprobe --ignore-install snd_soc_tas2783_sdw
	;;
esac
EOF
	chmod 0755 "$HOOK"
	cat > "$MODCONF" <<EOF
# Installed by ally-audio-fix.sh; remove with "ally-audio-fix.sh uninstall".
install snd_soc_acpi_amd_match /bin/sh $HOOK match
install snd_soc_tas2783_sdw /bin/sh $HOOK tas2783
EOF
	note "hooks: $MODCONF"

	if lsinitcpio "/boot/initramfs-$(pacman -Qqo "/usr/lib/modules/$KVER/vmlinuz").img" 2>/dev/null |
		grep -q 'snd-soc-acpi-amd-match'; then
		echo "warning: the initramfs contains the audio modules, so the hooks may not run" >&2
	fi
}

# --- commands ------------------------------------------------------------------------

cmd_install() {
	need_root
	check_device
	echo "device: $(cat /sys/class/dmi/id/product_name), BIOS $(cat /sys/class/dmi/id/bios_version), kernel $KVER"
	mkdir -p "$LIB"
	# Check everything that can fail before changing the boot setup.
	module_source > /dev/null || die "no $MODNAME for kernel $KVER.
Build one first (as your normal user, no sudo): $0 build"
	install_firmware
	install_module
	install_ucm
	install_hooks
	install_acpi
	sync
	echo
	echo "Done. Reboot, then check with: sudo $0 status"
}

cmd_uninstall() {
	need_root
	if [ -f "$CFG" ] && grep -q "$CPIO_NAME" "$CFG"; then
		sed -i -e "/--set=acpidev /d" -e "s|(\$acpidev)/$CPIO_NAME ||" "$CFG"
		grub-script-check "$CFG"
	fi
	rm -f "$EFI/$CPIO_NAME" "$MODCONF" "$ENVCONF"
	rm -rf "$LIB"
	sync
	echo "Removed from this slot. Reboot to apply."
}

cmd_status() {
	echo "device:    $(cat /sys/class/dmi/id/product_name) (BIOS $(cat /sys/class/dmi/id/bios_version))"
	echo "kernel:    $KVER"
	if [ -n "$ACP" ]; then
		drv=$(readlink "/sys/bus/pci/devices/$ACP/driver" 2>/dev/null || true)
		echo "ACP:       $ACP driver=$(basename "${drv:-none}")"
	fi
	if [ "$(id -u)" = 0 ]; then
		info=$(find_flag) || info="- - ??"
		set -- $info
		echo "ACPI flag: $KEY=0x$3 ($(dmesg | grep -q 'Table Upgrade: override' && echo override active || echo no override))"
		echo "boot cfg:  $(grep -c "$CPIO_NAME" "$CFG" 2>/dev/null || echo 0) patched entries"
		echo "speakers:  SPEAKER_ID=$(speaker_id || echo '?')"
	else
		echo "(run with sudo for ACPI and boot details)"
	fi
	m=$LIB/modules/$KVER/$MODNAME
	if [ ! -f "$m" ]; then
		echo "module:    none installed for this kernel (stock layout table)"
	elif [ "$(cat /sys/module/snd_soc_acpi_amd_match/srcversion 2>/dev/null)" = "$(modinfo -F srcversion "$m")" ]; then
		echo "module:    patched layout table loaded"
	else
		echo "module:    installed but not loaded (reboot?)"
	fi
	echo "firmware:  $(ls "$LIB/firmware" 2>/dev/null | tr '\n' ' ')"
	echo "UCM:       $(cat "$ENVCONF" 2>/dev/null || echo 'system default')"
	card=$(grep -l amdsoundwire /proc/asound/card*/id 2>/dev/null | head -1)
	if [ -n "$card" ]; then
		echo "card:      $(amixer -c "$(basename "$(dirname "$card")" | tr -dc 0-9)" info 2>/dev/null | sed -n 's/.*Components\s*: //p')"
	fi
	aplay -l 2>/dev/null | grep '^card' | sed 's/^/           /'
}

cmd_build() {
	[ "$(id -u)" != 0 ] || die "run build as your normal user (it uses rootless podman, stored in your home)"
	command -v podman > /dev/null || die "podman not found"
	pkg=$(pacman -Qo "/usr/lib/modules/$KVER/vmlinuz" | awk '{print $(NF-1), $NF}')
	set -- $pkg
	name=$1 ver=$2
	# 7.2.7-valve2-... -> v7.2.7; 7.2.0-... -> v7.2
	base=${KVER%%-*}
	case $base in *.0) base=${base%.0} ;; esac
	out="$REPO/build-out/$KVER"
	mkdir -p "$HOME/.cache"
	work=$(mktemp -d "$HOME/.cache/ally-audio-build.XXXXXX")
	trap 'rm -rf "$work"' EXIT
	note "kernel package $name $ver, upstream v$base"

	hdr="$name-headers-$ver-x86_64.pkg.tar.zst"
	mirror=https://steamdeck-packages.steamos.cloud/archlinux-mirror
	for repo in $(sed -n 's/^\[\(.*\)\]$/\1/p' /etc/pacman.conf | grep -v options); do
		curl -fsSL -o "$work/$hdr" "$mirror/$repo/os/x86_64/$hdr" 2>/dev/null && break
	done
	[ -s "$work/$hdr" ] || die "could not download $hdr"
	note "downloaded $hdr"
	mkdir -p "$work/hdr"
	tar --zstd -xf "$work/$hdr" -C "$work/hdr"

	mkdir -p "$work/src/amd/acp"
	for f in $KSRC_FILES; do
		curl -fsSL -o "$work/src/${f#sound/soc/}" "$KSRC_URL/$f?h=v$base" || die "download of $f failed"
	done
	cp "$REPO/patches/0001-ASoC-amd-acp70-add-TAS2783-x2-on-link-0-with-RT721-on-link-1.patch" "$work/layout.patch"
	cat > "$work/src/amd/acp/Makefile" <<'EOF'
snd-soc-acpi-amd-match-y := amd-acp63-acpi-match.o amd-acp70-acpi-match.o soc-acpi-amd-sdca-quirks.o
obj-m += snd-soc-acpi-amd-match.o
EOF
	note "building in an Arch Linux container (first run downloads ~500 MB)"
	podman run --rm -v "$work:/w:Z" docker.io/library/archlinux:latest sh -c "
		pacman -Sy --noconfirm --needed base-devel bc kmod libelf pahole zstd > /dev/null &&
		{ (cd /w/src && patch -s -p3 < /w/layout.patch) ||
		  { echo 'patch does not apply to v$base; the kernel source changed' >&2; exit 1; }; } &&
		make -s -C /w/hdr/usr/lib/modules/$KVER/build M=/w/src/amd/acp modules" ||
		die "build failed"
	m="$work/src/amd/acp/$MODNAME"
	[ "$(modinfo -F vermagic "$m" | awk '{print $1}')" = "$KVER" ] || die "built module has the wrong vermagic"
	[ "$(modinfo -F depends "$m")" = "$(modinfo -F depends snd_soc_acpi_amd_match)" ] ||
		echo "warning: module dependencies differ from the stock module" >&2
	strings "$m" | grep -q acp70_tas2783x2_l0u8b_rt721_l1u0 || die "built module lacks the new layout"
	mkdir -p "$out"
	cp "$m" "$out/"
	(cd "$out" && sha256sum "$MODNAME" > SHA256SUMS)
	note "built $out/$MODNAME"
	echo "Now run: sudo $0 install"
}

case ${1:-} in
install) cmd_install ;;
uninstall) cmd_uninstall ;;
status) cmd_status ;;
build) cmd_build ;;
*)
	echo "usage: sudo $0 install|status|uninstall"
	echo "       $0 build    (no sudo; after a kernel update)"
	exit 1
	;;
esac

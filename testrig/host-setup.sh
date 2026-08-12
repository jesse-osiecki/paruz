#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# testrig/host-setup.sh — idempotent, re-runnable bootstrap for the paruz
# disposable test rig (see testrig/README.md). Prints what it changes and
# asks before touching system state. Mirrors bin/paruz-setup's own style,
# deliberately: every step is grep/existence-guarded and safe to re-run.
#
# This is HOST setup — it prepares the machine to run libvirt/QEMU VMs.
# It never touches /etc/pacman.conf, ~/.config/paru/paru.conf, or any of
# the real paruz state paths; that's exactly what the VM boundary is for.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=testrig/config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=testrig/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DRY_RUN=0
YES=0
CHECK_ONLY=0

usage() {
	cat <<'EOF'
testrig/host-setup.sh — prepare this host to run the paruz disposable test rig

Usage: host-setup.sh [--dry-run] [--yes] [--check] [-h|--help]

  --dry-run   print what would change without doing it
  --yes, -y   don't prompt; assume yes to every step
  --check     read-only: report OK/MISSING per requirement, change nothing.
              Used by build-base.sh/run.sh as a fast preflight; exits
              non-zero if anything is missing.
EOF
}

while (( $# > 0 )); do
	case "$1" in
		--dry-run) DRY_RUN=1; shift ;;
		--yes|-y) YES=1; shift ;;
		--check) CHECK_ONLY=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

run() {
	if (( DRY_RUN )); then
		printf '%s[dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$(printf '%q ' "$@")" >&2
		return 0
	fi
	"$@"
}

confirm_step() {
	local prompt="$1" default="${2:-y}"
	(( YES )) && return 0
	confirm "$prompt" "$default"
}

MISSING=0
report_check() {
	local name="$1" ok="$2"
	if (( ok )); then
		printf '  OK       %s\n' "$name"
	else
		printf '  MISSING  %s\n' "$name"
		MISSING=1
	fi
}

# --- individual checks (each returns 0/1, no side effects) -----------------

check_platform() { command -v pacman >/dev/null 2>&1; }
check_kvm() { [[ -r /dev/kvm && -w /dev/kvm ]]; }
check_pkg_qemu_img() { command -v qemu-img >/dev/null 2>&1; }
check_pkg_qemu_system() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
check_pkg_virt_install() { command -v virt-install >/dev/null 2>&1; }
check_pkg_isogen() { command -v xorriso >/dev/null 2>&1 || command -v genisoimage >/dev/null 2>&1; }
check_libvirtd_active() { systemctl is-active --quiet libvirtd; }
check_group_membership() { id -nG | tr ' ' '\n' | grep -qx libvirt; }
check_default_network() { virsh_ net-info default >/dev/null 2>&1 && [[ "$(virsh_ net-info default 2>/dev/null | awk -F': +' '/^Active/{print $2}')" == yes ]]; }
check_image_dir() {
	[[ -d "$VM_IMAGE_DIR" ]] || return 1
	local perm; perm=$(stat -c '%a' "$VM_IMAGE_DIR")
	local grp; grp=$(stat -c '%G' "$VM_IMAGE_DIR")
	[[ "$grp" == libvirt && "$perm" == 2775 ]]
}
check_state_dir() { [[ -d "$STATE_DIR" && -d "$SSH_DIR" && -d "$LOG_DIR" ]]; }
check_ssh_key() { [[ -r "$SSH_KEY" && -r "$SSH_KEY.pub" ]]; }

# --- check-only mode ---------------------------------------------------------

if (( CHECK_ONLY )); then
	echo "testrig host-setup — preflight check"
	report_check "Arch host (pacman present)"        "$(check_platform && echo 1 || echo 0)"
	report_check "/dev/kvm accessible"                "$(check_kvm && echo 1 || echo 0)"
	report_check "qemu-img on PATH"                   "$(check_pkg_qemu_img && echo 1 || echo 0)"
	report_check "qemu-system-x86_64 on PATH"          "$(check_pkg_qemu_system && echo 1 || echo 0)"
	report_check "virt-install on PATH"                "$(check_pkg_virt_install && echo 1 || echo 0)"
	report_check "cloud-init ISO generator (xorriso/genisoimage)" "$(check_pkg_isogen && echo 1 || echo 0)"
	report_check "libvirtd active"                     "$(check_libvirtd_active && echo 1 || echo 0)"
	report_check "current user in 'libvirt' group"     "$(check_group_membership && echo 1 || echo 0)"
	report_check "libvirt 'default' NAT network active" "$(check_default_network && echo 1 || echo 0)"
	report_check "$VM_IMAGE_DIR (mode 2775, group libvirt)" "$(check_image_dir && echo 1 || echo 0)"
	report_check "$STATE_DIR (ssh/, logs/)"             "$(check_state_dir && echo 1 || echo 0)"
	report_check "dedicated ssh keypair ($SSH_KEY)"     "$(check_ssh_key && echo 1 || echo 0)"
	if (( MISSING )); then
		echo
		echo "some requirements are missing — run 'testrig/host-setup.sh' (without --check) to fix them"
		exit 1
	fi
	ok "all requirements satisfied"
	exit 0
fi

# --- interactive/fixing mode -------------------------------------------------

setup_check_platform() {
	log "step 1/9: platform"
	check_platform || die "pacman not found — this rig targets an Arch host (matches paruz itself)"
}

setup_check_kvm() {
	log "step 2/9: /dev/kvm"
	if check_kvm; then
		log "  accessible"
		return 0
	fi
	die "/dev/kvm is missing or not accessible — enable virtualization in firmware/BIOS and ensure the kvm kernel module is loaded (lsmod | grep kvm), and that you're in the 'kvm' group if /dev/kvm isn't world-writable"
}

setup_packages() {
	log "step 3/9: qemu/virt-install packages"
	local missing=()
	check_pkg_qemu_img       || missing+=(qemu-img)
	check_pkg_qemu_system    || missing+=(qemu-system-x86)
	check_pkg_virt_install   || missing+=(virt-install)
	check_pkg_isogen         || missing+=(libisoburn) # provides xorriso
	if (( ${#missing[@]} == 0 )); then
		log "  all present"
		return 0
	fi
	warn "missing packages: ${missing[*]}"
	confirm_step "Install via 'sudo pacman -S --needed ${missing[*]}'?" y \
		|| die "required packages missing: ${missing[*]}"
	run sudo pacman -S --needed --noconfirm "${missing[@]}"
}

setup_libvirtd() {
	log "step 4/9: libvirtd"
	if check_libvirtd_active; then
		log "  active"
		return 0
	fi
	confirm_step "Enable and start libvirtd ('sudo systemctl enable --now libvirtd')?" y \
		|| die "libvirtd must be active"
	run sudo systemctl enable --now libvirtd
}

setup_group() {
	log "step 5/9: libvirt group membership"
	if check_group_membership; then
		log "  $USER is already in the libvirt group"
		return 0
	fi
	confirm_step "Add $USER to the 'libvirt' group ('sudo usermod -aG libvirt $USER')?" y \
		|| die "$USER must be in the libvirt group to manage VMs without root"
	run sudo usermod -aG libvirt "$USER"
	warn "group membership only takes effect in a NEW login session — log out/in (or 'newgrp libvirt' in this shell), then re-run host-setup.sh"
	exit 0
}

setup_network() {
	log "step 6/9: libvirt 'default' NAT network"
	if check_default_network; then
		log "  already active"
		return 0
	fi
	if ! virsh_ net-info default >/dev/null 2>&1; then
		die "libvirt 'default' network not defined — unusual for a fresh libvirt install; check /etc/libvirt/qemu/networks/default.xml exists, or 'virsh net-define' it from libvirt's own template"
	fi
	run virsh_ net-start default
	run virsh_ net-autostart default
}

setup_image_dir() {
	log "step 7/9: $VM_IMAGE_DIR"
	if check_image_dir; then
		log "  already configured"
		return 0
	fi
	# Group-writable + setgid so an unprivileged member of 'libvirt' (this
	# user) can create/delete VM disk files directly, while libvirtd's
	# dynamic_ownership (default on) still chowns the active disk to
	# libvirt-qemu:kvm whenever the domain starts (see README
	# "Why /var/lib/libvirt").
	confirm_step "Create $VM_IMAGE_DIR (root:libvirt, mode 2775, via sudo)?" y \
		|| die "$VM_IMAGE_DIR is required to hold VM disk images"
	run sudo install -d -o root -g libvirt -m 2775 "$VM_IMAGE_DIR"
}

setup_state_dir() {
	log "step 8/9: $STATE_DIR"
	ensure_state_dirs
	log "  ready"
}

setup_ssh_key() {
	log "step 9/9: dedicated ssh keypair"
	if check_ssh_key; then
		log "  already present ($SSH_KEY)"
		return 0
	fi
	log "  generating a rig-only ed25519 keypair (never touches ~/.ssh)"
	run ssh-keygen -t ed25519 -N '' -C paruz-testrig -f "$SSH_KEY" -q
}

main() {
	setup_check_platform
	setup_check_kvm
	setup_packages
	setup_libvirtd
	setup_group
	setup_network
	setup_image_dir
	setup_state_dir
	setup_ssh_key
	ok "host-setup complete — run testrig/build-base.sh next"
}

main

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# testrig/teardown.sh — best-effort, confirmed removal of everything the
# rig created: the libvirt domain, its disk(s), the cached base image, and
# host-side rig state (ssh keys, logs). Mirrors bin/paruz-setup --uninstall's
# style: destructive, prompts per step unless --yes.
#
# Deliberately does NOT touch: the libvirt 'default' network or libvirtd
# itself (shared host infra you may use for other VMs), or anything under
# /etc/pacman.conf, ~/.config/paru, /var/lib/repo, /var/lib/aurbuild on
# THIS host — the rig never touches those in the first place (that's the
# point of running the live tier inside a VM).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=testrig/config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=testrig/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

YES=0
KEEP_CACHE=0
while (( $# > 0 )); do
	case "$1" in
		--yes|-y) YES=1; shift ;;
		--keep-cache) KEEP_CACHE=1; shift ;;
		-h|--help)
			cat <<'EOF'
Usage: teardown.sh [--yes] [--keep-cache]

  --yes, -y      don't prompt; remove everything
  --keep-cache   keep the cached base cloud image (skip re-download on the
                 next build-base.sh run) while still removing the domain,
                 its disk, and rig state
EOF
			exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

confirm_step() {
	local prompt="$1" default="${2:-n}"
	(( YES )) && return 0
	confirm "$prompt" "$default"
}

if domain_exists; then
	if confirm_step "Destroy and undefine the '$VM_NAME' domain?" y; then
		domain_running && virsh_ destroy "$VM_NAME" >/dev/null 2>&1
		virsh_ undefine "$VM_NAME" --nvram --snapshots-metadata >/dev/null 2>&1 || true
		ok "domain removed"
	fi
else
	log "no '$VM_NAME' domain defined"
fi

if [[ -d "$VM_IMAGE_DIR" ]]; then
	if confirm_step "Remove VM disk images under $VM_IMAGE_DIR (keeps the directory itself)?" y; then
		if (( KEEP_CACHE )); then
			find "$VM_IMAGE_DIR" -maxdepth 1 -type f ! -name "$(basename "$BASE_IMAGE_CACHE")" -delete
			log "removed disk/ISO files, kept cached base image"
		else
			find "$VM_IMAGE_DIR" -maxdepth 1 -type f -delete
			ok "removed all files under $VM_IMAGE_DIR (including the cached base image)"
		fi
	fi
	if confirm_step "Also remove the directory $VM_IMAGE_DIR itself (needs sudo)?" n; then
		sudo rmdir "$VM_IMAGE_DIR" 2>&1 || warn "couldn't remove $VM_IMAGE_DIR (not empty or permission denied) — leaving it"
	fi
fi

if [[ -d "$STATE_DIR" ]]; then
	if confirm_step "Remove rig state ($STATE_DIR — ssh keypair, logs)?" y; then
		rm -rf "$STATE_DIR"
		ok "removed $STATE_DIR"
	fi
fi

ok "teardown steps complete (skipped steps left untouched) — the host's own paruz install/config was never touched"

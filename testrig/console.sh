#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# testrig/console.sh — get a shell in the (running) paruz-testrig VM, for
# debugging a failed live-tier test. Defaults to SSH (reliable, scrollback,
# copy-paste); pass --serial to attach to the VM's serial console instead
# (useful if networking itself is broken, e.g. debugging an I2 network-off
# test gone wrong at the VM-boot level).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=testrig/config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=testrig/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MODE=ssh
while (( $# > 0 )); do
	case "$1" in
		--serial) MODE=serial; shift ;;
		--ssh) MODE=ssh; shift ;;
		-h|--help)
			cat <<'EOF'
Usage: console.sh [--ssh|--serial]

  --ssh     (default) SSH into the VM as the rig's guest user.
  --serial  attach to the VM's serial console via `virsh console`
            (Ctrl-] to detach). Useful if the network itself is what's
            broken (e.g. debugging a network-off build test).
EOF
			exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

domain_exists || die "no $VM_NAME domain — run testrig/build-base.sh first"

if ! domain_running; then
	warn "$VM_NAME is not running"
	confirm "Start it now?" y || die "VM not running"
	virsh_ start "$VM_NAME" >/dev/null
fi

if [[ "$MODE" == serial ]]; then
	log "attaching to serial console (Ctrl-] to detach)"
	virsh -c "$LIBVIRT_URI" console "$VM_NAME"
else
	ip=$(vm_ip) || ip=$(wait_for_ip 60) || die "couldn't determine the VM's IP — try --serial instead"
	log "ssh $GUEST_USER@$ip (guest sudo is passwordless)"
	exec ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip"
fi

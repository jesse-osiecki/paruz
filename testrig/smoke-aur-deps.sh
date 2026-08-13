#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# testrig/smoke-aur-deps.sh — validate paruz's AUR-DEPENDENCY handling (PLAN.md
# §7) against real packages inside the disposable VM. Each target here depends
# on at least one package that lives in the AUR (not the official repos), so
# installing it drives build_handle_unresolved — the v1 "warned, networked
# fallback" that builds uninstalled AUR deps via paru --noinstall and injects
# them into the target's hardened, network-off build.
#
# For each target it asserts:
#   - the target ends up installed (pacman -Qi)
#   - its AUR dependency was actually built into the local [aur] repo
#   - the §7 fallback path is what handled it (log shows the NETWORKED-fallback
#     notice, not some other route)
#
# Same auto-approval caveat as smoke-aur.sh: paruz's human gate is answered
# over an SSH pty (confirm() fails closed on a non-tty). Known packages only.
# Everything happens inside the throwaway VM; nothing touches the host.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=testrig/config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=testrig/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# target -> an AUR dependency it pulls in (the one we assert got built). All
# verified AUR-only (not official-repo collisions) at authoring time.
TARGETS=(
	"perl-date-range=perl-date-simple"
	"perl-html-treebuilder-xpath=perl-xml-xpathengine"
	"perl-spreadsheet-writeexcel=perl-ole-storage-lite"
	"perl-spreadsheet-xlsx=perl-spreadsheet-parseexcel"
	"patool=python-setuptools-reproducible"
)

AUTO_YES=0
KEEP_DISK=0

usage() {
	cat <<'EOF'
Usage: smoke-aur-deps.sh [--yes] [--keep-disk]

Installs a fixed set of real AUR packages that each have an AUR dependency,
validating PLAN.md §7 (build_handle_unresolved) end-to-end in the VM.

  --yes, -y     revert automatically on success without prompting
  --keep-disk   leave the VM running at the end even on success

Auto-approves paruz's review gate — validation of known packages only.
EOF
}

while (( $# > 0 )); do
	case "$1" in
		--yes|-y) AUTO_YES=1; shift ;;
		--keep-disk) KEEP_DISK=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1 (see --help)" ;;
	esac
done

ensure_state_dirs
"$SCRIPT_DIR/host-setup.sh" --check \
	|| die "host prerequisites not satisfied — run 'testrig/host-setup.sh' first"
if ! domain_exists || ! snapshot_exists; then
	die "no '$SNAPSHOT_NAME' snapshot for $VM_NAME yet — run 'testrig/build-base.sh' first"
fi

START_TS=$(date +%s)
elapsed() { printf '%ds' "$(( $(date +%s) - START_TS ))"; }
RUN_ID=$(date +%Y%m%d-%H%M%S)
RUN_LOG_DIR="$LOG_DIR/smoke-deps-$RUN_ID"
mkdir -p "$RUN_LOG_DIR"
log "logs for this run: $RUN_LOG_DIR"

log "reverting $VM_NAME to snapshot '$SNAPSHOT_NAME'"
domain_running && virsh_ destroy "$VM_NAME" >/dev/null 2>&1 || true
virsh_ snapshot-revert "$VM_NAME" "$SNAPSHOT_NAME" >/dev/null
log "starting $VM_NAME"
virsh_ start "$VM_NAME" >/dev/null
rm -f "$KNOWN_HOSTS"
log "waiting for DHCP lease + SSH (elapsed $(elapsed))"
ip=$(wait_for_ip 60) || die "VM never got a DHCP lease after revert"
wait_for_ssh "$ip" 90 || die "SSH never came up after revert on $ip"
ok "VM ready at $ip (elapsed $(elapsed))"

log "syncing current working tree into the guest ($GUEST_REPO_DIR)"
rsync_to_guest "$ip" "$REPO_ROOT" "$GUEST_REPO_DIR"

warn "================================================================"
warn "AUTO-APPROVING paruz's review gate for the §7 dep test targets"
warn "(known packages only — real usage must review these by hand)."
warn "================================================================"

paruz_in_guest() {
	local args="$1" logfile="$2" rc=0
	# Bounded 'y' feed over a pty for paruz's gate prompts; pacman installs run
	# --noconfirm, so no pacman prompts need answering here.
	printf 'y\ny\ny\ny\ny\n' \
		| ssh -tt "${SSH_OPTS[@]}" "$GUEST_USER@$ip" \
			"cd '$GUEST_REPO_DIR' && ./bin/paruz $args" 2>&1 \
		| tee "$logfile" \
		|| rc=$?
	return "$rc"
}

FAILED=0
pass() { ok "PASS  $*"; }
fail() { err "FAIL  $*"; FAILED=1; }

for entry in "${TARGETS[@]}"; do
	target="${entry%%=*}"
	dep="${entry##*=}"
	logfile="$RUN_LOG_DIR/$target.log"
	echo
	log "=== $target (expects AUR dep: $dep) ==="

	rc=0
	paruz_in_guest "-S $target" "$logfile" || rc=$?
	if (( rc != 0 )); then
		fail "$target: paruz -S exited $rc (see $logfile)"
		continue
	fi

	if ssh_guest "$ip" "pacman -Qi '$target'" >/dev/null 2>&1; then
		pass "$target: installed (pacman -Qi)"
	else
		fail "$target: exited 0 but NOT in the pacman DB"
	fi

	if ssh_guest "$ip" "ls /var/lib/repo/aur/${dep}-*.pkg.tar.zst" >/dev/null 2>&1; then
		pass "$target: AUR dep '$dep' was built into the local [aur] repo"
	else
		fail "$target: AUR dep '$dep' not found in /var/lib/repo/aur (§7 fallback didn't build it?)"
	fi

	if grep -qiE 'NETWORKED fallback|uninstalled AUR dependency' "$logfile"; then
		pass "$target: §7 fallback path (build_handle_unresolved) fired"
	else
		warn "$target: didn't see the §7 fallback notice in the log — dep may have resolved another way; inspect $logfile"
	fi
done

echo
if (( FAILED )); then
	err "§7 AUR-dependency validation FAILED (elapsed $(elapsed)) — VM left running at $ip"
	warn "shell in: testrig/console.sh   logs: $RUN_LOG_DIR"
	exit 1
fi
ok "§7 AUR-dependency validation PASSED — all ${#TARGETS[@]} targets installed via the fallback (elapsed $(elapsed))"

if (( KEEP_DISK )); then
	log "leaving $VM_NAME running (--keep-disk)"
	exit 0
fi
do_cleanup=1
if (( ! AUTO_YES )); then
	confirm "Shut down $VM_NAME and revert to the clean snapshot now?" y || do_cleanup=0
fi
if (( do_cleanup )); then
	log "shutting down and reverting $VM_NAME to '$SNAPSHOT_NAME'"
	ssh_guest "$ip" 'sudo shutdown -h now' || true
	wait_for_shutdown 60 || virsh_ destroy "$VM_NAME" >/dev/null 2>&1 || true
	virsh_ snapshot-revert "$VM_NAME" "$SNAPSHOT_NAME" >/dev/null
	ok "clean — $VM_NAME is shut off and reverted to '$SNAPSHOT_NAME'"
fi
exit 0

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# testrig/run.sh — one disposable test cycle: revert the paruz-testrig VM
# to its golden "provisioned" snapshot, push the CURRENT working tree into
# it, run the repo's own tests/run.sh (fast) and tests/run.sh --live
# inside the guest, report pass/fail, and (by default) tidy up. Exits
# non-zero if any test failed — usable as a CI gate.
#
# Nothing here can touch the host's real /etc/pacman.conf,
# ~/.config/paru/paru.conf, /var/lib/repo/aur, or /var/lib/aurbuild — the
# live tier runs entirely inside the guest. That is a structural property
# of using a separate VM, not something this script has to enforce.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=testrig/config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=testrig/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

FAST_ONLY=0
AUTO_YES=0
KEEP_DISK=0
REBUILD_FIRST=0

usage() {
	cat <<'EOF'
Usage: run.sh [--fast-only] [--rebuild-base] [--yes] [--keep-disk]

  --fast-only     run only tests/run.sh (skip --live: no chroot builds/installs)
  --rebuild-base  run build-base.sh --rebuild-base first (slow; see README)
  --yes, -y       don't prompt for the end-of-run cleanup; clean up
                  automatically on a passing run (for CI use)
  --keep-disk     never revert/clean up the disk at the end, even on pass
                  (useful if you want to poke around after a green run)
EOF
}

while (( $# > 0 )); do
	case "$1" in
		--fast-only) FAST_ONLY=1; shift ;;
		--rebuild-base) REBUILD_FIRST=1; shift ;;
		--yes|-y) AUTO_YES=1; shift ;;
		--keep-disk) KEEP_DISK=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1 (see --help)" ;;
	esac
done

ensure_state_dirs
"$SCRIPT_DIR/host-setup.sh" --check \
	|| die "host prerequisites not satisfied — run 'testrig/host-setup.sh' first"

if (( REBUILD_FIRST )); then
	"$SCRIPT_DIR/build-base.sh" --rebuild-base
fi

if ! domain_exists || ! snapshot_exists; then
	die "no '$SNAPSHOT_NAME' snapshot for $VM_NAME yet — run 'testrig/build-base.sh' first (one-time, slow; see README)"
fi

START_TS=$(date +%s)
elapsed() { printf '%ds' "$(( $(date +%s) - START_TS ))"; }

RUN_ID=$(date +%Y%m%d-%H%M%S)
RUN_LOG_DIR="$LOG_DIR/run-$RUN_ID"
mkdir -p "$RUN_LOG_DIR"
log "logs for this cycle: $RUN_LOG_DIR"

# --- revert to golden snapshot, start fresh ---------------------------------

log "reverting $VM_NAME to snapshot '$SNAPSHOT_NAME'"
if domain_running; then
	virsh_ destroy "$VM_NAME" >/dev/null 2>&1 || true
fi
virsh_ snapshot-revert "$VM_NAME" "$SNAPSHOT_NAME" >/dev/null

log "starting $VM_NAME"
virsh_ start "$VM_NAME" >/dev/null
rm -f "$KNOWN_HOSTS" # revert restores the golden host key; drop any stale entry

log "waiting for DHCP lease + SSH (elapsed $(elapsed))"
ip=$(wait_for_ip 60) || die "VM never got a DHCP lease after revert — debug with 'virsh -c $LIBVIRT_URI console $VM_NAME'"
printf '%s\n' "$ip" > "$LAST_IP_FILE"
wait_for_ssh "$ip" 90 || die "SSH never came up after revert on $ip — debug with testrig/console.sh"
ok "VM ready at $ip (elapsed $(elapsed))"

# --- push the CURRENT working tree, not the tree baked into the snapshot ----

log "syncing current working tree into the guest ($GUEST_REPO_DIR)"
rsync_to_guest "$ip" "$REPO_ROOT" "$GUEST_REPO_DIR"

# --- run the repo's own test entrypoint, unmodified -------------------------

RC=0

run_tier() {
	local label="$1" remote_args="$2" logfile="$RUN_LOG_DIR/$3.log"
	log "running tests/run.sh $remote_args (tier: $label)"
	local tier_rc=0
	ssh_guest "$ip" "cd $GUEST_REPO_DIR && ./tests/run.sh $remote_args" 2>&1 | tee "$logfile" || tier_rc=$?
	if (( tier_rc == 0 )); then
		ok "$label tier: PASS (log: $logfile)"
	else
		err "$label tier: FAIL (exit $tier_rc) — log: $logfile"
		RC=1
	fi
}

if (( FAST_ONLY )); then
	run_tier fast "" fast
else
	run_tier live "--live" live
fi

echo
if (( RC == 0 )); then
	ok "all tiers passed (elapsed $(elapsed))"
else
	err "one or more tiers failed (elapsed $(elapsed))"
fi

# --- end-of-run disk cleanup -------------------------------------------------
#
# On failure we deliberately do NOT shut down or revert: the whole point
# of a live-tier failure is a subtle security property, not a boolean, so
# the VM is left running for debugging (see README "debugging a failed
# live test" — testrig/console.sh / ssh in directly).

if (( RC != 0 )); then
	warn "leaving $VM_NAME running for debugging (it will NOT be cleaned up automatically)"
	warn "shell in with: testrig/console.sh   (or: ssh ${SSH_OPTS[*]} $GUEST_USER@$ip)"
	warn "next 'testrig/run.sh' will revert this VM to the clean snapshot, discarding this state"
	exit 1
fi

if (( KEEP_DISK )); then
	log "leaving $VM_NAME running (--keep-disk)"
	exit 0
fi

do_cleanup=1
if (( ! AUTO_YES )); then
	confirm "Tests passed. Shut down $VM_NAME and revert its disk to the clean snapshot now?" y \
		|| do_cleanup=0
fi

if (( do_cleanup )); then
	log "shutting down and reverting $VM_NAME to '$SNAPSHOT_NAME'"
	ssh_guest "$ip" 'sudo shutdown -h now' || true
	wait_for_shutdown 60 || virsh_ destroy "$VM_NAME" >/dev/null 2>&1 || true
	virsh_ snapshot-revert "$VM_NAME" "$SNAPSHOT_NAME" >/dev/null
	ok "clean — $VM_NAME is shut off and reverted to '$SNAPSHOT_NAME'"
else
	log "leaving $VM_NAME as-is (still running) — next run will revert it"
fi

exit 0

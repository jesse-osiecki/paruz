#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# testrig/smoke-aur.sh — end-to-end smoke test of a REAL AUR install inside
# the disposable VM. Unlike tests/run.sh (which uses trivial local fixtures),
# this drives the actual user workflow against the live AUR:
#
#   phase 1  paruz -S <pkg>     fetch -> gate -> net-off build -> split install
#   phase 2  paruz -S <pkg>     re-run: exercises the §6.6 approved-commit
#                                snapshot / "no upstream changes" gate path
#   phase 3  paruz -Sua         AUR upgrade dispatch (paru -Qua detection)
#
# It asserts real outcomes (pacman -Qi succeeds, the built package landed in
# the local repo), not just exit codes.
#
# >>> IMPORTANT: this AUTO-APPROVES paruz's human review gate. <<<
# paruz's whole point is that a human reads every PKGBUILD/.install/maintainer
# change before building. This script answers "yes" to those prompts (over an
# SSH pseudo-tty, since paruz's confirm() fails closed on a non-tty) so the
# pipeline can be validated unattended against a KNOWN-GOOD package. That is a
# deliberate, scoped exception for VM validation — never a mode real usage
# should run in.
#
# All of it happens inside the throwaway VM; nothing touches the host.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=testrig/config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=testrig/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PKG=downgrade
AUTO_YES=0
KEEP_DISK=0

usage() {
	cat <<'EOF'
Usage: smoke-aur.sh [--pkg NAME] [--yes] [--keep-disk]

  --pkg NAME    AUR package to install end-to-end (default: downgrade — a
                small, trusted package with official-repo deps and no AUR deps)
  --yes, -y     don't prompt for end-of-run cleanup; revert automatically on
                success
  --keep-disk   leave the VM running at the end even on success (for poking)

Auto-approves paruz's review gate — validation of a known package only.
EOF
}

while (( $# > 0 )); do
	case "$1" in
		--pkg) PKG="$2"; shift 2 ;;
		--pkg=*) PKG="${1#*=}"; shift ;;
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
RUN_LOG_DIR="$LOG_DIR/smoke-$RUN_ID"
mkdir -p "$RUN_LOG_DIR"
log "logs for this smoke run: $RUN_LOG_DIR"

# --- revert to golden snapshot, boot, sync current tree ---------------------

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
warn "AUTO-APPROVING paruz's human review gate for '$PKG' (VM validation"
warn "of a known package only — real usage must review these by hand)."
warn "================================================================"

# paruz_in_guest ARGS LOGFILE — run ./bin/paruz with the given args in the
# guest over an SSH pty, feeding 'y' to any tty-gated confirm() prompt. Tees
# to LOGFILE and returns paruz's exit code.
paruz_in_guest() {
	local args="$1" logfile="$2" rc=0
	# -tt forces a remote pty so paruz's confirm() (which fails closed on a
	# non-tty) actually reads our answers. A generous run of 'y' covers the
	# single first-install approval with margin.
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

# --- phase 1: real install --------------------------------------------------

echo
log "=== phase 1: paruz -S $PKG (real fetch/gate/build/install) ==="
rc=0
paruz_in_guest "-S $PKG" "$RUN_LOG_DIR/install.log" || rc=$?
if (( rc != 0 )); then
	fail "phase 1: paruz -S $PKG exited $rc (see $RUN_LOG_DIR/install.log)"
else
	if ssh_guest "$ip" "pacman -Qi '$PKG'" >/dev/null 2>&1; then
		pass "phase 1: $PKG is installed (pacman -Qi succeeds)"
	else
		fail "phase 1: paruz exited 0 but $PKG is NOT in the pacman DB"
	fi
	if ssh_guest "$ip" "ls /var/lib/repo/aur/${PKG}-*.pkg.tar.zst" >/dev/null 2>&1; then
		pass "phase 1: built package landed in the local [aur] repo"
	else
		fail "phase 1: no built ${PKG}-*.pkg.tar.zst in /var/lib/repo/aur"
	fi
	# The install log should show the scriptlet-split having classified the
	# official-repo deps (pacman-contrib/fzf for downgrade) — a light check
	# that §6.4 actually ran, not a hard gate.
	if grep -qiE 'repo dep|WITHOUT scriptlets|noscriptlet' "$RUN_LOG_DIR/install.log"; then
		pass "phase 1: scriptlet-split install path exercised (I4 messaging present)"
	else
		warn "phase 1: didn't see scriptlet-split messaging in the log — inspect $RUN_LOG_DIR/install.log"
	fi
fi

# --- phase 2: re-run exercises the approved-commit / no-change gate ----------

echo
log "=== phase 2: paruz -S $PKG again (approved-commit snapshot / no-change gate) ==="
rc=0
paruz_in_guest "-S $PKG" "$RUN_LOG_DIR/reinstall.log" || rc=$?
if (( rc != 0 )); then
	fail "phase 2: re-run exited $rc (see $RUN_LOG_DIR/reinstall.log)"
elif grep -qiE 'no upstream changes|no PKGBUILD/.install|no .* changes' "$RUN_LOG_DIR/reinstall.log"; then
	pass "phase 2: gate recognized the previously-approved commit (no-change path)"
else
	warn "phase 2: re-run succeeded but didn't clearly log the no-change path — inspect $RUN_LOG_DIR/reinstall.log"
fi

# --- phase 3: AUR upgrade dispatch ------------------------------------------

echo
log "=== phase 3: paruz -Sua (AUR upgrade dispatch) ==="
rc=0
paruz_in_guest "-Sua" "$RUN_LOG_DIR/upgrade.log" || rc=$?
if (( rc != 0 )); then
	fail "phase 3: paruz -Sua exited $rc (see $RUN_LOG_DIR/upgrade.log)"
else
	pass "phase 3: AUR upgrade path dispatched cleanly (exit 0)"
fi

# --- summary + cleanup ------------------------------------------------------

echo
if (( FAILED )); then
	err "smoke test FAILED (elapsed $(elapsed)) — VM left running at $ip for debugging"
	warn "shell in: testrig/console.sh   logs: $RUN_LOG_DIR"
	exit 1
fi
ok "smoke test PASSED — real $PKG install validated end-to-end (elapsed $(elapsed))"

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

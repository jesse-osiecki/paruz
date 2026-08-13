#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# testrig/smoke-packaged.sh — validate the PACKAGED install path in the VM:
# build paruz from the PKGBUILD (a fresh clone of the public repo), install it
# as a pacman package, then run paruz-setup and a real install using the
# packaged binary. This is the exact sequence you'd run on a real machine, so
# it closes the last gap the source-checkout smoke tests don't cover:
#
#   * `makepkg -si` builds via the Makefile (build/check/package) and installs
#   * the packaged /usr/bin/paruz resolves its libs from /usr/lib/paruz/lib
#   * paruz-setup, run from /usr/bin, takes its is_source_checkout=false branch
#     (files already placed by the package — it must NOT re-symlink anything)
#   * a real `paruz -S <pkg>` works end-to-end via the packaged binary
#
# The provisioned snapshot already ran paruz-setup in *source-checkout* mode
# (dev symlinks in /usr/local/bin + unowned /etc/paruz, /usr/share/paruz). We
# strip those first, so this models a clean machine installing the package for
# the first time (and so pacman -U doesn't hit "file exists in filesystem").
#
# Same auto-approval caveat as the other smoke tests. All inside the VM.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=testrig/config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=testrig/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PKG=downgrade   # the real AUR package installed via the packaged binary
AUTO_YES=0
KEEP_DISK=0

usage() {
	cat <<'EOF'
Usage: smoke-packaged.sh [--pkg NAME] [--yes] [--keep-disk]

Builds+installs paruz as a pacman package from the PKGBUILD inside the VM,
then validates paruz-setup (packaged mode) and a real `paruz -S <pkg>`.

  --pkg NAME    package to install via the packaged binary (default: downgrade)
  --yes, -y     revert automatically on success without prompting
  --keep-disk   leave the VM running at the end even on success
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
RUN_LOG_DIR="$LOG_DIR/smoke-packaged-$RUN_ID"
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

FAILED=0
pass() { ok "PASS  $*"; }
fail() { err "FAIL  $*"; FAILED=1; }

# pty runner: feeds 'y' to paruz's tty-gated gate (packaged binary on PATH).
# Bounded feed for paruz's gate prompts; pacman installs run --noconfirm.
paruz_pty() {
	local args="$1" logfile="$2" rc=0
	printf 'y\ny\ny\ny\ny\n' \
		| ssh -tt "${SSH_OPTS[@]}" "$GUEST_USER@$ip" "paruz $args" 2>&1 \
		| tee "$logfile" || rc=$?
	return "$rc"
}

# --- strip the source-checkout dev install so this models a clean machine ---

log "removing source-checkout dev artifacts (simulating a fresh machine)"
ssh_guest "$ip" 'sudo rm -f \
	/usr/local/bin/paruz /usr/local/bin/paruz-setup \
	/usr/share/bash-completion/completions/paruz /usr/share/zsh/site-functions/_paruz \
	/etc/paruz/paruz.conf /usr/share/paruz/known-bad-packages.txt
	sudo rmdir /etc/paruz /usr/share/paruz 2>/dev/null || true' \
	|| die "failed to clean dev artifacts in guest"

# --- build + install the package via makepkg ---------------------------------

echo
log "=== building + installing the paruz package (makepkg -si, fresh clone) ==="
rc=0
ssh_guest "$ip" '
	set -e
	rm -rf ~/pkgbuild
	# git protocol (not raw.githubusercontent, which is CDN-cached and can lag
	# a push by minutes) — always the authoritative tip. This is also how a
	# user actually builds a -git package: clone the repo, then makepkg.
	git clone --depth 1 https://github.com/jesse-osiecki/paruz.git ~/pkgbuild
	cd ~/pkgbuild
	makepkg -si --noconfirm --needed
' 2>&1 | tee "$RUN_LOG_DIR/makepkg.log" || rc=$?
if (( rc != 0 )); then
	fail "makepkg -si exited $rc (see $RUN_LOG_DIR/makepkg.log)"
else
	pass "package built + installed via makepkg -si"
fi

# --- assert the packaged binary is the one on PATH and works -----------------

echo
log "=== validating the installed package ==="
whichpath=$(ssh_guest "$ip" 'command -v paruz' 2>/dev/null || true)
if [[ "$whichpath" == "/usr/bin/paruz" ]]; then
	pass "paruz on PATH resolves to the package (/usr/bin/paruz)"
else
	fail "paruz on PATH is '$whichpath' (expected /usr/bin/paruz)"
fi

if ssh_guest "$ip" 'pacman -Qo /usr/bin/paruz' >/dev/null 2>&1; then
	pass "/usr/bin/paruz is owned by a pacman package"
else
	fail "/usr/bin/paruz is not owned by any package"
fi

if ssh_guest "$ip" 'paruz --version' >/dev/null 2>&1; then
	pass "packaged paruz runs and resolves its libs (/usr/lib/paruz/lib)"
else
	fail "packaged paruz --version failed (lib resolution broken?)"
fi

# --- paruz-setup from /usr/bin must take the packaged (non-checkout) branch --

echo
log "=== paruz-setup in packaged mode (from /usr/bin) ==="
rc=0
ssh_guest "$ip" 'paruz-setup --yes' 2>&1 | tee "$RUN_LOG_DIR/setup.log" || rc=$?
if (( rc != 0 )); then
	fail "paruz-setup --yes exited $rc (see $RUN_LOG_DIR/setup.log)"
else
	pass "paruz-setup --yes completed"
fi
if grep -qiE 'installed via package|files already in place' "$RUN_LOG_DIR/setup.log"; then
	pass "paruz-setup detected packaged mode (did not re-symlink a checkout)"
else
	fail "paruz-setup did NOT report packaged mode — is_source_checkout misfired? (see $RUN_LOG_DIR/setup.log)"
fi

# --- real install using the packaged binary ---------------------------------

echo
log "=== real install via the packaged binary: paruz -S $PKG ==="
rc=0
paruz_pty "-S $PKG" "$RUN_LOG_DIR/install.log" || rc=$?
if (( rc != 0 )); then
	fail "paruz -S $PKG exited $rc (see $RUN_LOG_DIR/install.log)"
elif ssh_guest "$ip" "pacman -Qi '$PKG'" >/dev/null 2>&1; then
	pass "$PKG installed end-to-end via the packaged binary"
else
	fail "paruz -S $PKG exited 0 but $PKG is not installed"
fi

# --- summary + cleanup ------------------------------------------------------

echo
if (( FAILED )); then
	err "packaged-path validation FAILED (elapsed $(elapsed)) — VM left running at $ip"
	warn "shell in: testrig/console.sh   logs: $RUN_LOG_DIR"
	exit 1
fi
ok "packaged-path validation PASSED — makepkg build/install + packaged paruz-setup + real install all work (elapsed $(elapsed))"

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

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# testrig/build-base.sh — build (or rebuild) the paruz-testrig golden VM:
# download the Arch cloud image, boot it via virt-install --import +
# cloud-init, bootstrap an AUR helper, dogfood bin/paruz-setup, smoke-test
# with the fast tier, shut down, and take the "provisioned" external
# disk-only snapshot that testrig/run.sh reverts to before every cycle.
#
# Slow (see testrig/README.md for real timings) — run it once, then use
# testrig/run.sh for fast iteration. Only re-run (or pass --rebuild-base)
# when you need a truly fresh base, e.g. after editing cloud-init/*.tmpl
# or suspecting the golden snapshot itself is stale/broken.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=testrig/config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=testrig/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

REBUILD=0
REDOWNLOAD=0
while (( $# > 0 )); do
	case "$1" in
		--rebuild-base) REBUILD=1; shift ;;
		--redownload) REBUILD=1; REDOWNLOAD=1; shift ;;
		-h|--help)
			cat <<'EOF'
Usage: build-base.sh [--rebuild-base] [--redownload]

  --rebuild-base   destroy the existing domain/disk/snapshot and rebuild
                    from the (possibly cached) Arch cloud image.
  --redownload     like --rebuild-base, but also re-fetches the cloud
                    image instead of reusing the cached copy.
EOF
			exit 0 ;;
		*) die "unknown argument: $1 (see --help)" ;;
	esac
done

START_TS=$(date +%s)
elapsed() { printf '%ds' "$(( $(date +%s) - START_TS ))"; }

# --- preflight ---------------------------------------------------------

"$SCRIPT_DIR/host-setup.sh" --check \
	|| die "host prerequisites not satisfied — run 'testrig/host-setup.sh' (without --check) first"
ensure_state_dirs

if domain_exists && snapshot_exists && (( ! REBUILD )); then
	ok "$VM_NAME already has a '$SNAPSHOT_NAME' snapshot — nothing to do (pass --rebuild-base to redo)"
	exit 0
fi

# --- tear down any existing domain/disk before rebuilding -------------------

if domain_exists; then
	log "removing existing domain '$VM_NAME' before rebuild"
	if domain_running; then virsh_ destroy "$VM_NAME" >/dev/null 2>&1 || true; fi
	virsh_ undefine "$VM_NAME" --nvram --snapshots-metadata >/dev/null 2>&1 || true
fi
# Remove every disk-pool file EXCEPT the cached base image (the VM disk
# itself, any leftover snapshot-revert overlay, the cloud-init ISO). Using
# a name-based find rather than a fixed glob because libvirt names revert
# overlays with a random suffix (see README).
find "$VM_IMAGE_DIR" -maxdepth 1 -type f ! -name "$(basename "$BASE_IMAGE_CACHE")" -delete 2>/dev/null || true
(( REDOWNLOAD )) && rm -f "$BASE_IMAGE_CACHE"

# --- fetch + verify the base cloud image -------------------------------

CLEANUP_PATHS=()
cleanup() { local p; for p in "${CLEANUP_PATHS[@]:-}"; do [[ -n "$p" ]] && rm -rf "$p"; done; }
trap cleanup EXIT

if [[ ! -r "$BASE_IMAGE_CACHE" ]]; then
	log "downloading Arch cloud image (cached at $BASE_IMAGE_CACHE for future rebuilds)"
	tmp_img=$(mktemp "$VM_IMAGE_DIR/.download.XXXXXX.qcow2")
	CLEANUP_PATHS+=("$tmp_img")
	curl -fL --progress-bar -o "$tmp_img" "$CLOUD_IMAGE_URL"

	log "verifying SHA256 checksum against the mirror's published sum"
	sums=$(curl -fsSL "$CLOUD_IMAGE_SHA256_URL")
	expected=$(awk '{print $1; exit}' <<<"$sums")
	actual=$(sha256sum "$tmp_img" | awk '{print $1}')
	[[ -n "$expected" && "$expected" == "$actual" ]] \
		|| die "SHA256 mismatch on downloaded cloud image — expected $expected, got $actual (refusing to use a corrupt/tampered base image)"
	ok "checksum verified"

	if command -v gpg >/dev/null 2>&1; then
		log "attempting best-effort GPG signature verification (non-fatal if unavailable)"
		sig_tmp=$(mktemp)
		if curl -fsSL "$CLOUD_IMAGE_SIG_URL" -o "$sig_tmp" 2>/dev/null \
			&& timeout 15 gpg --batch --keyserver hkps://keyserver.ubuntu.com \
				--recv-keys "$CLOUD_IMAGE_SIGNING_FPR" >/dev/null 2>&1 \
			&& gpg --batch --verify "$sig_tmp" "$tmp_img" >/dev/null 2>&1; then
			ok "GPG signature verified (arch-boxes signing key)"
		else
			warn "GPG signature verification skipped/failed — proceeding on the SHA256 check alone (mirror is fetched over HTTPS)"
		fi
		rm -f "$sig_tmp"
	fi

	mv "$tmp_img" "$BASE_IMAGE_CACHE"
	chmod 0644 "$BASE_IMAGE_CACHE"
	CLEANUP_PATHS=() # tmp_img is gone (moved); nothing left to clean up from this block
else
	log "reusing cached base image $BASE_IMAGE_CACHE (pass --redownload to refetch)"
fi

# --- create the domain's writable overlay disk ------------------------------

log "creating ${VM_DISK_SIZE_GB}G COW overlay at $VM_DISK (backed by the cached base image)"
qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE_CACHE" "$VM_DISK" "${VM_DISK_SIZE_GB}G" >/dev/null
chmod 0644 "$VM_DISK"

# --- render cloud-init and define+start the domain --------------------------

setup_ssh_key_check() {
	[[ -r "$SSH_KEY.pub" ]] || die "no rig ssh keypair at $SSH_KEY — run testrig/host-setup.sh first"
}
setup_ssh_key_check

ci_dir=$(mktemp -d)
CLEANUP_PATHS+=("$ci_dir")
pubkey=$(cat "$SSH_KEY.pub")
sed "s|__SSH_PUBKEY__|$pubkey|" "$SCRIPT_DIR/cloud-init/user-data.tmpl" > "$ci_dir/user-data"
cp "$SCRIPT_DIR/cloud-init/meta-data.tmpl" "$ci_dir/meta-data"

log "defining and starting $VM_NAME via virt-install --import (elapsed $(elapsed))"
virt-install --connect "$LIBVIRT_URI" \
	--name "$VM_NAME" \
	--memory "$VM_MEMORY_MB" --vcpus "$VM_VCPUS" \
	--disk "path=$VM_DISK,format=qcow2,bus=virtio" \
	--import --os-variant "$OS_VARIANT" \
	--network network=default,model=virtio \
	--graphics none --console pty,target_type=serial \
	--cloud-init "user-data=$ci_dir/user-data,meta-data=$ci_dir/meta-data,disable=on" \
	--noautoconsole

rm -f "$KNOWN_HOSTS" # fresh VM => fresh host key; this file is rig-private (config.sh)

log "waiting for DHCP lease (elapsed $(elapsed))"
ip=$(wait_for_ip 120) || die "VM never got a DHCP lease from the libvirt 'default' network — check 'virsh console $VM_NAME' for boot errors"
printf '%s\n' "$ip" > "$LAST_IP_FILE"
log "VM is at $ip — waiting for cloud-init/sshd (elapsed $(elapsed))"
wait_for_ssh "$ip" 240 \
	|| die "SSH never came up on $ip — debug with: virsh -c $LIBVIRT_URI console $VM_NAME (Ctrl-] to exit)"
ok "SSH is up (elapsed $(elapsed))"

# --- remote provisioning ----------------------------------------------------
# Everything here is generic Arch/VM bring-up (keyring, base-devel, an AUR
# helper) that a real user would already have on their machine — it is
# NOT part of what PLAN.md asks paruz-setup to do, so it stays outside
# bin/paruz-setup and lives here instead. The AUR-specific provisioning
# (local repo, chroot, paru.conf, pacman.conf) is 100% delegated to the
# repo's own bin/paruz-setup below — that's the dogfooding requirement.

remote() {
	local desc="$1" cmd="$2" logfile="$LOG_DIR/build-base.$3.log"
	log "$desc (log: $logfile)"
	if ! ssh_guest "$ip" "$cmd" 2>&1 | tee "$logfile"; then
		die "$desc failed — see $logfile, or debug live with testrig/console.sh"
	fi
}

remote "initializing pacman keyring" \
	'sudo pacman-key --init && sudo pacman-key --populate archlinux' keyring

remote "full system upgrade (pacman -Syu)" \
	'sudo pacman -Syu --noconfirm' pacman-syu

remote "installing base-devel + git + rsync (AUR-helper bootstrap + repo transfer — the Arch cloud image ships neither)" \
	'sudo pacman -S --needed --noconfirm base-devel git rsync' base-devel

remote "bootstrapping paru from AUR (one-time, unhardened — same pattern PLAN.md section 8 uses for ks-aur-scanner)" \
	'rm -rf /tmp/paru-bootstrap && git clone --depth 1 https://aur.archlinux.org/paru.git /tmp/paru-bootstrap \
	 && cd /tmp/paru-bootstrap && makepkg -si --noconfirm' paru-bootstrap

log "copying repo into the guest ($GUEST_REPO_DIR)"
rsync_to_guest "$ip" "$REPO_ROOT" "$GUEST_REPO_DIR"

remote "running the repo's own bin/paruz-setup --yes (dogfooding)" \
	"cd $GUEST_REPO_DIR && ./bin/paruz-setup --yes" paruz-setup

remote "smoke-testing with the fast test tier before snapshotting" \
	"cd $GUEST_REPO_DIR && ./tests/run.sh" fast-smoke-test

log "shutting down cleanly (elapsed $(elapsed))"
ssh_guest "$ip" 'sudo shutdown -h now' || true
wait_for_shutdown 90 || die "VM didn't shut down in time — check 'virsh -c $LIBVIRT_URI list' and shut it down manually before retrying"

log "taking external disk-only snapshot '$SNAPSHOT_NAME'"
virsh_ snapshot-create-as --domain "$VM_NAME" "$SNAPSHOT_NAME" --disk-only --atomic >/dev/null

ok "base build complete in $(elapsed) — run testrig/run.sh for a test cycle"

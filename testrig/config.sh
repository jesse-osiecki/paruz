# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# testrig/config.sh — shared configuration for the paruz disposable test rig.
# Sourced by every testrig/*.sh script. Not meant to be run directly.

TESTRIG_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname "$TESTRIG_DIR")

LIBVIRT_URI=qemu:///system
VM_NAME=paruz-testrig
SNAPSHOT_NAME=provisioned

# --- disk-backed state ------------------------------------------------------
# Everything the qemu process itself must read/write (disk images, the
# cloud-init seed ISO) lives under /var/lib/libvirt/images/paruz-testrig, a
# libvirt-qemu-traversable directory that host-setup.sh creates once
# (group `libvirt`, setgid, 2775). It deliberately does NOT live under
# $HOME: a home directory is typically 0700, which the libvirt-qemu user
# can't even traverse, so qemu fails to open any disk placed there
# ("Permission denied" at VM start). See testrig/README.md for the reasoning.
VM_IMAGE_DIR=/var/lib/libvirt/images/paruz-testrig
BASE_IMAGE_CACHE="$VM_IMAGE_DIR/arch-cloudimg-base.qcow2"
VM_DISK="$VM_IMAGE_DIR/$VM_NAME.qcow2"
SEED_ISO="$VM_IMAGE_DIR/seed.iso"

# --- host-only state (never touched by the qemu process) -------------------
# Ordinary $HOME permissions are fine here.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/paruz-testrig"
SSH_DIR="$STATE_DIR/ssh"
SSH_KEY="$SSH_DIR/id_ed25519"
KNOWN_HOSTS="$STATE_DIR/known_hosts"
LOG_DIR="$STATE_DIR/logs"
LAST_IP_FILE="$STATE_DIR/last-ip"

# --- base image ---------------------------------------------------------
CLOUD_IMAGE_URL="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
CLOUD_IMAGE_SHA256_URL="${CLOUD_IMAGE_URL}.SHA256"
CLOUD_IMAGE_SIG_URL="${CLOUD_IMAGE_URL}.sig"
# arch-boxes image-signing key (arch-boxes <arch-boxes@archlinux.org>),
# verified against the .sig issuer fingerprint on the mirror at the time
# this rig was written. GPG verification is best-effort (§ README) — the
# SHA256 check is the one that hard-fails.
CLOUD_IMAGE_SIGNING_FPR=656E4C5AC1CC3B86E539D97E343635A6859A9174

OS_VARIANT=archlinux
# 8G is a hard floor, not a suggestion: compiling paru from AUR during
# build-base.sh links a single LTO'd release binary (codegen-units=1,
# debuginfo=2) that needs real headroom. With 2G and 4G, the rustc process
# is prone to being SIGKILL'd by the guest OOM killer partway
# through the final `src/main.rs` link — rustc's RSS climbs past 3GB and
# guest swap (a fixed ~512M on the cloud image) doesn't cover the gap.
# Bump via PARUZ_TESTRIG_MEMORY_MB if your host has room for even more.
VM_MEMORY_MB="${PARUZ_TESTRIG_MEMORY_MB:-8192}"
VM_VCPUS="${PARUZ_TESTRIG_VCPUS:-4}"
VM_DISK_SIZE_GB="${PARUZ_TESTRIG_DISK_GB:-20}"

GUEST_USER=arch
GUEST_REPO_DIR="/home/$GUEST_USER/paruz"

# --- ssh -----------------------------------------------------------------
SSH_OPTS=(
	-o "UserKnownHostsFile=$KNOWN_HOSTS"
	-o StrictHostKeyChecking=accept-new
	-o ConnectTimeout=5
	-o BatchMode=yes
	-i "$SSH_KEY"
)

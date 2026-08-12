# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# testrig/lib/common.sh — logging, virsh/ssh wrappers, VM lifecycle helpers.
# Sourced after testrig/config.sh by every testrig/*.sh script. Assumes
# `set -euo pipefail` in the caller.

# --- colors (disabled when not a tty or NO_COLOR is set) -------------------

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
	C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'
	C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
	C_RED=''; C_YELLOW=''; C_GREEN=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi

log()  { printf '%s[testrig]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
warn() { printf '%s[testrig] WARNING:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
ok()   { printf '%s[testrig] OK:%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
err()  { printf '%s[testrig] ERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

# confirm PROMPT [default(y|n)] — non-interactive shells and EOF default to
# "no" (fail closed), matching paruz's own lib/common.sh convention.
confirm() {
	local prompt="$1" default="${2:-n}" reply suffix
	if [[ "$default" == y ]]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
	if [[ ! -t 0 ]]; then
		warn "non-interactive shell; defaulting '$prompt' to '$default'"
		reply="$default"
	else
		read -r -p "$prompt $suffix " reply || reply=""
		reply="${reply:-$default}"
	fi
	[[ "$reply" =~ ^[Yy] ]]
}

# --- virsh / paths ----------------------------------------------------------

virsh_() { virsh -c "$LIBVIRT_URI" "$@"; }

ensure_state_dirs() {
	mkdir -p "$SSH_DIR" "$LOG_DIR"
	chmod 700 "$SSH_DIR"
}

domain_exists() { virsh_ dominfo "$VM_NAME" >/dev/null 2>&1; }
domain_running() { [[ "$(virsh_ domstate "$VM_NAME" 2>/dev/null)" == running ]]; }
snapshot_exists() { virsh_ snapshot-info --domain "$VM_NAME" --snapshotname "$SNAPSHOT_NAME" >/dev/null 2>&1; }

# --- networking / ssh --------------------------------------------------------

# vm_mac — MAC address of the domain's (only) NIC, from its live/persistent XML.
vm_mac() {
	virsh_ domiflist "$VM_NAME" 2>/dev/null | awk 'NR>2 && NF{print $NF; exit}'
}

# vm_ip — current DHCP-leased IPv4 for the domain, via the libvirt `default`
# network's lease table (works whether or not qemu-guest-agent is installed
# in the guest — the Arch cloud image doesn't ship one by default).
vm_ip() {
	local mac ip
	mac=$(vm_mac) || return 1
	[[ -n "$mac" ]] || return 1
	ip=$(virsh_ net-dhcp-leases default 2>/dev/null \
		| awk -v m="$mac" 'tolower($0) ~ tolower(m){print $5}' \
		| tail -1 | cut -d/ -f1)
	[[ -n "$ip" ]] || return 1
	printf '%s\n' "$ip"
}

# wait_for_ip TIMEOUT_SECS — polls until the domain has a DHCP lease.
wait_for_ip() {
	local timeout="${1:-120}" waited=0 ip
	while (( waited < timeout )); do
		if ip=$(vm_ip); then printf '%s\n' "$ip"; return 0; fi
		sleep 2; waited=$((waited + 2))
	done
	return 1
}

# wait_for_ssh IP TIMEOUT_SECS — polls until sshd answers as $GUEST_USER.
wait_for_ssh() {
	local ip="$1" timeout="${2:-180}" waited=0
	while (( waited < timeout )); do
		if ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip" true 2>/dev/null; then
			return 0
		fi
		sleep 3; waited=$((waited + 3))
	done
	return 1
}

# wait_for_shutdown TIMEOUT_SECS — polls until the domain reaches "shut off".
wait_for_shutdown() {
	local timeout="${1:-60}" waited=0
	while (( waited < timeout )); do
		[[ "$(virsh_ domstate "$VM_NAME" 2>/dev/null)" == "shut off" ]] && return 0
		sleep 2; waited=$((waited + 2))
	done
	return 1
}

ssh_guest() {
	local ip="$1"; shift
	ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip" "$@"
}

# rsync_to_guest IP LOCAL_DIR REMOTE_DIR — one-way push, excludes VCS/build
# cruft. Used both for the one-time repo seed and for each run's refresh.
rsync_to_guest() {
	local ip="$1" local_dir="$2" remote_dir="$3"
	ssh_guest "$ip" "mkdir -p '$remote_dir'"
	rsync -az --delete \
		--exclude='.git/' --exclude='testrig/' \
		-e "ssh ${SSH_OPTS[*]}" \
		"$local_dir/" "$GUEST_USER@$ip:$remote_dir/"
}

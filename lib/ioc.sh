# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# lib/ioc.sh — IOC self-check (PLAN.md §6.0)
#
# Run once at start (loud) and lightly re-checked at the end (summary only).
# Everything here is advisory EXCEPT the eBPF rootkit-map check, which is a
# fail-closed CRITICAL abort (I7).

# ioc_check_rootkit_maps — greps `bpftool map list` for named maps used by
# known eBPF rootkits. Any hit means something plausibly ran as root and
# hid processes/files — treat the host as compromised and abort (I7).
ioc_check_rootkit_maps() {
	if ! command -v bpftool >/dev/null 2>&1; then
		warn "bpftool not found — skipping eBPF rootkit-map check (run 'paruz-setup' to install the 'bpf' package)"
		return 0
	fi

	local maps
	if ! maps=$(sudo bpftool map list 2>/dev/null); then
		warn "'sudo bpftool map list' failed — skipping eBPF rootkit-map check"
		return 0
	fi

	if grep -qiE 'hidden_pids|hidden_names|hidden_inodes' <<<"$maps"; then
		critical "eBPF rootkit indicator found (hidden_pids/hidden_names/hidden_inodes map present). \
A rootkit likely ran as root on this host. Rotate all credentials used on this machine and \
strongly consider reinstalling the OS. paruz refuses to continue."
	fi
	ok "no eBPF rootkit maps detected"
}

# ioc_check_known_bad — intersects installed packages with the known-bad
# list (§9.3). Advisory: warns loudly but never blocks (the list is
# point-in-time and incomplete).
ioc_check_known_bad() {
	local list="${KNOWN_BAD_LIST:-/usr/share/paruz/known-bad-packages.txt}"
	if [[ ! -r "$list" ]]; then
		warn "known-bad package list not found at $list — skipping"
		return 0
	fi

	local installed hit hits=()
	installed=$(pacman -Qq 2>/dev/null)
	while IFS= read -r hit; do
		[[ -z "$hit" || "$hit" == \#* ]] && continue
		if grep -qxF "$hit" <<<"$installed"; then
			hits+=("$hit")
		fi
	done < "$list"

	if (( ${#hits[@]} > 0 )); then
		warn "installed package(s) match the known-compromised list: ${hits[*]}"
		warn "investigate, rotate credentials used on this host, and consider reinstalling these packages"
	else
		ok "no known-compromised packages installed"
	fi
}

# ioc_check_installed_aur_audit — advisory `aur-scan system` summary.
ioc_check_installed_aur_audit() {
	if ! command -v aur-scan >/dev/null 2>&1; then
		warn "aur-scan not found — skipping installed-AUR audit"
		return 0
	fi
	log "running installed-AUR audit (aur-scan system)..."
	aur-scan system || warn "aur-scan system reported findings (advisory; see above)"
}

# ioc_self_check — entry point. FULL=1 runs everything (start-of-run);
# otherwise only the fast rootkit-map + known-bad checks run (end-of-run).
ioc_self_check() {
	local full="${1:-1}"
	[[ "${IOC:-1}" == 1 ]] || { log "IOC self-check disabled (IOC=0)"; return 0; }

	log "running IOC self-check..."
	ioc_check_rootkit_maps
	ioc_check_known_bad
	if [[ "$full" == 1 ]]; then
		ioc_check_installed_aur_audit
	fi
}

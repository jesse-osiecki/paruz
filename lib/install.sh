# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# lib/install.sh — scriptlet-split install + scriptlet read/gate (PLAN.md §6.4-6.5)
#
# Satisfies I4 (host install never runs a package's .install scriptlet) and
# I6 (sandbox replay is never a security gate — read + gate is the default).
#
# Driven by globals the caller (bin/paruz) sets before calling install_run:
#   ALL_AUR_NAMES      - every AUR pkgname/pkgbase built this run
#   EXPLICIT_AUR_FILES - built package files for user-requested targets
#   DEP_AUR_FILES      - built package files for AUR packages pulled in only
#                         as dependencies of a target
#   REPLAY_HOOK        - empty, or one of pre_install/post_install/
#                         pre_upgrade/post_upgrade/pre_remove/post_remove
#                         (validated by bin/paruz before being set)

REPO_INSTALL_DEPS=()

# install_split_closure — §6.4 step 1: full install closure for the AUR
# names built this run, minus the AUR names themselves, is the set of
# official-repo dependencies that must be installed separately (WITH
# scriptlets, since they're signed/trusted).
install_split_closure() {
	REPO_INSTALL_DEPS=()
	(( ${#ALL_AUR_NAMES[@]} == 0 )) && return 0

	local -a closure
	mapfile -t closure < <(pacman -Sp --print-format '%n' --needed "${ALL_AUR_NAMES[@]}" 2>/dev/null)

	local -A is_aur=()
	local n
	for n in "${ALL_AUR_NAMES[@]}"; do is_aur["$n"]=1; done
	for n in "${closure[@]}"; do
		[[ -n "${is_aur[$n]:-}" ]] || REPO_INSTALL_DEPS+=("$n")
	done
}

# install_repo_deps — §6.4 step 2: repo deps installed normally, scriptlets ON.
install_repo_deps() {
	if (( ${#REPO_INSTALL_DEPS[@]} == 0 )); then
		log "no official-repo dependency packages to install"
		return 0
	fi
	log "installing repo dep(s) WITH scriptlets (signed/trusted): ${REPO_INSTALL_DEPS[*]}"
	run sudo pacman -S --needed --asdeps --noconfirm "${REPO_INSTALL_DEPS[@]}"
}

# install_aur_packages — §6.4 step 3: AUR packages installed from the built
# files with --noscriptlet (I4). Explicit targets keep default (explicit)
# install reason; packages pulled in only as deps are marked --asdeps.
install_aur_packages() {
	if (( ${#EXPLICIT_AUR_FILES[@]} > 0 )); then
		log "installing explicit AUR target(s) WITHOUT scriptlets (I4): ${EXPLICIT_AUR_FILES[*]##*/}"
		run sudo pacman -U --noscriptlet --noconfirm "${EXPLICIT_AUR_FILES[@]}"
	fi
	if (( ${#DEP_AUR_FILES[@]} > 0 )); then
		log "installing AUR dependency package(s) WITHOUT scriptlets (I4): ${DEP_AUR_FILES[*]##*/}"
		run sudo pacman -U --noscriptlet --noconfirm --asdeps "${DEP_AUR_FILES[@]}"
	fi
}

# install_show_scriptlet PKGFILE — §6.5 steps 1-3: extract and display the
# skipped .INSTALL, list the functions it defines, and state plainly that
# they did not run. Default behavior: read + gate, never replay (I6).
install_show_scriptlet() {
	local pkgfile="$1" base script funcs
	base=$(basename "$pkgfile")

	if ! bsdtar -tf "$pkgfile" .INSTALL >/dev/null 2>&1; then
		log "$base: ships no .INSTALL scriptlet"
		return 0
	fi

	script=$(bsdtar -xOqf "$pkgfile" .INSTALL)
	# grep exits 1 when an .INSTALL defines none of these functions; `|| true`
	# keeps that from tripping `set -o pipefail` + `set -e` (=> funcs empty).
	funcs=$(grep -oE '^(pre_install|post_install|pre_upgrade|post_upgrade|pre_remove|post_remove)[[:space:]]*\(\)' <<<"$script" \
		| sed -E 's/\(\)$//' | tr '\n' ' ' || true)

	warn "$base: ships a .INSTALL scriptlet that was SKIPPED (I4). Functions defined: ${funcs:-none}"
	log "--- .INSTALL ($base) ---"
	printf '%s\n' "$script" >&2
	log "$base: these did NOT run on this host. Most legitimate .install side-effects (desktop-db, icon"
	log "cache, mkinitcpio, systemd-sysusers/tmpfiles, font/mime caches, ...) are already handled by"
	log "libalpm hooks regardless (PLAN.md §3.6)."
}

# install_replay_hook PKGFILE FN — §6.5 step 4: opt-in, advisory-only replay
# of a single scriptlet function in a cap-dropped, network-off bwrap
# sandbox. Never treated as a security signal (I6): Wave-2 payloads detect
# sandboxes/CI and stay dormant, so a "clean" replay proves nothing.
install_replay_hook() {
	local pkgfile="$1" fn="$2" base script tmp
	base=$(basename "$pkgfile")

	if [[ ! "$fn" =~ ^(pre_install|post_install|pre_upgrade|post_upgrade|pre_remove|post_remove)$ ]]; then
		die "internal error: invalid replay-hook function '$fn'"
	fi

	script=$(bsdtar -xOqf "$pkgfile" .INSTALL 2>/dev/null) || { warn "$base: no .INSTALL to replay"; return 0; }
	if ! grep -qE "^${fn}[[:space:]]*\(\)" <<<"$script"; then
		warn "$base: .INSTALL does not define $fn — nothing to replay"
		return 0
	fi

	warn "--replay-hook: ADVISORY ONLY (I6). Wave-2 payloads detect sandboxes/CI and stay dormant;"
	warn "a clean replay proves NOTHING and must NEVER be treated as approval."

	assert_tools bwrap
	tmp=$(mktemp -d)
	printf '%s\n' "$script" > "$tmp/.INSTALL"
	# $1/$fn below are the inner script's positional args, must not expand here
	# shellcheck disable=SC2016
	run bwrap --unshare-all --unshare-net --cap-drop ALL \
		--ro-bind / / --tmpfs /tmp --dev /dev --proc /proc --die-with-parent \
		--bind "$tmp" /tmp/paruz-replay \
		bash -c '. /tmp/paruz-replay/.INSTALL; declare -F "$1" >/dev/null && "$1"' _ "$fn" \
		|| warn "$base: replay of $fn exited non-zero (observation only — not a security signal)"
	rm -rf "$tmp"
}

# install_scriptlet_gate — runs install_show_scriptlet (and, if requested,
# install_replay_hook) for every AUR package installed this run.
install_scriptlet_gate() {
	local f
	for f in "${EXPLICIT_AUR_FILES[@]}" "${DEP_AUR_FILES[@]:-}"; do
		[[ -z "$f" ]] && continue
		install_show_scriptlet "$f"
		if [[ -n "${REPLAY_HOOK:-}" ]]; then
			install_replay_hook "$f" "$REPLAY_HOOK"
		fi
	done
}

# install_run — full §6.4-6.5 pipeline given the globals documented above.
install_run() {
	assert_tools pacman bsdtar
	install_split_closure
	install_repo_deps
	install_aur_packages
	install_scriptlet_gate
}

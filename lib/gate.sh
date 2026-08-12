# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# lib/gate.sh — fetch + maintainer + diff + static-scan gate (PLAN.md §6.1-6.2, §6.6)
#
# Satisfies I5 (every AUR install/upgrade passes the gate) and I7 (fail closed).
# Requires lib/common.sh to be sourced first. Uses $FAIL_ON, $WARN_ON,
# $ALLOW_MAINTAINER_CHANGE from config/CLI (see bin/paruz).

ORPHAN_MARK='«orphan»'

# display_file FILE — show a file for human review, preferring bat if present.
display_file() {
	local f="$1"
	[[ -e "$f" ]] || return 0
	log "--- $(basename "$f") ---"
	if command -v bat >/dev/null 2>&1; then
		bat --plain --paging=never --color=always "$f" >&2 || cat "$f" >&2
	else
		cat "$f" >&2
	fi
}

# gate_resolve_info PKG — queries the AUR RPC once; sets GATE_PKGBASE and
# GATE_MAINTAINER. Fails closed on any RPC error or unknown package (I7).
gate_resolve_info() {
	local pkg="$1" json count
	json=$(curl -fsS "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg") \
		|| die "AUR RPC lookup failed for '$pkg' (network issue?) — fail closed (I7)"
	count=$(jq -r '.resultcount // 0' <<<"$json")
	if [[ "$count" == "0" ]]; then
		die "'$pkg' not found in AUR via RPC — cannot gate; aborting (I7)"
	fi
	GATE_PKGBASE=$(jq -r '.results[0].PackageBase' <<<"$json")
	GATE_MAINTAINER=$(jq -r '.results[0].Maintainer // "«orphan»"' <<<"$json")
	[[ -n "$GATE_PKGBASE" && "$GATE_PKGBASE" != null ]] \
		|| die "could not resolve pkgbase for '$pkg' via AUR RPC"
}

# gate_fetch PKGBASE — clones/updates the AUR git repo via `paru -G` into the
# paruz work root. Echoes the clone directory on stdout.
gate_fetch() {
	local pkgbase="$1" workroot clonedir
	workroot=$(paruz_work_root)
	mkdir -p "$workroot"
	log "$pkgbase: fetching from AUR (paru -G)..."
	( cd "$workroot" && command paru -G "$pkgbase" ) >&2 \
		|| die "$pkgbase: 'paru -G' fetch failed"
	clonedir="$workroot/$pkgbase"
	[[ -d "$clonedir/.git" ]] \
		|| die "$pkgbase: expected git clone at $clonedir not found after fetch"
	printf '%s\n' "$clonedir"
}

# gate_maintainer PKGBASE MAINTAINER — hard-stops on any maintainer change,
# including orphan-adoption in either direction (I5). This is the direct
# defense against the orphan-adoption takeover vector (PLAN.md §1).
gate_maintainer() {
	local pkgbase="$1" current="${2:-$ORPHAN_MARK}"
	local approved_dir
	approved_dir="$(paruz_approved_dir)/$pkgbase"
	local maint_file="$approved_dir/maintainer"
	local stored=""
	[[ -r "$maint_file" ]] && stored=$(<"$maint_file")

	if [[ -z "$stored" ]]; then
		log "$pkgbase: first-time maintainer record: $current"
		return 0
	fi

	if [[ "$stored" != "$current" ]]; then
		warn "$pkgbase: maintainer changed: '$stored' -> '$current'"
		if [[ "$stored" == "$ORPHAN_MARK" || "$current" == "$ORPHAN_MARK" ]]; then
			warn "$pkgbase: this is an ORPHAN-ADOPTION event — the primary supply-chain takeover vector paruz defends against"
		fi
		if [[ "${ALLOW_MAINTAINER_CHANGE:-0}" == 1 ]]; then
			warn "$pkgbase: --allow-maintainer-change set — proceeding despite maintainer change"
			return 0
		fi
		die "$pkgbase: maintainer-change hard-stop (re-run with --allow-maintainer-change to override) — I5"
	fi
}

# gate_diff PKGBASE CLONEDIR — shows the PKGBUILD/.install diff since the
# last approved commit (or the full files on first install) and requires
# explicit approval. Escalates (extra confirmation) on security-sensitive
# changes. Default answer is always No (fail closed).
gate_diff() {
	local pkgbase="$1" clonedir="$2"
	local approved_dir
	approved_dir="$(paruz_approved_dir)/$pkgbase"
	local commit_file="$approved_dir/commit"
	local head
	head=$(git -C "$clonedir" rev-parse HEAD)

	if [[ ! -r "$commit_file" ]]; then
		log "$pkgbase: first-ever install — review required"
		display_file "$clonedir/PKGBUILD"
		local f
		for f in "$clonedir"/*.install; do
			[[ -e "$f" ]] && display_file "$f"
		done
		confirm "Approve $pkgbase for build?" n || die "$pkgbase: not approved — aborting (I5)"
		return 0
	fi

	local approved
	approved=$(<"$commit_file")
	if [[ "$approved" == "$head" ]]; then
		log "$pkgbase: no upstream changes since last approval ($approved)"
		return 0
	fi

	local diff
	diff=$(git -C "$clonedir" diff "$approved..$head" -- PKGBUILD '*.install' '*.sh' .SRCINFO 2>/dev/null || true)
	if [[ -z "$diff" ]]; then
		log "$pkgbase: no PKGBUILD/.install/.sh/.SRCINFO changes between $approved..$head"
		return 0
	fi

	log "$pkgbase: PKGBUILD/.install diff since last approval ($approved..$head):"
	printf '%s\n' "$diff" >&2

	local reasons=() added_lines removed_lines old_hosts new_hosts added_hosts
	if git -C "$clonedir" diff --name-status "$approved..$head" -- '*.install' | grep -qE '^[AM]'; then
		reasons+=("adds or modifies a .install scriptlet")
	fi
	if grep -q '^Binary files ' <<<"$diff"; then
		reasons+=("adds/changes a binary blob")
	fi
	added_lines=$(grep -E '^\+[^+]' <<<"$diff" || true)
	removed_lines=$(grep -E '^-[^-]' <<<"$diff" || true)
	old_hosts=$(grep -oE 'https?://[A-Za-z0-9.-]+' <<<"$removed_lines" | sort -u || true)
	new_hosts=$(grep -oE 'https?://[A-Za-z0-9.-]+' <<<"$added_lines" | sort -u || true)
	added_hosts=$(comm -13 <(printf '%s\n' "$old_hosts") <(printf '%s\n' "$new_hosts") 2>/dev/null | grep -v '^$' || true)
	if [[ -n "$added_hosts" ]] && grep -qi 'source' <<<"$added_lines"; then
		reasons+=("source=/checksum now points at a new host: $(tr '\n' ' ' <<<"$added_hosts")")
	fi

	if (( ${#reasons[@]} > 0 )); then
		warn "$pkgbase: ESCALATED — this diff touches security-sensitive surface:"
		local r
		for r in "${reasons[@]}"; do warn "  - $r"; done
	fi

	confirm "Approve this $pkgbase change for build?" n || die "$pkgbase: change not approved — aborting (I5)"

	if (( ${#reasons[@]} > 0 )); then
		confirm "This touches security-sensitive surface (see above). Really proceed with $pkgbase?" n \
			|| die "$pkgbase: escalated change not approved — aborting (I5)"
	fi
}

# gate_static_scan PKGBASE CLONEDIR — `aur-scan scan --fail-on` is the hard
# gate (I5); a separate non-fatal pass at WARN_ON surfaces lower-severity
# findings without blocking.
gate_static_scan() {
	local pkgbase="$1" clonedir="$2"
	local fail_on="${FAIL_ON:-critical}" warn_on="${WARN_ON:-high}"

	assert_tools aur-scan

	log "$pkgbase: running static scan (aur-scan scan --fail-on $fail_on)..."
	local out rc=0
	out=$(aur-scan scan "$clonedir" --fail-on "$fail_on" 2>&1) || rc=$?
	printf '%s\n' "$out" >&2
	if (( rc != 0 )); then
		die "$pkgbase: static scan found $fail_on+ severity findings — aborting (I5)"
	fi

	local warn_rc=0
	aur-scan scan "$clonedir" --fail-on "$warn_on" -q --format json >/dev/null 2>&1 || warn_rc=$?
	if (( warn_rc != 0 )); then
		warn "$pkgbase: static scan found $warn_on+ severity findings (see above) — review before proceeding"
	fi
	ok "$pkgbase: static scan passed at fail-on=$fail_on"
}

# gate_snapshot PKGBASE CLONEDIR MAINTAINER — records the approved commit +
# maintainer for the next run's diff/maintainer gate (§6.6). Call only after
# build + install + scriptlet-gate have all succeeded.
gate_snapshot() {
	local pkgbase="$1" clonedir="$2" maintainer="${3:-$ORPHAN_MARK}"
	local approved_dir
	approved_dir="$(paruz_approved_dir)/$pkgbase"
	mkdir -p "$approved_dir"
	git -C "$clonedir" rev-parse HEAD > "$approved_dir/commit"
	printf '%s\n' "$maintainer" > "$approved_dir/maintainer"
}

# gate_run PKG — full fetch+gate pipeline for one AUR target. Echoes:
#   PKGBASE CLONEDIR MAINTAINER
# on stdout (space-separated) for the caller to consume.
gate_run() {
	local pkg="$1"
	gate_resolve_info "$pkg"
	local pkgbase="$GATE_PKGBASE" maintainer="$GATE_MAINTAINER"

	local clonedir
	clonedir=$(gate_fetch "$pkgbase")

	gate_maintainer "$pkgbase" "$maintainer"
	gate_diff "$pkgbase" "$clonedir"
	gate_static_scan "$pkgbase" "$clonedir"

	ok "$pkgbase: gate passed"
	printf '%s %s %s\n' "$pkgbase" "$clonedir" "$maintainer"
}

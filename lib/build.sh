# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# lib/build.sh — network-off chroot build (PLAN.md §6.3, §7)
#
# Satisfies I2 (the build()/package() phase has no network) and I3 (the build
# never sees your secrets — nothing bind-mounts $HOME/~/.ssh/~/.gnupg;
# makechrootpkg and arch-nspawn do not either).
#
# I1 is a documented residual (PLAN.md §10): source download+verify runs
# `makepkg --verifysource` on the host, which sources the PKGBUILD (executes its
# global scope). That happens only AFTER the §6.2 gate (aur-scan + your review)
# approves the PKGBUILD, and makechrootpkg re-parses it on the host during the
# build regardless — so doing the fetch inside the chroot would not actually
# prevent host-side parsing, it would only duplicate it (and it broke PGP
# verification, which only works against your host keyring).
#
# Sets/uses these globals after build_classify_deps: REPO_DEPS, AUR_DEP_NAMES,
# UNRESOLVED_DEPS. Deliberately globals (not passed by value) — bash array
# passing is painful and this module is only ever driven by bin/paruz.

# build_srcinfo_deps CLONEDIR — union of depends/makedepends/checkdepends
# (all arch variants) from .SRCINFO, version constraints stripped.
build_srcinfo_deps() {
	local clonedir="$1"
	[[ -r "$clonedir/.SRCINFO" ]] || die "$clonedir/.SRCINFO missing (run makepkg --printsrcinfo upstream issue?)"
	grep -E '^[[:space:]]*(depends|makedepends|checkdepends)(_[A-Za-z0-9_]+)?[[:space:]]*=' "$clonedir/.SRCINFO" \
		| sed -E 's/^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*//' \
		| sed -E 's/[<>=].*$//' \
		| awk 'NF' | sort -u
}

# build_pkgnames CLONEDIR — all pkgname entries from .SRCINFO (split pkgs).
build_pkgnames() {
	local clonedir="$1"
	awk -F'= ' '/^pkgname = /{print $2}' "$clonedir/.SRCINFO"
}

# build_needs_build_net CLONEDIR — heuristic: does this package fetch its own
# dependencies at BUILD time (cargo/go/npm/pip/…)? Such builds can't run under
# the network-off model (I2); paruz offers a networked (still chroot/secret-
# isolated) build for them. Heuristic, so it can miss or over-match — it only
# drives an offer, and --allow-build-net / a declined prompt override it.
build_needs_build_net() {
	local clonedir="$1"
	local srcinfo="$clonedir/.SRCINFO" pkgbuild="$clonedir/PKGBUILD"
	# makedepends/depends that imply an online build-dep fetcher
	grep -qE '^[[:space:]]*(make)?depends([_[:alnum:]]*)?[[:space:]]*=[[:space:]]*(cargo|rust|rustup|go|nodejs|npm|yarn|pnpm|bun|deno|python-pip|python-installer|dotnet-sdk|dotnet-runtime|stack|cabal-install)([[:space:]<>=].*)?$' \
		"$srcinfo" 2>/dev/null && return 0
	# build-time fetch commands in the PKGBUILD itself
	grep -qE '\b(cargo[[:space:]]+(fetch|build|install|update|test)|go[[:space:]]+(build|get|mod|install|run)|GOPROXY|GOFLAGS|npm[[:space:]]+(ci|install|i)\b|yarn([[:space:]]+install)?|pnpm[[:space:]]+(install|i)\b|pip[[:space:]]+install|bun[[:space:]]+install|dotnet[[:space:]]+(restore|build|publish))' \
		"$pkgbuild" 2>/dev/null && return 0
	return 1
}

# build_latest_repo_file NAME — newest package file in the local [aur] repo
# whose pkgname is EXACTLY NAME, or empty if none. A glob like "${name}-*"
# is not enough: it also matches "${name}-debug-..." (makepkg emits a debug
# package) and prefix collisions like "${name}-something-...". A package
# filename is pkgname-pkgver-pkgrel-arch.pkg.tar.zst where pkgver/pkgrel/arch
# contain no dashes, so pkgname is the filename minus its last three
# dash-fields; compare that to NAME exactly.
build_latest_repo_file() {
	local name="$1" f base stem pkgname newest="" newest_t=0 t
	for f in "$AUR_REPO_DIR"/*.pkg.tar.zst; do
		[[ -e "$f" ]] || continue
		base=${f##*/}
		stem=${base%.pkg.tar.zst}   # pkgname-pkgver-pkgrel-arch
		pkgname=${stem%-*}          # drop arch
		pkgname=${pkgname%-*}       # drop pkgrel
		pkgname=${pkgname%-*}       # drop pkgver
		[[ "$pkgname" == "$name" ]] || continue
		t=$(stat -c %Y "$f" 2>/dev/null || echo 0)
		if (( t >= newest_t )); then newest_t=$t; newest="$f"; fi
	done
	[[ -n "$newest" ]] && printf '%s\n' "$newest"
}

# build_classify_deps CLONEDIR — split .SRCINFO deps into: REPO_DEPS (official
# repos, pre-installed into the chroot for the net-off build); AUR_DEP_NAMES
# (already built into the local [aur] repo, injected via `makechrootpkg -I`);
# UNRESOLVED_DEPS (not in any sync db — an unbuilt AUR dep or truly missing,
# handled by build_handle_unresolved).
#
# Resolution uses `pacman -Sddp --print-format '%r %n'`, which RESOLVES PROVIDES
# / virtual packages (cargo->rust, sh->bash, awk->gawk, java-runtime->jre...) —
# `pacman -Si` does not, and mis-classifying those as "missing" was killing real
# builds. `-Sdd` resolves only the target itself, not its transitive deps. We
# classify against what the FRESH chroot needs, independent of the host's
# installed set (a host-installed dep is still absent from the clean copy).
build_classify_deps() {
	local clonedir="$1" dep resolved repo name
	REPO_DEPS=(); AUR_DEP_NAMES=(); UNRESOLVED_DEPS=()
	while IFS= read -r dep; do
		[[ -z "$dep" ]] && continue
		resolved=$(pacman -Sddp --print-format '%r %n' "$dep" 2>/dev/null | head -1) || resolved=""
		repo=${resolved%% *}
		name=${resolved##* }
		if [[ -z "$resolved" ]]; then
			UNRESOLVED_DEPS+=("$dep")
		elif [[ "$repo" == "aur" ]]; then
			AUR_DEP_NAMES+=("$name")   # the actual [aur] pkg (dep may be a provide)
		else
			REPO_DEPS+=("$dep")        # official; pacman -S resolves the provide
		fi
	done < <(build_srcinfo_deps "$clonedir")
}

# build_handle_unresolved — for each name in UNRESOLVED_DEPS: if it exists in
# AUR, build it via the v1 fallback (§7): a NETWORKED, filesystem/secret-
# isolated `paru --noinstall --chroot --localrepo` build (I2 not guaranteed
# for this subtree — printed explicitly). If it's not in AUR either, fail
# closed. On success, promotes the name into AUR_DEP_NAMES.
build_handle_unresolved() {
	(( ${#UNRESOLVED_DEPS[@]} == 0 )) && return 0

	local dep really_aur=() truly_missing=()
	for dep in "${UNRESOLVED_DEPS[@]}"; do
		if curl -fsS "https://aur.archlinux.org/rpc/v5/info?arg[]=$dep" 2>/dev/null \
			| jq -e '.resultcount > 0' >/dev/null 2>&1; then
			really_aur+=("$dep")
		else
			truly_missing+=("$dep")
		fi
	done

	if (( ${#truly_missing[@]} > 0 )); then
		die "dependency not found in any repo, installed set, or AUR: ${truly_missing[*]} (I7)"
	fi

	if (( ${#really_aur[@]} > 0 )); then
		warn "uninstalled AUR dependency/ies not yet built locally: ${really_aur[*]}"
		warn "v1 scope (PLAN.md §7): building these via a NETWORKED fallback (paru --noinstall --chroot --localrepo)."
		warn "This subtree is filesystem/secret-isolated but I2 (network-off build) is NOT guaranteed for it."
		warn "Packages built WITH network for this reason: ${really_aur[*]}"
		run command paru -S --noinstall --chroot --localrepo --noconfirm "${really_aur[@]}" \
			|| die "networked fallback build failed for: ${really_aur[*]}"
		run sudo pacman -Sy
		AUR_DEP_NAMES+=("${really_aur[@]}")
	fi
}

# build_sync_copy COPYNAME — (re)creates the chroot working copy from the
# pristine root so provisioning starts from a clean, known state.
build_sync_copy() {
	local copyname="$1" root="$AUR_CHROOT_ROOT/root"
	local copy="$AUR_CHROOT_ROOT/$copyname"
	if [[ -d "$copy" ]]; then
		log "$copyname: removing stale chroot copy"
		run sudo rm -rf "$copy"
	fi
	log "$copyname: syncing fresh chroot copy from pristine root"
	if findmnt -no FSTYPE "$AUR_CHROOT_ROOT" 2>/dev/null | grep -qx btrfs; then
		run sudo btrfs subvolume snapshot "$root" "$copy" >/dev/null
	else
		run sudo cp -a --reflink=auto "$root" "$copy"
	fi
}

# build_provision_repo_deps COPYNAME — install official-repo deps into the
# copy WITH network (I2 only constrains the build phase, not provisioning), so
# the later network-off makechrootpkg finds them present and needs no network.
build_provision_repo_deps() {
	local copyname="$1"
	(( ${#REPO_DEPS[@]} == 0 )) && return 0
	log "$copyname: provisioning repo deps (network ON): ${REPO_DEPS[*]}"
	run sudo arch-nspawn "$AUR_CHROOT_ROOT/$copyname" pacman -Sy --needed --noconfirm "${REPO_DEPS[@]}"
}

# build_provision_sources CLONEDIR — download + verify sources on the HOST,
# with network, as the invoking user, into the shared source pool, BEFORE the
# network-off build. Running on the host (not in the chroot) is deliberate:
# PGP signatures then verify against YOUR gpg keyring — exactly what
# makechrootpkg's own download_sources does. VERIFICATION IS FULL — no
# --skipinteg, no --skippgpcheck: a bad checksum, a bad signature, or an
# unknown/missing key fails the build closed (that is the point of the tool).
# --holdver only pins VCS sources so the later network-off re-verify won't try
# to fetch "latest"; it does not weaken integrity.
#
# This sources the PKGBUILD (runs its global scope) on the host — the I1
# residual (PLAN.md §10). It happens only after the §6.2 gate approved the
# PKGBUILD, and makechrootpkg re-parses it on the host during the build anyway.
# build_ensure_srcpool — the shared source pool must exist and be writable by
# the invoking user: makepkg writes sources there as that user in BOTH build
# modes (net-off via build_provision_sources; net-on via makechrootpkg's own
# download_sources). paruz-setup also sets this up, but a networked build skips
# build_provision_sources, so make it certain here for every build.
build_ensure_srcpool() {
	local build_user="${SUDO_USER:-$(id -un)}"
	run sudo mkdir -p "$AUR_SRCPOOL"
	run sudo chown "$build_user:$build_user" "$AUR_SRCPOOL"
}

build_provision_sources() {
	local clonedir="$1"
	build_ensure_srcpool
	log "downloading + verifying sources on the host (network ON, your gpg keyring)"
	# makepkg refuses to run as root, so this runs as the invoking user (whose
	# keyring holds the maintainer keys, like a normal `makepkg`/`paru` build).
	if ! ( cd "$clonedir" && run env SRCDEST="$AUR_SRCPOOL" makepkg --verifysource --holdver ); then
		die "source download/verification failed (see above). If it is an unknown PGP key, \
import it (e.g. 'gpg --recv-keys <keyid>') and re-run — paruz verifies against your keyring, \
it does not skip the check (I7)."
	fi
}

# build_do_build NETMODE COPYNAME CLONEDIR AUR_DEP_FILE... — run makechrootpkg.
# NETMODE=off (default, I2): the outer `unshare -n` strips the network namespace
# before makechrootpkg/arch-nspawn runs, so build()/package() have no network.
# NETMODE=on: no unshare — build()/package() have network (I2 explicitly waived,
# see build_target); still chroot- and secret-isolated (I3), and makechrootpkg
# fetches sources+deps and verifies PGP itself in this mode.
# AUR deps already built (this run or previously) are injected as files via
# `-I` — no [aur] repo needs to be configured inside the chroot.
#
# makechrootpkg internally passes --skipinteg to the in-chroot build's makepkg
# (a devtools default, not something paruz adds). In NETMODE=off it is NOT a
# weakening: sources were already fully verified — checksums AND PGP — on the
# host in build_provision_sources, and makechrootpkg's own host-side
# download_sources re-verifies against your keyring before the build; --skipinteg
# only avoids a third, redundant re-hash of already-verified sources. In
# NETMODE=on, makechrootpkg's download_sources performs that same full host-side
# verification (checksums + PGP) with network available.
build_do_build() {
	local netmode="$1" copyname="$2" clonedir="$3"
	shift 3
	local -a aur_dep_files=("$@")

	local -a cmd=(env "SRCDEST=$AUR_SRCPOOL" "PKGDEST=$AUR_REPO_DIR" \
		makechrootpkg -r "$AUR_CHROOT_ROOT" -l "$copyname")
	local f
	for f in "${aur_dep_files[@]}"; do
		cmd+=(-I "$f")
	done
	cmd+=(-- --holdver)

	if [[ "$netmode" == on ]]; then
		log "$copyname: building WITH network (I2 waived): ${cmd[*]}"
		( cd "$clonedir" && run sudo -- "${cmd[@]}" )
	else
		log "$copyname: building with network OFF (I2): ${cmd[*]}"
		( cd "$clonedir" && run sudo unshare -n -- bash -c \
			'ip link set lo up 2>/dev/null; exec "$@"' _ "${cmd[@]}" )
	fi
}

# build_repo_add PKGNAME... — repo-add the just-built package files and
# refresh the host sync db so subsequent targets in this run can see them.
build_repo_add() {
	local -a pkgnames=("$@") files=()
	local n f
	for n in "${pkgnames[@]}"; do
		f=$(build_latest_repo_file "$n")
		[[ -n "$f" ]] && files+=("$f")
	done
	(( ${#files[@]} > 0 )) || die "build produced no package file(s) for: ${pkgnames[*]}"
	run sudo repo-add "$AUR_REPO_DIR/aur.db.tar.zst" "${files[@]}"
	run sudo pacman -Sy
	printf '%s\n' "${files[@]}"
}

# build_target PKGBASE CLONEDIR — full build pipeline for one gated target.
# Echoes the built package file path(s) on stdout, one per line.
build_target() {
	local pkgbase="$1" clonedir="$2"
	assert_tools makechrootpkg arch-nspawn repo-add pacman makepkg unshare

	log "$pkgbase: classifying dependencies from .SRCINFO"
	build_classify_deps "$clonedir"
	build_handle_unresolved

	local -a aur_dep_files=() f
	local n
	for n in "${AUR_DEP_NAMES[@]}"; do
		f=$(build_latest_repo_file "$n")
		[[ -n "$f" ]] || die "$pkgbase: AUR dependency '$n' not found in $AUR_REPO_DIR after build/fallback"
		aur_dep_files+=("$f")
	done

	local copyname="paruz-$pkgbase"
	build_sync_copy "$copyname"
	build_ensure_srcpool   # makepkg needs a user-writable SRCDEST in both modes

	# Decide the build's network mode. Default is off (I2). Packages that fetch
	# their own build deps (cargo/go/npm/…) can't build offline, so paruz offers
	# a networked build; --allow-build-net (ALLOW_BUILD_NET=1) pre-approves it.
	local netmode=off
	if [[ "${ALLOW_BUILD_NET:-0}" == 1 ]]; then
		netmode=on
		warn "$pkgbase: --allow-build-net set — building WITH network (I2 waived)"
	elif build_needs_build_net "$clonedir"; then
		warn "$pkgbase: this package fetches dependencies at build time (cargo/go/npm/pip/…),"
		warn "which the default network-off build (I2) cannot do."
		warn "A networked build stays chroot- and secret-isolated (I3), is still gated, and is"
		warn "still installed with --noscriptlet + IOC-checked — but build()/package() WILL have"
		warn "network, so a malicious build could fetch a payload into the (secret-free) sandbox."
		if confirm "$pkgbase: build WITH network in the isolated chroot?" y; then
			netmode=on
		else
			warn "$pkgbase: keeping the network-off build (it will likely fail for this package)"
		fi
	fi

	if [[ "$netmode" == off ]]; then
		# Net-off build needs sources + deps present beforehand (no network then).
		build_provision_repo_deps "$copyname"
		build_provision_sources "$clonedir"
	fi
	# In netmode=on, makechrootpkg fetches sources+deps and verifies PGP itself.
	build_do_build "$netmode" "$copyname" "$clonedir" "${aur_dep_files[@]}"

	local -a pkgnames
	mapfile -t pkgnames < <(build_pkgnames "$clonedir")
	build_repo_add "${pkgnames[@]}"
}

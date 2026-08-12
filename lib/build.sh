# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# lib/build.sh — isolated net-off chroot build, Recipe A (PLAN.md §6.3, §7)
#
# Satisfies I1 (no untrusted PKGBUILD code on host), I2 (build phase has no
# network), I3 (build env never sees secrets — we simply never bind-mount
# $HOME/~/.ssh/~/.gnupg/agents; makechrootpkg/arch-nspawn do not either).
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

# build_latest_repo_file NAME — newest matching package file in the local
# [aur] repo directory, or empty if none.
build_latest_repo_file() {
	local name="$1"
	find "$AUR_REPO_DIR" -maxdepth 1 -name "${name}-*.pkg.tar.zst" -printf '%T@ %p\n' 2>/dev/null \
		| sort -rn | head -1 | cut -d' ' -f2-
}

# build_classify_deps CLONEDIR — per §7: pacman -Sp/-Si succeeds and repo is
# not 'aur' => REPO_DEPS; repo is 'aur' => AUR_DEP_NAMES (already built,
# resolvable from the local file repo); not resolvable at all (and not
# already installed) => UNRESOLVED_DEPS, handled by build_handle_unresolved.
build_classify_deps() {
	local clonedir="$1" dep repository
	REPO_DEPS=(); AUR_DEP_NAMES=(); UNRESOLVED_DEPS=()
	while IFS= read -r dep; do
		[[ -z "$dep" ]] && continue
		if pacman -Qq "$dep" >/dev/null 2>&1; then
			continue
		fi
		# pacman -Si exits non-zero for AUR deps; `|| true` prevents that
		# expected failure from tripping `set -o pipefail` + `set -e`. Empty
		# $repository => not in any repo (AUR dep or truly missing).
		repository=$(pacman -Si "$dep" 2>/dev/null | awk -F': ' '/^Repository/{print $2; exit}') || true
		if [[ -z "$repository" ]]; then
			UNRESOLVED_DEPS+=("$dep")
		elif [[ "$repository" == "aur" ]]; then
			AUR_DEP_NAMES+=("$dep")
		else
			REPO_DEPS+=("$dep")
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
# copy WITH network (I2 only constrains the build phase, not provisioning).
build_provision_repo_deps() {
	local copyname="$1"
	(( ${#REPO_DEPS[@]} == 0 )) && return 0
	log "$copyname: provisioning repo deps (network ON): ${REPO_DEPS[*]}"
	run sudo arch-nspawn "$AUR_CHROOT_ROOT/$copyname" pacman -Sy --needed --noconfirm "${REPO_DEPS[@]}"
}

# build_create_builduser COPYNAME — creates the 'builduser' account inside
# the chroot copy, mirroring makechrootpkg's own prepare_chroot() exactly
# (uid/gid match the invoking host user, so files written inside the chroot
# land with correct host ownership). Needed because our provisioning phase
# calls `runuser -u builduser` directly via arch-nspawn, BEFORE real
# makechrootpkg — which normally creates this account itself — ever runs.
# builduser doesn't pre-exist anywhere (not in the pristine root, not on any
# host); makechrootpkg (re)creates it fresh on every invocation, so we must
# too. Same on a real machine as in a VM — no chroot/host-specific branching.
build_create_builduser() {
	local copyname="$1"
	local copy="$AUR_CHROOT_ROOT/$copyname"
	local build_user="${SUDO_USER:-$(id -un)}" uid gid
	uid=$(id -u "$build_user")
	gid=$(id -g "$build_user")

	log "$copyname: creating builduser in chroot copy (uid=$uid gid=$gid)"
	run sudo sed -e '/^builduser:/d' -i "$copy/etc/passwd" "$copy/etc/shadow" "$copy/etc/group"
	run sudo bash -c 'printf "builduser:x:%s:\n" "$1" >> "$2"' _ "$gid" "$copy/etc/group"
	run sudo bash -c 'printf "builduser:x:%s:%s:builduser:/build:/bin/bash\n" "$1" "$2" >> "$3"' _ "$uid" "$gid" "$copy/etc/passwd"
	run sudo bash -c 'printf "builduser:!!:%s::::::\n" "$(( $(date -u +%s) / 86400 ))" >> "$1"' _ "$copy/etc/shadow"

	# makepkg working dirs owned by builduser (mirrors makechrootpkg's
	# prepare_chroot). Without a writable BUILDDIR, makepkg aborts at startup
	# ("no write permission for $BUILDDIR (/)") before it downloads anything,
	# because it otherwise defaults BUILDDIR to the cwd (/). /srcdest and
	# /startdir are bind-mount targets, so they are not created here.
	run sudo install -d -o "$uid" -g "$gid" \
		"$copy/build" "$copy/pkgdest" "$copy/srcpkgdest" "$copy/logdest"
}

# build_provision_sources COPYNAME CLONEDIR — fetch+verify sources into the
# persistent host source pool, inside the chroot copy (I1 residual, §10):
# avoids makechrootpkg's default on-host --verifysource parse. --holdver
# pins VCS sources so the later network-off build doesn't need to "check
# latest".
build_provision_sources() {
	local copyname="$1" clonedir="$2"
	local build_user="${SUDO_USER:-$(id -un)}"

	run sudo mkdir -p "$AUR_SRCPOOL"
	# builduser's uid inside the chroot is the SAME uid as build_user on the
	# host (no user-namespace remapping in arch-nspawn) — bind-mounted
	# directories are seen with their real host ownership, so this is what
	# actually makes /srcdest writable by builduser inside the chroot.
	run sudo chown "$build_user:$build_user" "$AUR_SRCPOOL"

	build_create_builduser "$copyname"

	log "$copyname: provisioning sources (network ON, inside chroot)"
	# Run as builduser from /startdir (makepkg refuses a PKGBUILD outside the
	# cwd — same reason makechrootpkg's _chrootbuild does `cd /startdir`).
	# HOME/BUILDDIR/*DEST point at writable in-chroot dirs (created in
	# build_create_builduser); SRCDEST is the bind-mounted host pool so the
	# fetched sources persist for the later network-off build.
	run sudo arch-nspawn "$AUR_CHROOT_ROOT/$copyname" \
		--bind="$AUR_SRCPOOL:/srcdest" --bind="$clonedir:/startdir" -- \
		runuser -u builduser -- bash -c 'cd /startdir || exit 1
			exec env HOME=/build BUILDDIR=/build SRCDEST=/srcdest \
				PKGDEST=/pkgdest SRCPKGDEST=/srcpkgdest LOGDEST=/logdest \
				makepkg --verifysource --holdver'
}

# build_do_build COPYNAME CLONEDIR AUR_DEP_FILE... — the network-off build
# (I2): the outer `unshare -n` strips the network namespace before
# makechrootpkg/arch-nspawn ever runs, so build()/package() have none.
# AUR deps already built (this run or previously) are injected as files via
# `-I` — no [aur] repo needs to be configured inside the chroot.
build_do_build() {
	local copyname="$1" clonedir="$2"
	shift 2
	local -a aur_dep_files=("$@")

	local -a cmd=(env "SRCDEST=$AUR_SRCPOOL" "PKGDEST=$AUR_REPO_DIR" \
		makechrootpkg -r "$AUR_CHROOT_ROOT" -l "$copyname")
	local f
	for f in "${aur_dep_files[@]}"; do
		cmd+=(-I "$f")
	done
	cmd+=(-- --holdver)

	log "$copyname: building with network OFF (I2): ${cmd[*]}"
	( cd "$clonedir" && run sudo unshare -n -- bash -c \
		'ip link set lo up 2>/dev/null; exec "$@"' _ "${cmd[@]}" )
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
	assert_tools makechrootpkg arch-nspawn repo-add pacman arch-nspawn unshare

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
	build_provision_repo_deps "$copyname"
	build_provision_sources "$copyname" "$clonedir"
	build_do_build "$copyname" "$clonedir" "${aur_dep_files[@]}"

	local -a pkgnames
	mapfile -t pkgnames < <(build_pkgnames "$clonedir")
	build_repo_add "${pkgnames[@]}"
}

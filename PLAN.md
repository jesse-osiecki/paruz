# paruz — Zero-Trust AUR Installer: Design & Security Invariants

> **Status:** implemented. This document is the authoritative design and
> **security-invariant reference** (§2, I1–I7) — code comments cite it as
> `PLAN.md §N`. Keep it in sync when behavior changes; do not regress the
> invariants.
> **Scope:** a portable Bash tool `paruz` (+ `paruz-setup` bootstrap) that hardens
> AUR install/upgrade on Arch Linux against supply-chain (maintainer-takeover) attacks,
> while preserving `paru`/`pacman` muscle memory.

---

## 0. TL;DR for the implementer

Build a Bash wrapper, `paruz`, that for AUR **install/upgrade** operations:

1. **Reads & gates** every PKGBUILD/`.install`/maintainer change before building
   (git diff gate + AUR-RPC maintainer gate + `aur-scan` static analysis; **fail closed**).
2. **Builds in an existing chroot with the network turned off** after sources/deps are
   provisioned (reuses `/var/lib/aurbuild` + `/var/lib/repo/aur`).
3. **Installs on the host with `pacman -U --noscriptlet`** so the package's `.install`
   scriptlet **never executes as root on the host**; official-repo dependencies are
   installed separately **with** scriptlets (they're signed/trusted).
4. **Reads the skipped scriptlet and gates on it** (does *not* auto-replay; sandbox
   replay is opt-in and treated as advisory only — see §2, I6).
5. Runs an **IOC self-check** (eBPF-rootkit maps + known-compromised package list).
6. Optionally folds in **`flatpak update`** on full upgrades.

Everything that is *not* an AUR sync-install/upgrade is passed straight through to stock
`paru`. `paruz` is a thin, auditable orchestrator around **stock, signed paru + pacman +
devtools + ks-aur-scanner** — it is **not** a fork of paru.

---

## 1. Threat model (why every step exists)

Attack vector (both 2026 waves): **silent maintainer takeover of already-trusted AUR
packages** via AUR's orphan-adoption feature. Packages keep their names, histories, and
community trust; the malicious change arrives as an **upgrade of a package you already
have**. That is the most dangerous event — not first install.

Two code-execution moments the attacker uses:

| Moment | What runs | Wave-1 example | Wave-2 example |
|---|---|---|---|
| **Build time** | `build()`/`package()` (and PKGBUILD parse-time globals) as the build user | `npm/bun install <lockfile pkg>` fetches live payload | pre-shipped ELF ("linter"/"hasher"/"minifier") + loader fetches stage-2 from `.onion` |
| **Install time** | `.install` scriptlet as **root** on the host | post-install scriptlet triggers the fetch | ELF loader invoked from scriptlet |

Wave-2 refinements that constrain the design:

- **Pre-shipped ELF payloads** → blocking outbound network *at install* is insufficient;
  the payload can also run *at build*. → **isolate the build's network too** (gap #2).
- **VM/sandbox/CI detection** → the loader goes dormant inside sandboxes. → **do not trust
  a "clean" result from sandbox replay** as a security signal (gap #4).
- **SSH worm + infostealer** → secrets must be unreachable from the build. → build env
  must never mount `$HOME`/`~/.ssh`/`~/.gnupg`/tokens (gap #6).
- **eBPF rootkit** when build/install runs as root → detectable via named BPF maps.

---

## 2. Security invariants (MUST hold — do not regress these)

These are the contract. Any implementation choice is acceptable iff it preserves all of:

- **I1 — No untrusted PKGBUILD code executes on the host.** All PKGBUILD parsing,
  `prepare()`, `build()`, `package()` happen **inside the chroot**. Gates run **before**
  any `makepkg` parse of the target. (Residual, see §10: `makechrootpkg`'s own on-host
  `--verifysource` parse; paruz performs source/dep provisioning **inside the chroot** to
  avoid it — see §6.4.)
- **I2 — The build phase has no network.** Network is available only while *provisioning*
  sources and dependencies (inside the chroot); the actual `build()`/`package()` run with
  the network namespace stripped.
- **I3 — The build env never exposes secrets.** No bind mount of `$HOME`, `~/.ssh`,
  `~/.gnupg`, `~/.config`, cloud/token files, SSH agent, GPG agent into the build. Assert
  this explicitly; `makechrootpkg` already does not mount them — never add binds that do.
- **I4 — The host install never runs a package's `.install` scriptlet.** Use
  `pacman -U --noscriptlet` for AUR packages. (libalpm hooks still run — that's fine and
  intended; see §6.5.)
- **I5 — Every AUR install/upgrade passes the gate.** Diff + maintainer + static-scan gate
  precede every build. A maintainer change is a **hard stop** by default.
- **I6 — Sandbox replay is never a security gate.** Default behavior is **read + gate**
  the scriptlet, not replay. `--replay-hook` is opt-in, runs cap-dropped + network-off,
  and its result is **advisory only** (Wave-2 detects sandboxes). A "clean" replay must
  **not** auto-approve anything.
- **I7 — Fail closed.** Any gate error, ambiguity, missing tool needed for a security
  check, or unexpected state **aborts the install**. Never "proceed on error."

A conforming implementation should have a single `die()`/`abort()` path and route every
gate failure through it.

---

## 3. Environment facts

These describe a typical current Arch system with the AUR-build stack installed.
`paruz-setup` (§8) re-establishes these on any target machine; `paruz` should also assert
the critical ones at runtime and **fail closed** (I7) if missing.

### 3.1 Tooling present
`paru 2.1.0`, `devtools 1:1.5.1` (`makechrootpkg`, `mkarchroot`, `arch-nspawn`,
`pkgctl`), `pacman`, `ks-aur-scanner 0.1.1` (binary **`aur-scan`**, plus `aur-scan-hook`,
`aur-scan-wrap`, libalpm hook `90-aur-scanner.hook`), `gvisor-bin`/`runsc 20260406`,
`flatpak`, and `jq curl git expac bwrap` — all on `PATH`. **`bpftool` is NOT installed**
→ ships in the **`bpf`** package; `paruz-setup` installs it (needed for the IOC check).

### 3.2 Build infrastructure (reuse — do not recreate)
- Local repo: `/var/lib/repo/aur/` — `aur.db` (+ `.files`), group `wheel`, `g+w`,
  `SigLevel = Optional TrustAll`. Built `.pkg.tar.zst` land here.
- Chroot: `/var/lib/aurbuild/` with pristine `root/` and per-user working copies.
- `pacman.conf` tail:
  ```ini
  [aur]
  SigLevel = Optional TrustAll
  Server = file:///var/lib/repo/aur
  ```
- `~/.config/paru/paru.conf`: `LocalRepo = aur`, `Chroot = /var/lib/aurbuild`.
  (Note: an existing `paru.conf` can end up with the `[options]` header duplicated —
  harmless but `paruz-setup` should write a single clean block.)

### 3.3 paru capabilities (verified against paru 2.1.0 source)
- **`--noinstall`** builds + `repo-add`s targets into the local repo **without installing
  on the host** (`command_line.rs:300` sets `no_install`; `install.rs:79`
  `install_targets = !config.no_install`). This is the "build into local repo, don't touch
  the host" primitive.
- **`--downloadonly`/`-w` is rejected for AUR targets** (`install.rs:1080`) — do not use it.
- `--chroot`, `--localrepo`, `-G/--getpkgbuild` (fetch PKGBUILD+files), `-Qua` (list AUR
  updates), `-Gp` (print PKGBUILD). paru recognizes `--noscriptlet` as a pass-through
  pacman arg (`args.rs:12`) and internally splits repo vs AUR targets.

### 3.4 `makechrootpkg` internals (verified from `/usr/bin/makechrootpkg`)
- Default makepkg args: `--syncdeps --noconfirm --log --holdver --skipinteg` (`:22`).
- `download_sources()` runs **on the host** as the build user via
  `makepkg --verifysource -o` writing to `$SRCDEST` (`:255-264`). ← host-side parse of
  PKGBUILD globals happens here (see I1 residual, §10).
- The actual build runs **inside `arch-nspawn`** via `/chrootbuild` (`:413-416`), with
  bind mounts `"$PWD":/startdir` and `"$SRCDEST":/srcdest` (`:396-399`).
- Options: `-l <copy>` (named working copy), `-I <pkg.tar.zst>` (install a built package
  into the copy before building — `:148-163`, `:309`), `-d <dir>` / `-D <dir>` (rw/ro bind),
  `-u` (update copy), `-c` (clean/re-sync copy from pristine root).
- Reads `SRCDEST/PKGDEST/LOGDEST/PACKAGER` from `makepkg.conf`/env; if unset they default
  to `$PWD` (`:362-366`). Host `makepkg.conf` here leaves them **unset** → paruz must set
  them explicitly.

### 3.5 `arch-nspawn` network (verified from `/usr/bin/arch-nspawn`)
- `exec … systemd-nspawn "${nspawn_args[@]}" "$@"` (`:155`) with **no `--private-network`**
  → the build container shares the **caller's** network namespace.
- **Consequence (the network-off hook):** run `makechrootpkg` inside a stripped network
  namespace (`unshare -n`, or pass `--private-network` through to the build `arch-nspawn`)
  and the build has **no network** — *provided sources and deps are already present*
  (they must be, because both source download and `--syncdeps` need network).

### 3.6 `--noscriptlet` scope (important, non-obvious)
`pacman --noscriptlet` skips **only the package's own `.install` scriptlet**. It does
**not** disable **libalpm hooks** in `/usr/share/libalpm/hooks/` — so `update-desktop-database`,
`gtk-update-icon-cache`, `systemd-sysusers`, `systemd-tmpfiles`, `mkinitcpio`, font/mime
cache updates, etc. **still run**. The only thing skipped is the package's *custom*
`.install` logic — which is exactly the attacker-controlled surface. This is what makes
`--noscriptlet` both safe and non-breaking for normal packages.

### 3.7 `aur-scan` CLI (verified `--help`)
- **Use `aur-scan scan <dir> --fail-on <level>`** on the exact fetched PKGBUILD dir (scans
  `PKGBUILD` + `.install`). `--fail-on {critical|high|medium|low|info}` → **non-zero exit
  at/above that level** ⇒ this is the gate.
- **Do NOT gate on `aur-scan check <pkg>`** — it re-fetches from AUR (TOCTOU: scans
  something other than what we build) and its shell integration is non-gating (see §3.8).
- Global: `-s/--severity` (min to display), `-q`, `--format {text,json,sarif}`.

### 3.8 Existing ks-aur-scanner shell integration is NON-gating
`/usr/share/aur-scan/integration.zsh` wraps `paru()`/`yay()` and runs
`aur-scan check --severity high --no-confirm` **without `--fail-on`** → it prints findings
and **always proceeds** (exit 0). `paruz` must not rely on it. `paruz-setup` should
recommend disabling the auto-scan for `paru` (e.g. `AUR_SCAN_ENABLED=0`, or removing the
source line) so you don't get a confusing, weaker second scan layered under paruz's real
gate.

---

## 4. Command surface

`paruz` inspects the pacman-style operation and either **hardens** or **passes through**.

| Invocation | Behavior |
|---|---|
| `paruz -S <pkgs>` | Hardened AUR install (repo targets among them handled normally). |
| `paruz -Syu`, `paruz` (bare), `paruz -Su` | Hardened **full upgrade**: official repo upgrade → AUR upgrade → Flatpak. |
| `paruz -Sua` | Hardened AUR-only upgrade. |
| `paruz -Qua` | Pass-through (list AUR updates). |
| `paruz -R…`, `-Q…`, `-Ss`, `-Si`, `-G`, `-F…`, `-Sc`, etc. | `exec command paru "$@"` unchanged. |

**paruz-specific flags** (strip before delegating):

- `--fail-on <level>` — static-scan gate threshold (default `critical`; warn at `high`).
- `--allow-maintainer-change` — permit a maintainer change for this run (still shows diff).
- `--replay-hook[=post_install|post_upgrade]` — deliberately replay a scriptlet in a
  cap-dropped, network-off `bwrap` sandbox (advisory only; prints a Wave-2 warning).
- `--no-flatpak` / `--no-ioc` — skip those stages.
- `--sandbox=chroot|gvisor` — build backend (default `chroot`; `gvisor` is Phase 2, §13).
- `--dry-run` — print the plan (gates, build, install commands) without executing.

**Muscle memory:** `paruz` calls **`command paru`** internally so it is unaffected by the
existing zsh `paru()` wrapper. Users may optionally `alias paru=paruz`. Never let `paruz`
call a shell function named `paru`/`pacman` (use `command`/absolute paths) — avoids the
wrapper-loop and the non-gating scan.

---

## 5. High-level flow

```
paruz <args>
  │
  ├─ not an AUR sync-install/upgrade? ───────────────► exec command paru <args>   (passthrough)
  │
  ├─ IOC self-check (§6.0)                              [fail closed on rootkit map]
  │
  ├─ upgrade path? ─► sudo pacman -Syu   (official, signed, scriptlets ON; fixes -Sy footgun)
  │                   determine AUR updates via `command paru -Qua`
  │
  └─ for each AUR target (topological; deps first):
        6.1 FETCH      command paru -G <pkg>            (git clone AUR pkgbase)          [net ON]
        6.2 GATE       git-diff gate + maintainer gate + `aur-scan scan --fail-on`       [fail closed]
        6.3 BUILD      provision sources+deps (net ON, in-chroot) → build (net OFF)      [I1,I2,I3]
                       → repo-add into /var/lib/repo/aur
        6.4 INSTALL    install repo-deps WITH scriptlets → `pacman -U --noscriptlet` AUR [I4]
        6.5 SCRIPTLET  read skipped .install; report; gate; (optional cap-dropped replay)[I6]
        6.6 SNAPSHOT   record approved commit + maintainer for next-time diff
  │
  ├─ upgrade path? ─► flatpak update            (interactive; --no-flatpak to skip)
  └─ final IOC re-check + summary
```

---

## 6. Pipeline detail

### 6.0 IOC self-check (`lib/ioc.sh`)
Run once at start (and a light re-check at end). Advisory **except** the rootkit-map check,
which is a loud CRITICAL.

- **eBPF rootkit maps:** `sudo bpftool map list` and grep names
  `hidden_pids|hidden_names|hidden_inodes`. Any hit → CRITICAL banner: rootkit likely ran
  as root; advise credential rotation + host reinstall; **abort** the run (I7). If
  `bpftool` is absent, print a warning that this check was skipped (paruz-setup installs
  `bpf`, so this should be rare).
- **Known-compromised packages:** intersect `pacman -Qq` with
  `share/known-bad-packages.txt` (see §9.3). Any match → loud warning (rotate creds,
  consider reinstall). This is a point-in-time, advisory list.
- **Installed-AUR audit:** `aur-scan system` (advisory; summarize counts, don't block).
- *(Optional, off by default — high false-positive:* flag a `dbus-daemon` process that
  holds network sockets, i.e. Tor-masquerading-as-dbus. Document as a heuristic.)*

### 6.1 Fetch (`lib/gate.sh`)
For each AUR target `$pkg`, into a paruz-owned work root
(`${XDG_STATE_HOME:-~/.local/state}/paruz/work/`):

```bash
( cd "$WORKROOT" && command paru -G "$pkg" )   # clones AUR git repo → $WORKROOT/<pkgbase>
```

`paru -G` resolves pkgname→pkgbase and clones the AUR git repo (full history — needed for
the diff gate). Do **not** run `makepkg` yet.

### 6.2 Gate (`lib/gate.sh`) — fail closed (I5, I7)
State dir: `${XDG_STATE_HOME:-~/.local/state}/paruz/approved/<pkgbase>/` holding the last
**approved git commit** and **maintainer**.

1. **Maintainer gate** (ties directly to the orphan-adoption vector):
   ```bash
   curl -fsS "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" \
     | jq -r '.results[0].Maintainer // "«orphan»"'
   ```
   Compare to the stored maintainer. **Hard stop** (unless `--allow-maintainer-change`) if:
   maintainer changed, went `«orphan»`→named (adoption!), or named→`«orphan»`. Show old→new.
2. **PKGBUILD/`.install` diff gate:**
   - First-ever install (no baseline): show the full `PKGBUILD` and any `*.install`
     (prefer `bat` if present) and require explicit approval.
   - Update: `git -C <clone> diff <approved>..HEAD -- PKGBUILD *.install *.sh .SRCINFO`.
     Present it; **escalate** (extra confirmation) if the diff **adds or changes an
     `.install` file**, adds a **binary/blob source**, or changes a `source=`/checksum to a
     new host. Default answer is **No**.
3. **Static scan:** `aur-scan scan "<clone>" --fail-on "$FAIL_ON"` (default `critical`).
   Non-zero exit ⇒ **abort**. Additionally warn (don't auto-abort) on `high`. Print the
   findings verbatim.

All three must pass (or be explicitly overridden where allowed) before build.

### 6.3–6.4 already covered above; details:

### 6.3 Isolated build (`lib/build.sh`) — satisfies I1, I2, I3

**Invariants restated:** sources + all build/runtime deps must be present **before** the
network is removed; `build()`/`package()` run with **no network**; no secrets bind-mounted.

**Recommended recipe (Recipe A — chroot + `unshare -n`):** per package, in its clone dir,
with a **dedicated working copy** `paruz-<pkgbase>` and a persistent host source pool
`SRCPOOL=/var/lib/paruz/srcdest`, `PKGDEST=/var/lib/repo/aur`:

1. **Sync a fresh working copy** from the pristine root (`makechrootpkg -c … -l paruz-<pkgbase>`
   handles copy creation; or rsync/btrfs-snapshot `/var/lib/aurbuild/root` → copy).
2. **Provision (network ON), inside the chroot** — never on the host:
   - Repo deps: parse `.SRCINFO` `depends`/`makedepends`/`checkdepends`; install the
     official-repo ones into the copy: `arch-nspawn "<copy>" pacman -Sy --needed --noconfirm <repo-deps>`.
   - AUR deps (already built earlier this run): inject as files at build time via
     `makechrootpkg -I /var/lib/repo/aur/<dep>-*.pkg.tar.zst …` (installs into the copy via
     `pacman -U`; no chroot `[aur]` config needed).
   - Sources: fetch+verify **inside** the copy into the bind-mounted pool, e.g.
     `arch-nspawn "<copy>" --bind="$SRCPOOL:/srcdest" -- runuser -u builduser -- \
        env SRCDEST=/srcdest makepkg -p /startdir/PKGBUILD --verifysource --holdver`.
     `--holdver` prevents VCS "fetch latest" so a later net-off re-verify won't need the net.
3. **Build (network OFF)** reusing the provisioned copy (do **not** pass `-c`):
   ```bash
   sudo unshare -n -- bash -c '
     ip link set lo up 2>/dev/null   # some test suites need loopback
     exec env SRCDEST="'"$SRCPOOL"'" PKGDEST="/var/lib/repo/aur" \
       makechrootpkg -r /var/lib/aurbuild -l "paruz-'"$pkgbase"'" \
         -I <aur-dep pkgs…> -- --holdver --nocheck? '   # see note on --nocheck below
   ```
   With sources cached + deps present + `--holdver`, `makechrootpkg`'s own
   `download_sources` and `--syncdeps` need no network; the `arch-nspawn` build inherits the
   empty netns → **`build()`/`package()` have no network**.
   - *Note on tests:* `check()` sometimes needs network; default to running it offline and,
     on failure that looks network-related, either surface it or allow an opt-in
     `--allow-check-net` that re-runs only `check()` networked (document the tradeoff). Keep
     the default **offline**.
4. **Publish:** `makechrootpkg` writes the `.pkg.tar.zst` to `PKGDEST`
   (`/var/lib/repo/aur`); then `repo-add /var/lib/repo/aur/aur.db.tar.zst <pkg>` and
   `sudo pacman -Sy` (refresh only the `[aur]` db — acceptable; it's the local file repo).

**Alternative (Recipe B):** shadow `arch-nspawn` on `PATH` with a wrapper that injects
`--private-network` for the build call only (leaving `makechrootpkg`'s host-side
`download_sources` networked). Simpler orchestration, but relies on PATH-shadowing and
still requires deps pre-installed. Recipe A is preferred for auditability.

**AUR-dependency scope for v1 (see §7):** if a target has an **uninstalled AUR
dependency**, v1 may either (a) resolve it recursively with the same pipeline (preferred if
time permits), or (b) **fall back** to a clearly-warned `command paru -S --noinstall
--chroot --localrepo <pkg>` build for that subtree — which is filesystem/secret-isolated
but **networked** (I2 not guaranteed for that build) — then continue with the hardened
install. The fallback must print exactly which packages built with network and why.

### 6.4 Host install with scriptlet split (`lib/install.sh`) — satisfies I4
After all targets are built into `[aur]`:

1. **Compute the closure & classify.** Resolve what would be installed for the AUR target
   names (they now resolve via `[aur]`), then split into **repo deps** vs **AUR pkgs**:
   ```bash
   closure=$(pacman -Sp --print-format '%n' --needed <aur-names>)   # deps + aur names
   aur_names=<the set paruz built this run>
   repo_deps=closure \ aur_names
   ```
   (`aur_names` are known because paruz built them; cross-check against `pacman -Slq aur`.)
2. **Install repo deps WITH scriptlets** (signed/trusted):
   `sudo pacman -S --needed --asdeps <repo_deps>`.
3. **Install AUR packages WITHOUT scriptlets** from the built files:
   `sudo pacman -U --noscriptlet /var/lib/repo/aur/<name>-<ver>-<arch>.pkg.tar.zst …`
   Mark explicitly-requested targets as explicit (default) and pulled AUR deps `--asdeps`.
   Because deps are already satisfied by step 2, `-U` won't complain, and `--noscriptlet`
   now affects **only** the AUR packages.

Future `paru -Qua` upgrade detection still works — it compares the installed version
(tracked in the pacman DB by `-U`) against the AUR RPC, independent of install source.

### 6.5 Scriptlet read + gate (`lib/install.sh`) — satisfies I6
For each AUR package whose scriptlet was skipped:

1. Extract and display it: `bsdtar -xOqf <pkg.tar.zst> .INSTALL` (present only if the
   package ships one). List which functions it defines (`post_install`, `post_upgrade`,
   `pre_remove`, …) and state plainly: **these did NOT run.**
2. It was already covered by the §6.2 static scan; re-summarize any findings.
3. **Default: do nothing further** (read + gate, per I6). Advise the user what, if anything,
   a legitimate scriptlet would have done (most legit side-effects are handled by libalpm
   hooks anyway — §3.6).
4. **`--replay-hook[=fn]`** (opt-in): replay the chosen function in a locked-down sandbox,
   **advisory only**:
   ```bash
   bwrap --unshare-all --unshare-net --cap-drop ALL \
     --ro-bind / / --tmpfs /tmp --dev /dev --proc /proc --die-with-parent \
     bash -c '. .INSTALL; declare -F post_install >/dev/null && post_install "<ver>"'
   ```
   Print the Wave-2 warning: *the loader detects sandboxes and may stay dormant; a clean
   replay proves nothing and must not be treated as approval.* Replayed side-effects are
   isolated and do **not** apply to the host — replay is for **observation**, never to
   "perform" the scriptlet.

### 6.6 Snapshot
On success, write the approved git commit hash and maintainer to
`…/paruz/approved/<pkgbase>/` for the next run's diff/maintainer gate.

### 6.7 Flatpak (upgrade path only)
`flatpak update` (interactive; respects its own confirmation). Skip with `--no-flatpak`.
Print a one-line note that Flatpak apps run in their own sandbox (different trust model).

---

## 7. AUR dependency handling

**Classification:** for each `depends`/`makedepends`/`checkdepends` in `.SRCINFO`:
`pacman -Sp <dep>` succeeds ⇒ **repo dep** (handled by §6.3 step 2 / §6.4 step 2);
else present in AUR (`command paru -G` / RPC) ⇒ **AUR dep** (fetch, gate, build first);
else ⇒ error (fail closed).

**Ordering:** build AUR deps before dependents (topological; maintain a `visited` set to
avoid cycles/duplicates). Inject each built AUR dep into a dependent's build via
`makechrootpkg -I` (§6.3).

**v1 scope decision:** implement the full pipeline for **explicitly-named targets and the
common case where their dependencies are official-repo or already installed** (strong I2
guarantee end to end). For targets with **uninstalled AUR dependencies**, ship the §6.3
fallback (warned, networked `paru --noinstall` build) in v1 and make full recursive
hardened dep-building a **Phase 2** task. Rationale: recursive AUR-dep hardening adds real
complexity (topological build, `[aur]`-in-chroot or `-I` plumbing) that shouldn't block the
MVP, and the fallback is still filesystem/secret-isolated.

---

## 8. `paruz-setup` — portable bootstrap (`bin/paruz-setup`)

Idempotent, re-runnable, prints what it changes, asks before touching system files. Makes a
fresh Arch machine `paruz`-ready. Steps:

1. **Deps:** `sudo pacman -S --needed devtools flatpak jq expac bpf` and ensure an AUR
   helper exists (paru). `ks-aur-scanner` is itself from the AUR — bootstrap it with plain
   paru **once** (or `makepkg -si` from a hand-reviewed clone). Verify `runsc` only if
   `--sandbox=gvisor` is intended (Phase 2).
2. **Local repo:** create `/var/lib/repo/aur`, `chgrp wheel`, `chmod g+w`, and initialize:
   `repo-add /var/lib/repo/aur/aur.db.tar.zst` (idempotent if it already exists).
3. **Chroot:** `mkarchroot /var/lib/aurbuild/root base-devel` if absent. Detect btrfs (the
   chroot uses subvolume snapshots there). Create `/var/lib/paruz/srcdest`.
4. **pacman.conf:** append the `[aur]` block (§3.2) **only if not already present**
   (grep-guard). Never duplicate.
5. **paru.conf:** write a single clean `[options]` block with `LocalRepo = aur` and
   `Chroot = /var/lib/aurbuild` (de-duplicate if the file already has repeated headers).
6. **Scanner integration:** detect the non-gating zsh integration (§3.8) and offer to set
   `AUR_SCAN_ENABLED=0` for `paru` (or comment the source line) so paruz's gate is the
   single source of truth.
7. **Install paruz:** symlink/copy `bin/paruz` (+ `bin/paruz-setup`) into `/usr/local/bin`;
   install completions; drop default config to `/etc/paruz/paruz.conf` (§9) if absent.
8. **Self-test:** a `paruz doctor` subcommand that verifies every §3 assumption and reports
   OK/MISSING per line (model this on `claudenboxen doctor`).

Provide a matching **uninstall/teardown** note (remove `[aur]` block, repo dir, chroot,
`/var/lib/paruz`) so the change is reversible.

---

## 9. Config

### 9.1 File
`/etc/paruz/paruz.conf` (system) overridden by `${XDG_CONFIG_HOME:-~/.config}/paruz/paruz.conf`
(user). Simple `KEY=value` sourced by Bash. See `etc/paruz.conf` in this repo for the
annotated default. Keys:

| Key | Default | Meaning |
|---|---|---|
| `FAIL_ON` | `critical` | `aur-scan` gate threshold. |
| `WARN_ON` | `high` | Warn-but-don't-block threshold. |
| `SANDBOX` | `chroot` | Build backend (`chroot` \| `gvisor` [Phase 2]). |
| `ALLOW_MAINTAINER_CHANGE` | `0` | Default hard-stop on maintainer change. |
| `FLATPAK` | `1` | Fold `flatpak update` into full upgrades. |
| `IOC` | `1` | Run the IOC self-check. |
| `ALLOW_CHECK_NET` | `0` | Allow networked `check()` re-run (weakens I2 for tests only). |
| `KNOWN_BAD_LIST` | `/usr/share/paruz/known-bad-packages.txt` | IOC package list path. |

### 9.2 Runtime assertions
On start, `paruz` verifies: `command paru`, `pacman`, `makechrootpkg`, `arch-nspawn`,
`repo-add`, `aur-scan`, `jq`, `curl`, `git`, `bsdtar`, `unshare` exist; `/var/lib/repo/aur`
and `/var/lib/aurbuild/root` exist and are writable/usable; `[aur]` is configured. Missing
anything → point at `paruz-setup` and **fail closed** (I7).

### 9.3 `share/known-bad-packages.txt`
Seed with the confirmed Wave-2 names (see the file in this repo) plus a comment that it is
point-in-time and advisory. `paruz-setup` installs it to `/usr/share/paruz/`.

---

## 10. Non-goals & residual risks (state honestly in README + `--help`)

- **Static analysis is not complete.** `aur-scan` catches known patterns; obfuscated/novel
  payloads may pass. paruz is defense-in-depth, not a guarantee.
- **Runtime risk is out of scope.** paruz protects *build* and *install*. A pre-shipped ELF
  that only acts when you later *run* the installed program is not something an installer
  can neutralize — that is the inherent risk of running untrusted software.
- **Host-side parse during source verify (I1 residual).** Recipe A performs `--verifysource`
  *inside* the chroot to avoid `makechrootpkg`'s default on-host parse; if a code path ever
  falls back to on-host `makepkg`, PKGBUILD globals run as the unprivileged build user — but
  always **after** the §6.2 gate. Never run `makepkg` on the host before the gate.
- **Build-time kernel escape.** The chroot shares the host kernel; a build carrying a kernel
  LPE could escape. Mitigated only by the Phase-2 gVisor backend (§13). The documented
  attacks (infostealer/fetch/persist) are already neutralized by I2/I3/I4 without it.
- **Trust anchors.** paru, pacman, devtools, ks-aur-scanner, and paruz itself are trusted;
  install them from signed sources / hand-reviewed clones.

---

## 11. Test plan / acceptance criteria (`tests/`)

Use fixture PKGBUILDs under `tests/fixtures/` and a local test AUR mirror or `aur-scan
scan` on directories (no live AUR needed for most). Each must pass:

1. **Static gate blocks.** Fixture with `curl … | bash` (DLE-001) ⇒ `aur-scan scan
   --fail-on critical` non-zero ⇒ paruz **aborts**, nothing built/installed.
2. **`.install` addition escalates.** Update fixture that adds a `.install` with
   `INSTALL-003` (network in scriptlet) ⇒ gate escalates and (default No) aborts.
3. **Maintainer change hard-stops.** Simulate stored maintainer `alice` → RPC `mallory`
   (or `«orphan»`→`bob`) ⇒ abort without `--allow-maintainer-change`.
4. **Network-off build proven.** Fixture whose `build()` runs
   `curl -m5 https://example.com` (or `getent hosts …`) **must fail** the build under
   Recipe A. A control run without `unshare -n` succeeds — proving I2 is real.
5. **`--noscriptlet` proven.** Fixture whose `post_install` creates
   `/tmp/paruz-scriptlet-ran`; after `paruz -S`, that file **must NOT exist** (I4).
   Confirm libalpm-hook side-effects (e.g. desktop-database) still occur.
6. **Secrets isolation.** Assert the build namespace cannot see `$HOME`/`~/.ssh` (fixture
   `build()` that `test -e ~/.ssh/id_*` must find nothing) (I3).
7. **Scriptlet split correctness.** An AUR pkg with a repo dep that has a real scriptlet ⇒
   repo dep's scriptlet **runs**, AUR pkg's does **not**.
8. **Passthrough.** `paruz -Q`, `-Ss`, `-R`, `-Si`, `-G` behave exactly like `paru`.
9. **Idempotent setup.** `paruz-setup` run twice makes no second change; `[aur]`/paru.conf
   never duplicated; `paruz doctor` all-OK afterward.
10. **Fail-closed.** Remove `aur-scan` from PATH ⇒ paruz refuses to install (I7), does not
    silently skip the scan.

---

## 12. Deliverables / file layout

```
paruz/
├── README.md                      # what it is, threat model summary, install, honest limits
├── PLAN.md                        # this file
├── LICENSE                        # GPL-3.0-or-later (matches paru/ks-aur-scanner ecosystem)
├── bin/
│   ├── paruz                      # entrypoint: arg parse, dispatch, orchestration, doctor
│   └── paruz-setup                # §8 bootstrap
├── lib/
│   ├── common.sh                  # die/abort, logging, colors, runtime assertions (§9.2)
│   ├── gate.sh                    # fetch + diff + maintainer + aur-scan gate (§6.1–6.2)
│   ├── build.sh                   # Recipe A net-off build + repo-add (§6.3)
│   ├── install.sh                 # scriptlet-split install + scriptlet read/gate (§6.4–6.5)
│   └── ioc.sh                     # IOC self-check (§6.0)
├── etc/paruz.conf                 # default config (annotated)
├── share/known-bad-packages.txt   # IOC list (seed provided)
├── completions/{paruz.bash,_paruz}
└── tests/{run.sh,fixtures/…}      # §11
```

**Style:** POSIX-leaning Bash with `set -euo pipefail`, `shellcheck`-clean, small functions,
one `die()` path, no `eval` on untrusted input, always `command paru` / absolute pacman.
Every privileged step uses `sudo` explicitly and is echoed under `--dry-run`.

---

## 13. Open decisions & future work

- **[Decided] Build backend = chroot + `unshare -n` for v1.** Directly neutralizes the
  documented attacks. Keep the build in a single swappable function (`lib/build.sh`) so a
  backend can be selected by `SANDBOX=`.
- **[Phase 2] gVisor (`--sandbox=gvisor`).** Adds host-kernel-attack-surface reduction
  (defense vs build-time container escape). Caveats on this class of host: gVisor
  `--network=sandbox` (NAT netns) is broken under `kernel.yama.ptrace_scope=1`, but the
  build wants **`network=none`** anyway, which works under rootless `runsc`. Implement as a
  `makepkg`-in-`runsc` backend with a purpose-built rootfs (cf. the `claudenboxen` design),
  **not** by nesting `nspawn` inside gVisor.
- **[Phase 2] Recursive hardened AUR-dependency builds** (replace the §7 fallback).
- **[Consider] `paruz -Qua`/upgrade UX:** batch the gate review so a big `-Syu` doesn't
  prompt per-package with no overview; show a combined "N AUR updates, M changed PKGBUILDs,
  K maintainer changes" summary first, then drill in.

---

---

## 14. Handoff notes

### 14.1 Ready-to-use implementer prompt
> Implement `paruz` per `PLAN.md` in this repo. Build `bin/paruz`, `bin/paruz-setup`, and
> `lib/*.sh` exactly to the §2 invariants — **fail closed**. Start with the §11 test
> fixtures (especially test 4, network-off build, and test 5, `--noscriptlet`) so the
> security guarantees are proven, not assumed. Follow the §7 v1 scope. Do **not** fork
> paru — call `command paru`. Bash with `set -euo pipefail`, shellcheck-clean.

### 14.2 Decisions the implementer inherits (confirm before/at start)
- **§7 — v1 AUR-dependency scope:** default is *full hardening for repo-only/installed
  deps + a warned, networked fallback for uninstalled AUR deps*; full recursive hardening
  is Phase 2. Change this only if the repo owner asks for full recursion in v1.
- **§13 — build backend:** chroot + `unshare -n` for v1; gVisor is Phase 2.

### 14.3 Repo TODOs not yet done
- **LICENSE file is missing.** PLAN/README reference GPL-3.0-or-later; drop in the canonical
  GPL-3.0 text (do not hand-transcribe it) and add an SPDX header to each script.
- **No git remote / no initial commit yet** at time of writing (scaffold + this plan are
  untracked). Make the first commit and add a remote before handing the repo to anyone.
- `bin/`, `lib/`, `completions/`, `tests/fixtures/` are empty placeholders (`.gitkeep`).

### 14.4 Traps worth re-reading before coding
- The existing ks-aur-scanner zsh integration **looks** like a gate but isn't (§3.8) — do
  not treat its "OK" as meaningful; paruz's own §6.2 gate is the source of truth.
- `--noscriptlet` skips only the package `.install`, **not** libalpm hooks (§3.6) — this is
  why the approach doesn't break normal packages; don't "fix" it by re-enabling scriptlets.
- Network must be present while *provisioning* sources/deps and absent during *build* — the
  ordering in §6.3 is the whole point of I2. Never run `makepkg` on the host before §6.2.

---

*End of plan. Implement against the invariants in §2; when in doubt, fail closed.*

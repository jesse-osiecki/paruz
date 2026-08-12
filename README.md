# paruz — zero-trust AUR installer

`paruz` is a thin, auditable Bash wrapper around **stock** `paru` + `pacman` + `devtools` +
[`ks-aur-scanner`](https://github.com/KiefStudioMA/ks-aur-scanner) that hardens AUR
install/upgrade against **supply-chain / maintainer-takeover** attacks — while keeping
`paru`/`pacman` muscle memory (`paruz -S <pkg>`, `paruz -Syu`).

It is **not** a fork of paru. paru is a dependency; paruz orchestrates it.

## What it does

For AUR install/upgrade operations, paruz:

1. **Reads and gates** every PKGBUILD / `.install` / maintainer change before building
   (git-diff gate + AUR-RPC maintainer gate + `aur-scan` static analysis — **fail closed**).
2. **Builds in a chroot with the network turned off** after sources/deps are provisioned,
   so a build-time payload can't fetch a second stage or exfiltrate.
3. **Installs on the host with `pacman -U --noscriptlet`** — the package's `.install`
   scriptlet never runs as root on your machine (libalpm hooks still run, so nothing
   normal breaks).
4. **Reads the skipped scriptlet and gates on it** instead of trusting sandbox replay.
5. Runs an **IOC self-check** (eBPF-rootkit maps + known-compromised package list).
6. Optionally folds in `flatpak update` on full upgrades.

Everything that isn't an AUR sync-install/upgrade passes straight through to `paru`.

## Status

Implemented per **[PLAN.md](./PLAN.md)** (the full, self-contained design: verified
environment facts, the network-off build recipe, the scriptlet-split install, the gates,
the IOC check, `paruz-setup`, security invariants, and the test plan).

Run `paruz-setup` to bootstrap a machine, then `paruz doctor` to verify it. `tests/run.sh`
runs the fast, non-privileged acceptance tests by default; `tests/run.sh --live` exercises
the real chroot build / install / `paruz-setup` paths and needs interactive `sudo` — read
it before running it, since it mutates real system state.

## Honest limits

paruz is **defense-in-depth, not a guarantee.** Static analysis can't catch every payload;
it protects *build* and *install* time, not the inherent risk of *running* untrusted
software afterward; and the chroot shares the host kernel (a build-time kernel-escape
exploit is only mitigated by the planned gVisor backend). See PLAN.md §10.

## License

GPL-3.0-or-later (matches the paru / ks-aur-scanner ecosystem).

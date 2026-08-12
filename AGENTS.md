# AGENTS.md

Instructions for any agent (or human) working in this repo. `CLAUDE.md` is a
symlink to this file — one source of truth. Follow these exactly.

## paruz in one line
A thin, auditable Bash wrapper around **stock** `paru` + `pacman` + `devtools` +
`ks-aur-scanner` that hardens AUR install/upgrade against supply-chain /
maintainer-takeover attacks. It is **not** a fork of paru — it orchestrates it.

## Commit / PR conventions
- Do **not** add `Co-Authored-By: Claude` (or any AI/Claude co-author),
  "Generated with Claude", "🤖", or similar attribution to commit messages or
  PR descriptions. Commits are authored solely by the human, using the repo's
  default git identity.
- Do **not** commit personal or environment-revealing content: no personal
  absolute paths (`/home/<user>` — use `$HOME`/`~`), machine hostnames,
  hardware specs, or "verified on my host / measured on my box" framing. State
  technical reasoning impersonally and portably; timings are "approximate,
  hardware-dependent". (Exception: the `PKGBUILD` `Maintainer:` line is a
  conventional public field and stays.)

## When a command is blocked
If a tool call or command is denied, sandboxed, or blocked (a refused
permission prompt, a missing group/privilege, etc.), **stop and ask the human**.
Do not route around it with `sudo`, `sg`, `su`, an alternate tool, or a
rephrased command. A denial is a signal to hand control back, not a puzzle.

## Security is the whole point — do not regress it
paruz's security invariants (I1–I7) are the contract; they are defined in
**`PLAN.md` §2**. Any change must preserve all of them. In particular:
- **Fail closed (I7).** Any gate error, ambiguity, missing security tool, or
  unexpected state must abort the install via the single `die()` path — never
  "proceed on error".
- No untrusted PKGBUILD code runs on the host (I1); the build phase has no
  network (I2); the build env never sees secrets (I3); the host install uses
  `pacman -U --noscriptlet` so a package's `.install` never runs as root (I4);
  every AUR install/upgrade passes the gate (I5); sandbox replay is never a
  security gate (I6).
- Never call a shell function named `paru`/`pacman`; always use `command paru`
  and absolute/`command` pacman, so paruz is unaffected by user shell wrappers
  and never re-triggers the non-gating ks-aur-scanner shell integration.

## Build / test / lint
- `make build` — syntax-check all scripts (the "compile" step for pure Bash).
- `make test` — the fast, non-privileged acceptance tier (`tests/run.sh`).
- `make lint` — `shellcheck -x` (run it; keep the tree shellcheck-clean).
- `make install` — DESTDIR-aware install (used by the `PKGBUILD` too).
- The **live** test tier (real chroot builds, real installs, `paruz-setup`)
  needs root + a real Arch environment and mutates system state. Do **not** run
  it on a dev machine — run it in the VM rig (below).

## Testrig (disposable VM) — how the live pipeline is validated
`testrig/` is a libvirt/QEMU harness that runs the dangerous, stateful tests in
a throwaway Arch VM so the host is never touched:
- `testrig/host-setup.sh` — one-time host prep (libvirt/kvm/etc.).
- `testrig/build-base.sh` — build the provisioned base snapshot (slow, once).
- `testrig/run.sh` — revert → sync current tree → run `tests/run.sh --live`.
- `testrig/smoke-aur.sh`, `smoke-aur-deps.sh`, `smoke-packaged.sh` — real-AUR,
  AUR-dependency (§7), and packaged-install end-to-end validations.
Prefer proving security-relevant changes here rather than assuming them.

## Style
POSIX-leaning Bash, `set -euo pipefail`, shellcheck-clean, small functions, a
single `die()`/abort path, no `eval` on untrusted input. Every privileged step
uses `sudo` explicitly and is echoed under `--dry-run`. Match surrounding code.

## Layout & design reference
`bin/` (entrypoint + bootstrap), `lib/*.sh` (gate/build/install/ioc/common),
`etc/paruz.conf`, `share/`, `completions/`, `tests/`, `testrig/`.
**`PLAN.md` is the authoritative design + security-invariant reference** — code
comments cite it as `PLAN.md §N`. Keep it in sync when behavior changes.

# paruz test rig

A disposable Arch Linux VM for exercising `tests/run.sh --live` — the tier of
paruz's own test suite that does real `makechrootpkg`/`arch-nspawn` chroot
builds, real `unshare -n` network-namespace stripping, real `pacman -S`/
`pacman -U` installs, and a real `bin/paruz-setup` run against
`/etc/pacman.conf` and `~/.config/paru/paru.conf`.

None of that is safe to run against your actual machine repeatedly. This rig
gives it a throwaway machine instead: a libvirt/QEMU VM, built from the
official Arch cloud image, provisioned by dogfooding the repo's own
`bin/paruz-setup`, snapshotted right after provisioning so re-running tests is
cheap, and always reachable for debugging when a test fails.

**Nothing here can touch your host's real `/etc/pacman.conf`,
`~/.config/paru/paru.conf`, `/var/lib/repo/aur`, or `/var/lib/aurbuild`.**
That isn't a promise the scripts make and might break — it's a consequence of
the live tier running entirely inside a separate VM. The VM boundary *is* the
safety property.

## Why libvirt/QEMU, not Docker

`arch-nspawn`/`makechrootpkg` nested inside Docker needs heavy
`--privileged`/cgroup-v2 workarounds and behaves differently from a real host.
`unshare -n` — the actual property test 4 proves (build-time network
isolation) — is shakier to reason about from inside a container that's
already sitting in another namespace layer. And the IOC self-check shells out
to `bpftool map list`, which wants a real kernel with BTF that containers can
lack. A real VM sidesteps all three. See `PLAN.md` §3–§6 for why those
specific mechanisms matter.

## Layout

```
testrig/
├── config.sh          # shared paths/settings, sourced by every script below
├── lib/common.sh       # logging, virsh/ssh wrappers, VM lifecycle helpers
├── host-setup.sh        # one-time HOST prep (libvirt, kvm, image dir, ssh key)
├── build-base.sh         # slow: cloud image -> provisioned VM -> golden snapshot
├── run.sh                 # fast: revert -> run tests -> report -> cleanup
├── console.sh              # get a shell in the VM (ssh or serial)
├── teardown.sh              # confirmed full removal of everything the rig made
└── cloud-init/               # NoCloud user-data/meta-data templates
```

## Prerequisites (one-time, per host)

```
testrig/host-setup.sh
```

Checks/fixes, in order: `/dev/kvm` access, the `qemu-img`/`qemu-system-x86_64`/
`virt-install`/`xorriso` packages, `libvirtd` active, your user in the
`libvirt` group, the libvirt `default` NAT network started+autostarted, a
dedicated `/var/lib/libvirt/images/paruz-testrig` directory for VM disks, rig
state under `${XDG_STATE_HOME:-~/.local/state}/paruz-testrig` (ssh keypair,
logs), and a rig-only SSH keypair (never your real `~/.ssh` keys).

It's interactive and idempotent — safe to re-run. If it adds you to the
`libvirt` group, **log out and back in** (or `newgrp libvirt`) before
continuing; group membership doesn't apply to your already-running shell.

`testrig/build-base.sh` and `testrig/run.sh` both call `host-setup.sh --check`
as a preflight and fail fast with a pointer here if something's missing.

### Why `/var/lib/libvirt/images/paruz-testrig`, not somewhere under `$HOME`

System libvirtd runs QEMU as the unprivileged `libvirt-qemu` user. A home
directory is typically mode `0700` (not traversable by other users), so
`libvirt-qemu` can't even `stat()` into it, and a VM disk placed there fails
to start with a bare "Permission denied" no matter what the file itself is
chmod'd to. `host-setup.sh` creates
`/var/lib/libvirt/images/paruz-testrig` once via `sudo` (`root:libvirt`, mode
`2775`, setgid) so a member of the `libvirt` group can read/write files there
directly, while libvirt's `dynamic_ownership` (on by default) still chowns the
actively-referenced disk to `libvirt-qemu:kvm` whenever the domain starts.

## Building the base snapshot (slow — do this once)

```
testrig/build-base.sh
```

What it does, in order:

1. Downloads the official Arch cloud image (cached under
   `/var/lib/libvirt/images/paruz-testrig/arch-cloudimg-base.qcow2` —
   re-runs reuse it), verifies its **SHA256** against the mirror's published
   sum (hard fail on mismatch), and best-effort-verifies the mirror's GPG
   signature if `gpg` and a keyserver are reachable (soft warning otherwise —
   the SHA256 check is the one that blocks).
2. Creates a fresh 20G qcow2 **overlay** on top of the cached base image and
   `virt-install --import`s a domain from it, with cloud-init (`--cloud-init`,
   NoCloud datasource) creating an `arch` user with the rig's dedicated SSH
   key and passwordless sudo — no manual interaction.
3. Waits for a DHCP lease from libvirt's `default` network, then for SSH.
4. Over SSH: initializes the pacman keyring, `pacman -Syu`, installs
   `base-devel`+`git`, and bootstraps **paru** from AUR
   (`git clone .../paru.git && makepkg -si`) — the same "bootstrap once,
   unhardened" pattern PLAN.md §8 already uses for `ks-aur-scanner`. This step
   (keyring/paru bootstrap) is generic Arch bring-up that a real user would
   already have; it deliberately stays outside `bin/paruz-setup`.
5. `rsync`s the current repo into the guest and runs **the repo's own
   `bin/paruz-setup --yes`** — this is the dogfooding requirement. If
   `paruz-setup` is broken, this step fails loudly and the base build aborts;
   that's a real finding, not something the rig works around.
6. Runs the fast test tier (`tests/run.sh`) as a smoke check that the
   provisioned state is sane before committing to a snapshot.
7. Shuts the VM down cleanly and takes an **external, disk-only** snapshot
   (`virsh snapshot-create-as ... --disk-only`) named `provisioned`.

Only re-run when you actually need a fresh base — e.g. you changed
`cloud-init/*.tmpl`, or you suspect the golden snapshot itself is stale:

```
testrig/build-base.sh --rebuild-base     # keep the cached cloud image, redo the VM
testrig/build-base.sh --redownload       # also re-fetch the cloud image
```

`--rebuild-base` destroys and redefines the domain first, so it's safe to run
against an existing rig VM.

## Running a test cycle (fast — do this often)

```
testrig/run.sh
```

What it does:

1. `virsh snapshot-revert` back to the `provisioned` snapshot (this is what
   makes iteration cheap — see "Snapshot mechanics" below).
2. Starts the VM, waits for its DHCP lease + SSH.
3. `rsync`s your **current working tree** into the guest (not the tree that
   was baked into the snapshot — you always test what's on disk right now).
4. Runs `tests/run.sh --live` inside the guest (both tiers; `--live` runs the
   fast tests too) and streams the output to your terminal, saving a copy
   under `${XDG_STATE_HOME:-~/.local/state}/paruz-testrig/logs/run-<timestamp>/`.
5. Reports PASS/FAIL per tier and exits non-zero if anything failed —
   `testrig/run.sh` is a valid CI gate command as-is.
6. **On success**, shuts the VM down and reverts it back to `provisioned`
   (prompted `[Y/n]` unless `--yes`), so the rig is tidy and ready for the
   next cycle. **On failure**, the VM is deliberately left running — see
   below.

Useful flags:

```
testrig/run.sh --fast-only      # skip --live entirely (just tests/run.sh); quickest sanity check
testrig/run.sh --rebuild-base   # rebuild the golden snapshot first, then run
testrig/run.sh --yes            # no prompts; auto-cleanup on pass (CI use)
testrig/run.sh --keep-disk      # never auto-cleanup, even on a pass
```

### Debugging a failed live test

These tests check subtle security properties (network really is off during
`build()`, the `.install` scriptlet really didn't run, secrets really aren't
mounted) — a FAIL is the start of an investigation, not just a red line. When
`run.sh` reports a failure it leaves the VM **running, unreverted, exactly as
the test left it**:

```
testrig/console.sh            # ssh in as the rig's guest user (passwordless sudo)
testrig/console.sh --serial   # attach to the serial console instead (virsh console;
                               # useful if networking itself is what's broken)
```

The per-tier logs are also saved on the host under
`.../paruz-testrig/logs/run-<timestamp>/{fast,live}.log`. Once you're done
poking around, either `testrig/run.sh` again (its revert step discards
whatever the failed run left behind) or shut the VM down yourself.

### Snapshot mechanics (why revert is cheap and doesn't leak disk space)

`build-base.sh` takes an **external, disk-only** snapshot with
`virsh snapshot-create-as --disk-only`. This freezes the current disk file as
the snapshot's content and points the domain at a brand-new (initially empty)
overlay for all future writes. `run.sh`'s `virsh snapshot-revert` **deletes the
now-discarded overlay and creates a fresh one** on every revert — so repeated
`run.sh` cycles do not accumulate stray disk files; disk usage stays bounded
at roughly base-image + one overlay, regardless of how many cycles you run.

## Full teardown

```
testrig/teardown.sh              # prompts per step
testrig/teardown.sh --yes        # remove everything, no prompts
testrig/teardown.sh --keep-cache # remove the VM/domain but keep the cached
                                  # cloud image (skips re-download next time)
```

Removes the domain, its disks, and rig state
(`${XDG_STATE_HOME:-~/.local/state}/paruz-testrig`). Never touches the
libvirt `default` network or `libvirtd` itself — those are shared host infra
you may want for other VMs.

## Timings (approximate, hardware-dependent)

| Step | Time |
|---|---|
| `host-setup.sh` (first run, needs `sudo pacman -S`) | ~1 min |
| `build-base.sh` (cached cloud image; `pacman -Syu` + compiling `paru` from AUR + `paruz-setup --yes` + fast-tier smoke test) | several minutes end-to-end, dominated by compiling `paru` |
| `build-base.sh --redownload` | add time for the ~530MB image fetch |
| `run.sh` (revert → boot → SSH → rsync → `--live`, fast+live combined) | around a minute for revert+boot+SSH+rsync+running both tiers on the current fixture set — dominated by boot, not the tests themselves, since the fixtures are tiny |
| `run.sh --fast-only` | well under a minute end-to-end |

The `run.sh` number is small mainly because the *fixture* PKGBUILDs are trivial
(see "Known current status" below for why the live tier's real chroot-build
path isn't actually being exercised end-to-end right now). Once that's fixed,
expect tests 4/5/6 to each take roughly as long as a real `makechrootpkg`
build (dominated by dependency resolution + a fresh `pacman -Sy` inside the
chroot copy), so `run.sh` will land more like a few minutes, not one.

**Memory floor:** the VM defaults to 8G RAM. This is not just a nice-to-have —
compiling `paru` from AUR during `build-base.sh` links a single LTO'd release
binary (`codegen-units=1`, `debuginfo=2`) whose rustc process is prone to
getting SIGKILL'd by the guest's own OOM killer at **both** 2G and 4G, partway
through linking `src/main.rs` (RSS climbs past 3G and the cloud image's fixed
~512M swap doesn't cover the gap). If `build-base.sh` dies partway through
"bootstrapping paru from AUR" with a `(signal: 9, SIGKILL: kill)` in the log,
that's this; raise `PARUZ_TESTRIG_MEMORY_MB` further rather than lowering it.

If your host is memory-constrained, `PARUZ_TESTRIG_MEMORY_MB`/
`PARUZ_TESTRIG_VCPUS`/`PARUZ_TESTRIG_DISK_GB` environment variables (read by
`testrig/config.sh`) tune the VM's resources without editing scripts.

## Known current status (found by actually running this rig)

The point of this rig is to run `tests/run.sh --live` for real instead of
trusting it untested — doing exactly that surfaced a real bug in the parent
repo, on the *first* real run, on a stock `paruz-setup --yes` environment:

**`lib/build.sh`'s `build_provision_sources()` runs
`runuser -u builduser -- ... makepkg --verifysource` inside the chroot copy,
but nothing in the codebase ever creates a `builduser` account there** —
not `paruz-setup`'s `mkarchroot $AUR_CHROOT_ROOT/root base-devel` call, not
`build.sh` itself. `grep -rn builduser lib/ bin/` turns up exactly one hit:
`lib/build.sh:132`. Every real build hits `runuser: user builduser does not
exist`, then fails claiming "You do not have write permission for
$SRCDEST" (a confusing secondary error — the real cause is upstream).

**Consequence for the test suite itself: test 4 (`network-off-build`) is a
false positive.** Its assertion is just "did the build fail" (the fixture's
`build()` calls `curl` and the test wants that to fail under `unshare -n`).
Since `build_provision_sources()` now fails *before* the network-off build
step ever runs, test 4 reports PASS without ever exercising the I2 guarantee
it exists to check. Tests 5 (`noscriptlet`) and 6 (`secrets-isolation`)
correctly FAIL, but for this provisioning bug, not for the property each is
actually named after. Confirmed via `testrig/console.sh` +
`/tmp/paruz-test-{4,5,6}.out` inside the guest — this is not a rig artifact
(no nested-virtualization/network-namespace weirdness involved; it's a plain
missing-user error, same on real hardware).

This was left as-found per the task's own instructions — the rig's job is to
surface bugs in `tests/run.sh --live`, not silently patch around them.

## What this rig deliberately does not do

- It does not modify `bin/`, `lib/`, or `tests/run.sh` in the parent repo —
  it only provisions the disposable environment and drives those unmodified
  entrypoints.
- It does not mock or vendor the AUR. The guest has real outbound network
  access (via libvirt's `default` NAT network) to `aur.archlinux.org` and the
  official Arch mirrors, same as PLAN.md §6 assumes a real machine has.
- It does not try to make the live tier "safe" by weakening it — if
  `tests/run.sh --live` has a real bug, running it in a VM surfaces that bug
  faithfully instead of hiding it behind mocks.

# Packaging & AUR submission

Maintainer notes for shipping paruz. paruz itself is pure Bash, so the package
just installs files (`make install`); there is nothing to compile.

## The PKGBUILD

`PKGBUILD` in this repo is a **`-git`** package (`pkgname=paruz-git`) that builds
from the tip of `main`:

- `pkgver()` derives the version from `git describe` (tag-based once tags exist,
  else `0.rN.gHASH`). The `pkgver=` line is a placeholder regenerated at build.
- `build()` → `make build` (syntax-check); `check()` → `make test` (fast tier);
  `package()` → `make PREFIX=/usr DESTDIR="$pkgdir" install`.
- Runtime deps (`paru`, `ks-aur-scanner`) are themselves in the AUR — fine for an
  AUR package; an AUR helper resolves them.

Regenerate `.SRCINFO` whenever the PKGBUILD changes:

```sh
makepkg --printsrcinfo > .SRCINFO
```

Sanity-check before submitting:

```sh
makepkg --printsrcinfo >/dev/null   # parses clean
namcap PKGBUILD                     # lint (pacman package `namcap`)
makepkg -si                         # actually builds + installs (ideally in the VM rig)
```

## Submitting to the AUR

Requires an [AUR account](https://aur.archlinux.org) with your SSH **public** key
registered (Account → My Account → SSH Public Key). The AUR package lives in its
own git repo, separate from the GitHub source repo.

```sh
git clone ssh://aur@aur.archlinux.org/paruz-git.git aur-paruz-git
cd aur-paruz-git
cp ../paruz/PKGBUILD .
makepkg --printsrcinfo > .SRCINFO      # REQUIRED by the AUR
git add PKGBUILD .SRCINFO
git commit -m "paruz-git <version>"
git push
```

The AUR only accepts commits that include a matching `.SRCINFO`. Never commit
build artifacts (`pkg/`, `src/`, `*.pkg.tar.zst`).

## Cutting a tagged release (e.g. v1.0.0)

1. Ensure `main` is pushed to GitHub and fully green (VM rig: `testrig/run.sh`).
2. Tag: `git tag -a v1.0.0 -m 'paruz v1.0.0' && git push origin v1.0.0`.
   `pkgver()` then reports `1.0.0.r0.g<hash>` for `paruz-git`.
3. *(Optional)* also publish a fixed **`paruz`** package (not `-git`) that tracks
   releases: copy the PKGBUILD, set `pkgname=paruz`, `pkgver=1.0.0`, drop
   `pkgver()`, and point `source` at the tag tarball:

   ```sh
   source=("$pkgname-$pkgver.tar.gz::https://github.com/jesse-osiecki/paruz/archive/refs/tags/v$pkgver.tar.gz")
   ```

   Then submit it to `ssh://aur@aur.archlinux.org/paruz.git` the same way.

## After publishing

Re-run `testrig/smoke-packaged.sh` against the pushed tree to confirm the exact
`makepkg -si` → `paruz-setup` → real-install path a user will run.

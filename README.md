# gcc-packages

Prebuilt GCC compilers for Arch Linux, published as pacman repositories on
GitHub Releases.

Arch ships one GCC, the newest one, and some toolchains need an older one.
nvcc from CUDA 12.9, for example, refuses any host compiler newer than
GCC 14. The AUR has recipes for older compilers, but building one takes
hours, which is too slow for every CI run. This repository builds each pinned
compiler once, checks that it installs and compiles on a current Arch, and
publishes the packages together with a repository database. CI then installs
them with `pacman` in a few seconds.

| Pin | Version | Release |
| --- | --- | --- |
| [`gcc14`](pins/gcc14.env) | 14.4.1+r175+gafa9b4ecc082-1 | `gcc14-14.4.1.r175.gafa9b4ecc082-1` |

The packages are the unmodified AUR recipes, built with `makepkg`. They
install next to the system compiler, never in place of it: the binaries are
versioned (`gcc-14`, `g++-14`), and so is the runtime directory
(`/usr/lib/gcc/x86_64-pc-linux-gnu/14.x`).

## Use it

Add the repository to `/etc/pacman.conf`, pinned to a release tag:

```ini
[gcc14-arch]
SigLevel = Optional TrustAll
Server = https://github.com/MrOz59/gcc-packages/releases/download/gcc14-14.4.1.r175.gafa9b4ecc082-1
```

Then install it:

```sh
pacman -Sy --needed gcc14
g++-14 --version
```

### In GitHub Actions (Arch container)

Add the repository before the job's first `pacman -Syu`, and list `gcc14`
with the other packages. That keeps the job a single full upgrade, never a
partial one:

```yaml
      - name: Setup Arch Linux
        run: |
          cat >> /etc/pacman.conf <<'EOF'

          [gcc14-arch]
          SigLevel = Optional TrustAll
          Server = https://github.com/MrOz59/gcc-packages/releases/download/gcc14-14.4.1.r175.gafa9b4ecc082-1
          EOF
          pacman -Syu --noconfirm --needed gcc14 # ...the rest of the job's packages

      - name: Point nvcc at GCC 14
        run: echo "CUDAHOSTCXX=/usr/bin/g++-14" >> "$GITHUB_ENV"
```

You don't need an AUR build, a cache, or `gcc-ada`/`gcc-d`.

## What a release contains

| File | What it is |
| --- | --- |
| `<pkg>-*.pkg.tar.zst` | The packages (for `gcc14`: `gcc14`, `gcc14-libs`, `gcc14-fortran`) |
| `<repo>.db`, `<repo>.files` (+ `.tar.gz`) | The pacman repository database |
| `<pkg>-source-<commit>.tar.zst` | The exact GCC source the packages were built from |
| `<pkg>-recipe-<revision>.tar.gz` | The AUR recipe at the pinned revision |
| `SHA256SUMS` | Checksums of all of the above |

Package filenames use `.` where the version has `+`, because GitHub rewrites
`+` in asset names. pacman takes the name and version from inside the
package, so `pacman -Q gcc14` still reports `14.4.1+r175+gafa9b4ecc082-1`.

The packages and database are unsigned. pacman still checks each package
against the SHA-256 the database records, and everything is served over HTTPS
from this repository's releases.

## Publishing

To add a compiler, add `pins/<aur-package>.env` (copy
[`pins/gcc14.env`](pins/gcc14.env)). To move one to a new version, change
`AUR_REVISION` to the new AUR commit and `PKGVER`/`PKGREL` to the version it
builds. Then push to `main`.

**Build and publish** builds every pin that has no release yet. For each one
it fetches the recipe (from the AUR, or from its GitHub mirror when the AUR is
down), runs `makepkg`, and checks the version against the pin. It then builds
the repository, installs from it in a clean container, and only after that
creates the release. Once published, it runs the same install check again
against the release URL. A pin that already has a release is skipped.

**Verify** also runs every week, against the newest release of every pin. The
packages link against Arch's `libisl`, `libmpc` and friends, so a soname bump
on the Arch side makes them uninstallable. When that happens, run **Build and
publish** by hand with that pin and `rebuild` set to `1` (then `2`, and so
on). That publishes the same recipe under `<tag>.rebuild1`, and consumers move
their `Server` line to the new tag.

## Licenses

GCC is licensed under GPL-3.0-or-later with the GCC Runtime Library
Exception, and each release includes its corresponding source. The recipes
are by their AUR maintainers and the Arch Linux contributors (0BSD). The
scripts and workflows in this repository are MIT.

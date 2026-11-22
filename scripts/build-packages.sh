#!/usr/bin/env bash
# Build a pinned AUR GCC recipe and lay out a pacman repository.
#
# Runs as root inside a throwaway archlinux:latest container; makepkg itself
# runs as an unprivileged user. Everything that ends up in a release is
# written to <dist-dir>: the packages, the repository database, the GCC source
# the packages were built from, the recipe, and SHA256SUMS.
#
# Usage: build-packages.sh <pin-file> <dist-dir>

set -euo pipefail

usage="usage: build-packages.sh <pin-file> <dist-dir>"
pin_file="$(realpath -- "${1:?${usage}}")"
dist="$(realpath -m -- "${2:?${usage}}")"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../pins/gcc14.env
. "${pin_file}"

log() {
    printf '\n==> %s\n' "$*" >&2
}

if (( EUID != 0 )); then
    echo "Run this as root inside an archlinux container." >&2
    exit 1
fi
if [[ $(uname -m) != x86_64 ]]; then
    echo "Only x86_64 is built." >&2
    exit 1
fi

log "Updating the container"
pacman -Syu --noconfirm --needed base-devel git

builder=builder
work="/var/tmp/${AUR_PACKAGE}-build"
recipe="${work}/recipe"
id -u "${builder}" &> /dev/null || useradd --create-home "${builder}"
install -d -o "${builder}" -g "${builder}" "${work}" "${recipe}"
# runuser keeps root's environment; git and makepkg must not look in /root.
as_builder() {
    runuser -u "${builder}" -- env HOME="/home/${builder}" USER="${builder}" LOGNAME="${builder}" "$@"
}

# The AUR has had long outages; its official GitHub mirror carries the same
# commits, and the revision check below makes the two interchangeable.
log "Fetching the ${AUR_PACKAGE} recipe at ${AUR_REVISION}"
as_builder git -C "${recipe}" init -q
fetched=""
for remote in "https://aur.archlinux.org/${AUR_PACKAGE}.git" https://github.com/archlinux/aur.git; do
    if as_builder git -C "${recipe}" fetch -q --depth 1 "${remote}" "${AUR_REVISION}"; then
        fetched="${remote}"
        break
    fi
    echo "Could not fetch from ${remote}" >&2
done
if [[ -z ${fetched} ]]; then
    echo "The recipe revision is not reachable from any remote." >&2
    exit 1
fi
as_builder git -C "${recipe}" checkout -q --detach "${AUR_REVISION}"
if [[ $(as_builder git -C "${recipe}" rev-parse HEAD) != "${AUR_REVISION}" ]]; then
    echo "Checked out the wrong recipe revision." >&2
    exit 1
fi
echo "Recipe taken from ${fetched}" >&2

# makepkg -s would need sudo for the builder, so the makedepends go in here.
# Read them from the recipe, so a new pin brings its own.
mapfile -t makedepends < <(sed -n 's/^\tmakedepends = //p' "${recipe}/.SRCINFO")
log "Installing makedepends: ${makedepends[*]}"
pacman -S --noconfirm --needed "${makedepends[@]}"

# The GCC checkout: its pinned commit, and the directory makepkg clones it to
# (the name before '::', else the repository's own name).
gcc_source="$(sed -n 's/^\tsource = \(.*#commit=[0-9a-f]\{40\}\)$/\1/p' "${recipe}/.SRCINFO" | head -n 1)"
gcc_commit="${gcc_source##*#commit=}"
if [[ -z ${gcc_source} || ! ${gcc_commit} =~ ^[0-9a-f]{40}$ ]]; then
    echo "Could not read the GCC commit from .SRCINFO." >&2
    exit 1
fi
if [[ ${gcc_source} == *::* ]]; then
    gcc_clone="${gcc_source%%::*}"
else
    gcc_clone="${gcc_source%%#*}"
    gcc_clone="${gcc_clone##*/}"
    gcc_clone="${gcc_clone%.git}"
fi

# Split debug packages would double the disk the build needs and nobody
# installs them; check() is skipped because the testsuite alone takes longer
# than a hosted runner allows.
# makepkg only reads the drop-ins next to the config it was given, so they are
# pulled in explicitly to keep the build identical to a stock one.
cat > "${work}/makepkg.conf" <<'CONF'
source /etc/makepkg.conf
for dropin in /etc/makepkg.conf.d/*.conf; do
    if [[ -r ${dropin} ]]; then source "${dropin}"; fi
done
OPTIONS+=(!debug)
CONF
pkgdest="${work}/packages"
install -d -o "${builder}" -g "${builder}" "${pkgdest}"

log "Building ${AUR_PACKAGE} ${PKGVER}-${PKGREL} from GCC ${gcc_commit}"
(
    cd "${recipe}"
    as_builder env PKGDEST="${pkgdest}" \
        makepkg --config "${work}/makepkg.conf" --nocheck --noconfirm --noprogressbar
)

shopt -s nullglob
built=("${pkgdest}"/*.pkg.tar.zst)
shopt -u nullglob
if (( ${#built[@]} == 0 )); then
    echo "makepkg produced no packages." >&2
    exit 1
fi

# The recipe's pkgver() derives the version from git describe, so check it
# landed where the pin says it should.
for package in "${built[@]}"; do
    version="$(bsdtar -xOf "${package}" .PKGINFO | sed -n 's/^pkgver = //p')"
    if [[ ${version} != "${PKGVER}-${PKGREL}" ]]; then
        echo "${package##*/} is ${version}, but ${pin_file##*/} pins ${PKGVER}-${PKGREL}." >&2
        exit 1
    fi
done

log "Laying out the ${REPO_NAME} repository"
rm -rf "${dist}"
mkdir -p "${dist}"

# GitHub rewrites '+' in release asset names, and pacman downloads exactly the
# name the database records, so the files are renamed before they go into it.
# pacman reads name and version from inside the package, never the filename.
for package in "${built[@]}"; do
    name="${package##*/}"
    install -m 0644 "${package}" "${dist}/${name//+/.}"
done
repo-add --quiet "${dist}/${REPO_NAME}.db.tar.gz" "${dist}"/*.pkg.tar.zst

# repo-add points ${REPO_NAME}.db at the tarball with a symlink; a release
# can't hold one, so pacman gets a real copy under the name it asks for.
for kind in db files; do
    cp --remove-destination "${dist}/${REPO_NAME}.${kind}.tar.gz" "${dist}/${REPO_NAME}.${kind}"
done

# GCC is GPL: every release carries the exact source and recipe it was built
# from, rather than pointing at mirrors that may not keep them.
log "Archiving the corresponding source"
# The clones belong to the builder, and git refuses to read them as root.
as_builder git -C "${recipe}/${gcc_clone}" archive --format=tar --prefix="gcc-${gcc_commit}/" "${gcc_commit}" \
    | zstd -q -T0 -15 -o "${dist}/${AUR_PACKAGE}-source-${gcc_commit}.tar.zst"
as_builder git -C "${recipe}" archive --format=tar.gz --prefix="${AUR_PACKAGE}-recipe-${AUR_REVISION}/" "${AUR_REVISION}" \
    > "${dist}/${AUR_PACKAGE}-recipe-${AUR_REVISION}.tar.gz"

(
    cd "${dist}"
    sha256sum -- * > SHA256SUMS
)

# Prove the repository installs and works the way consumers will use it,
# before anything is published.
bash "${here}/scripts/verify-repo.sh" "${pin_file}" "file://${dist}"

log "Done"
ls -l "${dist}" >&2

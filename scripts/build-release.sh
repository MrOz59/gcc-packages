#!/usr/bin/env bash
# Run as an unprivileged user in the Arch build container.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$(realpath -m -- "${1:?pass the release output directory}")"
recipe_revision=87e62884e433543b59aaa2a28dcceb2e6f314054
gcc_revision=afa9b4ecc0828b627cb5c57f71f8c5fa23e5a274
version=14.4.1+r175+gafa9b4ecc082-1
tag="gcc14-${version}"

if [[ $EUID == 0 || $(uname -m) != x86_64 ]]; then
    printf 'Run the release build as a non-root x86_64 Arch user.\n' >&2
    exit 1
fi
test "${GITHUB_REF_NAME:-$tag}" = "$tag"
mkdir -p "$output"
work="$(mktemp -d -- "$(dirname "$output")/gcc14-build.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

git init -q "$work/recipe"
git -C "$work/recipe" fetch --depth 1 https://github.com/archlinux/aur.git "$recipe_revision"
git -C "$work/recipe" checkout -q --detach "$recipe_revision"
test "$(git -C "$work/recipe" rev-parse HEAD)" = "$recipe_revision"
git -C "$work/recipe" archive --format=tar.gz -o "$output/aur-recipe.tar.gz" HEAD
cp -- "$repo/scripts/gcc14-cuda.patch" "$output/"

cd "$work/recipe"
patch --batch --fuzz=0 -p1 < "$repo/scripts/gcc14-cuda.patch"
printf 'source /etc/makepkg.conf\nOPTIONS+=(!debug)\n' > "$work/makepkg.conf"
# Keep upstream source available for the exact corresponding source archive.
export SRCDEST="$work/downloads"
export PKGDEST="$output"
mkdir -p "$SRCDEST"
makepkg --config "$work/makepkg.conf" --nocheck --noconfirm

test -f "$output/gcc14-$version-x86_64.pkg.tar.zst"
test -f "$output/gcc14-libs-$version-x86_64.pkg.tar.zst"
test "$(git --git-dir="$SRCDEST/gcc14" rev-parse "$gcc_revision^{commit}")" = "$gcc_revision"
git --git-dir="$SRCDEST/gcc14" archive --prefix=gcc14/ --format=tar.gz \
    -o "$output/gcc-source-$gcc_revision.tar.gz" "$gcc_revision"

prefix="$work/check"
mkdir -p "$prefix"
for name in gcc14 gcc14-libs; do
    tar --zstd -xf "$output/$name-$version-x86_64.pkg.tar.zst" -C "$prefix" usr
done
compiler="$prefix/usr/bin/g++-14"
test "$("$compiler" -dumpfullversion)" = "${version%%+*}"
cat > "$work/probe.cpp" <<'CPP'
#include <concepts>
#include <string>
#include <vector>

int main() {
  static_assert(std::same_as<std::vector<std::string>::value_type, std::string>);
  return std::vector<std::string>{"CUDA host compiler"}.size() != 1;
}
CPP
"$compiler" -std=c++20 "$work/probe.cpp" -o "$work/probe"
"$work/probe"

{
    printf 'release=%s\naur_revision=%s\ngcc_revision=%s\n' "$tag" "$recipe_revision" "$gcc_revision"
    printf 'producer_revision=%s\n' "$(git -C "$repo" rev-parse HEAD)"
    printf 'compiler=%s\n' "$("$compiler" -dumpfullversion)"
    printf '\nArch build environment\n'
    pacman -Q
} > "$output/BUILD-INFO.txt"
cp -- "$work/makepkg.conf" "$output/makepkg.conf"

cd "$output"
sha256sum gcc14*.pkg.tar.zst gcc-source-*.tar.gz aur-recipe.tar.gz gcc14-cuda.patch \
    makepkg.conf BUILD-INFO.txt > SHA256SUMS

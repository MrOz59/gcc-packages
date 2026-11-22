#!/usr/bin/env bash
# Install a pinned GCC from a pacman repository and check that it works next
# to the system compiler, the way a CUDA build uses it as nvcc's host compiler.
#
# Runs as root in a throwaway Arch container: it adds the repository to
# /etc/pacman.conf and installs packages.
#
# Usage: verify-repo.sh <pin-file> <pacman Server URL>
#   e.g. file:///dist, or
#   https://github.com/<owner>/<repo>/releases/download/<tag>

set -euo pipefail

usage="usage: verify-repo.sh <pin-file> <pacman Server URL>"
pin_file="${1:?${usage}}"
server="${2:?${usage}}"

# shellcheck source=../pins/gcc14.env
. "${pin_file}"

log() {
    printf '\n==> %s\n' "$*" >&2
}

if (( EUID != 0 )); then
    echo "Run this as root inside an archlinux container." >&2
    exit 1
fi

major="${PKGVER%%.*}"
cc="gcc-${major}"
cxx="g++-${major}"

log "Adding [${REPO_NAME}] at ${server}"
if ! grep -qxF "[${REPO_NAME}]" /etc/pacman.conf; then
    cat >> /etc/pacman.conf <<EOF

[${REPO_NAME}]
SigLevel = Optional TrustAll
Server = ${server}
EOF
fi

# The system gcc goes in too: the point is that the pinned compiler sits
# beside it rather than replacing it.
pacman -Syu --noconfirm --needed gcc "${AUR_PACKAGE}"

expected="${PKGVER%%+*}"
actual="$("${cxx}" -dumpfullversion)"
if [[ ${actual} != "${expected}" ]]; then
    echo "${cxx} reports ${actual}, expected ${expected}." >&2
    exit 1
fi
system="$(g++ -dumpfullversion)"
if [[ ${system%%.*} == "${major}" ]]; then
    echo "The system g++ is GCC ${major}; ${AUR_PACKAGE} must not displace it." >&2
    exit 1
fi
log "${cxx} is ${actual}; the system g++ is still ${system}"

probe="$(mktemp -d)"
trap 'rm -rf -- "${probe}"' EXIT

# What nvcc hands the host compiler for a .cu file: C++17 and a few common
# headers.
cat > "${probe}/probe17.cpp" <<'EOF'
#include <memory>
#include <string>
#include <vector>

int main() {
    std::vector<std::string> v{"x"};
    auto p = std::make_unique<int>(static_cast<int>(v.size()));
    return *p - 1;
}
EOF
# The rest of libstdc++ in C++20, threads included.
cat > "${probe}/probe20.cpp" <<'EOF'
#include <concepts>
#include <numeric>
#include <span>
#include <string>
#include <thread>
#include <vector>

template <std::integral T>
T sum(std::span<const T> values) {
    return std::accumulate(values.begin(), values.end(), T{});
}

int main() {
    std::vector<int> values{1, 2, 3};
    int total = 0;
    std::jthread worker([&] { total = sum<int>(values); });
    worker.join();
    return total == 6 ? 0 : 1;
}
EOF
printf '#include <stdio.h>\nint main(void) { return puts("c ok") < 0; }\n' > "${probe}/probe.c"

log "Compiling and running probes"
"${cc}" -O2 -o "${probe}/c" "${probe}/probe.c"
"${probe}/c"
run() {
    local source_file="$1"
    shift
    "${cxx}" "$@" -o "${probe}/cxx" "${source_file}"
    "${probe}/cxx"
    echo "${cxx} $*: ok" >&2
}
run "${probe}/probe17.cpp" -std=c++17 -O2
run "${probe}/probe20.cpp" -std=c++20 -O2 -pthread
run "${probe}/probe20.cpp" -std=c++20 -O2 -pthread -flto

log "${AUR_PACKAGE} from [${REPO_NAME}] works"

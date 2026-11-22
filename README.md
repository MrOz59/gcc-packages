# GCC 14 packages for Arch CUDA builds

This repository supplies a native x86_64 Arch GCC 14 C and C++ compiler for
CUDA `nvcc -ccbin`. The release includes `gcc14` and `gcc14-libs`. Hermes
continues to use Arch's ordinary toolchain for the rest of its build.

The [build script](scripts/build-release.sh) pins the AUR recipe and exact GCC
source commit. A small [tracked patch](scripts/gcc14-cuda.patch) restricts the
recipe to C and C++, one compiler build stage, and no Fortran, debug packages,
multilib, or generated API documentation. The GitHub runner verifies the
unpacked compiler by compiling and running a C++20 program.

Download the two archives from the same versioned release and verify
`SHA256SUMS` before extracting them to an isolated prefix. The driver is at
`usr/bin/g++-14` below that prefix. The compiler uses a current Arch
userspace and its `binutils`, `libisl`, `libmpc`, and `zstd` packages.

Each release publishes the corresponding GCC source archive, the pinned AUR
recipe with its launchers, and the applied patch alongside the binaries.
License notices are in the GCC source and package files. `BUILD-INFO.txt`
records the source revisions and exact Arch packages in the build environment.
The tagged workflow and build script record the compilation and packaging
commands.

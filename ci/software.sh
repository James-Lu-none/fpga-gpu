#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
jobs=$(nproc)
printf 'Using %s available CPUs for software builds.\n' "$jobs"
mkdir -p artifacts/software
# Preserve stdout/stderr even if the compiler or simulation fails.
exec > >(tee artifacts/software/build.log) 2>&1
collect() {
    local rc=$?
    trap - EXIT
    cp -a fpga-gpu-hardware/sim/build artifacts/software/simulation 2>/dev/null || true
    find fpga-gpu-firmware -maxdepth 1 -type f \( -name 'firmware.*' -o -name '*.elf' \) -exec cp {} artifacts/software/ \; || true
    find fpga-gpu-driver/driver -maxdepth 1 -name '*.ko' -exec cp {} artifacts/software/ \; || true
    exit "$rc"
}
trap collect EXIT
verilator --version > artifacts/software/verilator-version.txt
clang-18 --version > artifacts/software/clang-version.txt
dpkg-query -W > artifacts/software/packages.txt
cmake -S fpga-gpu-compiler -B fpga-gpu-compiler/build \
    -DCMAKE_BUILD_TYPE=Release -DLLVM_DIR=/usr/lib/llvm-18/lib/cmake/llvm
cmake --build fpga-gpu-compiler/build --parallel "$jobs"
ctest --test-dir fpga-gpu-compiler/build --output-on-failure --no-tests=error --parallel "$jobs"
make -C fpga-gpu-hardware/sim lint
make -C fpga-gpu-hardware/sim check JOBS="$jobs" TRACE=0
make -C fpga-gpu-firmware -j"$jobs"
make -C fpga-gpu-driver -j"$jobs" umd_lib user_tests
kdir=$(find /usr/src -maxdepth 1 -type d -name 'linux-headers-*-generic' | sort -V | tail -n1)
test -n "$kdir"
printf '%s\n' "$kdir" > artifacts/software/kernel-headers.txt
make -C fpga-gpu-driver/driver -j"$jobs" KDIR="$kdir"

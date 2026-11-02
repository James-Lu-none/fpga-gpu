#!/usr/bin/env bash
# Run on DUT B from a deployed checkout: sudo bash ci/hardware-test.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
logs="$root/results"
mkdir -p "$logs"
driver="$root/fpga-gpu-driver"
firmware="$root/fpga-gpu-firmware"
compiler="$root/fpga-gpu-compiler"
jobs=$(nproc)
kdir="/lib/modules/$(uname -r)/build"
mode=${FPGAGPU_HARDWARE_MODE:-gpu}
[[ $mode == gpu || $mode == l2 ]] || { echo "ERROR: Invalid hardware mode: $mode"; exit 2; }
echo "Hardware mode: $mode"
loaded=0
resource=
export FPGAGPU_COMPILER_DIR="$compiler" LD_LIBRARY_PATH="$driver/umd"

run() {
    local name=$1 limit=$2 rc
    shift 2
    echo "RUN: $name: $*"
    if timeout --kill-after=5 "$limit" "$@" > "$logs/$name.log" 2>&1; then
        echo "PASS: $name"
    else
        rc=$?
        echo "FAIL: $name (exit=$rc)"
        tail -c 8192 "$logs/$name.log"
        return "$rc"
    fi
}

finish() {
    local rc=$? unload_rc=0
    trap - EXIT
    set +e
    timeout --kill-after=5 15 dmesg --color=never > "$logs/dmesg-after.log" 2>&1
    find "$driver/tests" -maxdepth 1 -type f \( -name '*_cpu.bin' -o -name '*_gpu.bin' \) -exec cp {} "$logs/" \;
    if (( loaded )); then
        run module-unload 30 rmmod fpgagpu_driver
        unload_rc=$?
        if (( rc == 0 )); then rc=$unload_rc; fi
    fi
    echo "SUMMARY: hardware tests exit=$rc; results=$logs"
    exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tools=(make gcc insmod rmmod dmesg timeout)
if [[ $mode == gpu ]]; then
    tools+=(g++ cmake clang-18 riscv64-unknown-elf-gcc riscv64-unknown-elf-objcopy riscv64-unknown-elf-objdump)
    [[ -d /usr/lib/llvm-18/lib/cmake/llvm ]] || { echo 'ERROR: Require LLVM 18 development files.'; exit 1; }
fi
for tool in "${tools[@]}"; do
    command -v "$tool" > /dev/null || { echo "ERROR: Missing DUT dependency: $tool"; exit 1; }
done
[[ -d $kdir ]] || { echo "ERROR: Require running-kernel headers at $kdir"; exit 1; }
[[ ! -d /sys/module/fpgagpu_driver ]] || { echo 'ERROR: fpgagpu_driver is already loaded.'; exit 1; }
resource=$(python3 "$root/ci/dut.py" device)
run dmesg-before 15 dmesg --color=never
if [[ $mode == gpu ]]; then
    run compiler-configure 300 cmake -S "$compiler" -B "$compiler/build" \
        -DCMAKE_BUILD_TYPE=Release -DLLVM_DIR=/usr/lib/llvm-18/lib/cmake/llvm -DBUILD_TESTING=OFF
    run compiler-build 600 cmake --build "$compiler/build" --parallel "$jobs"
    run firmware-build 300 make -C "$firmware" -j"$jobs"
    run driver-build 300 make -C "$driver" -j"$jobs" KDIR="$kdir"
    cd "$firmware"
    run firmware-load 90 ./load_fw "$resource"
else
    run driver-build 300 make -C "$driver/driver" -j"$jobs" KDIR="$kdir"
    run l2-test-build 60 make -C "$driver/tests" test_l2_memory test_vrf
fi
run module-load 30 insmod "$driver/driver/fpgagpu_driver.ko" queue_mode=0
loaded=1
for ((attempt=0; attempt<50; attempt++)); do
    [[ -e /dev/fpgagpu0 ]] && break
    sleep 0.2
done
[[ -e /dev/fpgagpu0 && -e ${resource%/resource0}/driver ]] || {
    echo 'ERROR: Driver did not bind/create /dev/fpgagpu0.'; exit 1;
}
cd "$driver/tests"
if [[ $mode == l2 ]]; then
    failed=0
    for path in l2 l1 lsu-uniform lsu-pair lsu-lane0 lsu-lane1; do
        if run "$path-memory" 60 ./test_l2_memory "$resource" "$path"; then
            cat "$logs/$path-memory.log"
        else
            failed=1
        fi
    done
    if run vrf-registers 120 ./test_vrf "$resource"; then
        cat "$logs/vrf-registers.log"
    else
        failed=1
    fi
    (( failed == 0 )) || exit 1
    echo 'PASS: L2, L1, LSU and VRF isolation tests'
    exit 0
fi
minimal_failed=0
for mode in store copy register rs1-add; do
    if run "isa-$mode" 120 ./test_isa_memory "$mode"; then
        :
    else
        minimal_failed=1
    fi
done
for mode in constant scalar copy thread-id; do
    if run "minimal-$mode" 120 ./test_opencl_minimal "$mode"; then
        :
    else
        minimal_failed=1
    fi
done
(( minimal_failed == 0 )) || exit 1
tests=(test_dma test_opencl_buffer_copy test_opencl_vector_add test_opencl_matmul \
       test_opencl_matmul_occupancy test_opencl_branch_divergence)
for test in "${tests[@]}"; do
    run "$test" 120 "./$test"
done
echo "PASS: ${#tests[@]} hardware tests completed"

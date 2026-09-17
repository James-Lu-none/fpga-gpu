#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color Definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

print_step() {
    echo -e "\n${BLUE}${BOLD}==>${NC} ${CYAN}${BOLD}$1${NC}"
}

print_success() {
    echo -e "${GREEN}${BOLD}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}${BOLD}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}${BOLD}✗ $1${NC}"
}

# 1. Require Root / Sudo
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}Notice: This script requires root privileges. Elevating with sudo...${NC}"
    exec sudo bash "$0" "$@"
fi

# Parse optional arguments
RUN_TESTS=true
LOAD_FIRMWARE=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-test)
            RUN_TESTS=false
            shift
            ;;
        --no-fw)
            LOAD_FIRMWARE=false
            shift
            ;;
        -h|--help)
            echo "Usage: sudo ./run_full_test.sh [options]"
            echo ""
            echo "Options:"
            echo "  --no-test   Load driver and firmware without running tests"
            echo "  --no-fw     Skip firmware reload (only reload driver and run tests)"
            echo "  -h, --help  Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# 2. Verify PCIe Device Status
print_step "Checking Artix-7 PCIe Endpoint (Device 10ee:7021)..."
if ! lspci -d 10ee:7021 > /dev/null 2>&1; then
    print_warning "Device 10ee:7021 not found in current PCIe tree! Attempting bus rescan..."
    echo 1 > /sys/bus/pci/rescan
    sleep 1
    if ! lspci -d 10ee:7021 > /dev/null 2>&1; then
        print_error "FPGA PCIe device not detected! Please ensure the FPGA is programmed and PCIe link is up."
        exit 1
    fi
fi
PCIE_INFO=$(lspci -d 10ee:7021)
print_success "Found PCIe Device: ${PCIE_INFO}"

# 3. Build & Reload Kernel Module (KMD)
print_step "Compiling and Reloading fpgagpu Kernel Driver (fpgagpu_driver.ko)..."
if lsmod | grep -q "^fpgagpu_driver"; then
    echo "Unloading existing fpgagpu_driver module..."
    rmmod fpgagpu_driver || {
        print_error "Failed to unload fpgagpu_driver. Ensure no processes have /dev/fpgagpu0 open."
        exit 1
    }
fi

make -C "${SCRIPT_DIR}/fpga-gpu-driver/driver" clean > /dev/null 2>&1 || true
make -C "${SCRIPT_DIR}/fpga-gpu-driver/driver" -j"$(nproc)"
insmod "${SCRIPT_DIR}/fpga-gpu-driver/driver/fpgagpu_driver.ko"
print_success "Kernel module loaded successfully."

# 4. Load Baremetal RISC-V Firmware into BRAM
if [ "$LOAD_FIRMWARE" = true ]; then
    print_step "Building and Loading Firmware to PicoRV32 BRAM..."
    make -C "${SCRIPT_DIR}/fpga-gpu-firmware" -j"$(nproc)"
    (
        cd "${SCRIPT_DIR}/fpga-gpu-firmware"
        ./load_fw
    )
    print_success "PicoRV32 firmware written & verified in BRAM."
fi

# 5. Build UMD & Test Suite
print_step "Building OpenCL Userspace Driver (UMD) & Verification Tests..."
make -C "${SCRIPT_DIR}/fpga-gpu-driver/umd" -j"$(nproc)"
make -C "${SCRIPT_DIR}/fpga-gpu-driver/tests" -j"$(nproc)"
print_success "UMD (libfpgagpu_opencl.so) and test binaries are up to date."

# 6. Execute Test Suite
if [ "$RUN_TESTS" = true ]; then
    print_step "Running OpenCL Test Suite..."
    export LD_LIBRARY_PATH="${SCRIPT_DIR}/fpga-gpu-driver/umd:${LD_LIBRARY_PATH}"
    export FPGAGPU_COMPILER_DIR="${SCRIPT_DIR}/fpga-gpu-compiler"

    TEST_FAILED=0

    if "${SCRIPT_DIR}/fpga-gpu-driver/tests/test_opencl_buffer_copy"; then
        print_success "Test 1 (Buffer Copy & clFinish) PASSED"
    else
        print_error "Test 1 (Buffer Copy & clFinish) FAILED"
        TEST_FAILED=$((TEST_FAILED + 1))
    fi

    if "${SCRIPT_DIR}/fpga-gpu-driver/tests/test_opencl_vector_add"; then
        print_success "Test 2 (Vector Add NDRange Kernel) PASSED"
    else
        print_error "Test 2 (Vector Add NDRange Kernel) FAILED"
        TEST_FAILED=$((TEST_FAILED + 1))
    fi

    if "${SCRIPT_DIR}/fpga-gpu-driver/tests/test_opencl_matmul"; then
        print_success "Test 3 (Matrix Multiplication Kernel) PASSED"
    else
        print_error "Test 3 (Matrix Multiplication Kernel) FAILED"
        TEST_FAILED=$((TEST_FAILED + 1))
    fi

    if [ "$TEST_FAILED" -eq 0 ]; then
        echo -e "${GREEN}${BOLD} ALL OPENCL TESTS PASSED SUCCESSFULLY! ${NC}"
    else
        echo -e "${RED}${BOLD} ${TEST_FAILED} TEST(S) FAILED ! ${NC}"
    fi

    exit "$TEST_FAILED"
fi

print_success "Setup and loading complete."

# FPGA-GPU: Full-Stack GPGPU Accelerator on Xilinx Artix-7 FPGA

FPGA-GPU is an open-source, full-stack GPGPU accelerator designed for the Xilinx Artix-7 (XC7A200T) FPGA on the ALINX AX7A200B development platform. It integrates custom hardware RTL, baremetal RISC-V on-chip firmware, an LLVM-based compiler infrastructure, and a high-performance Linux kernel driver supporting Unified Virtual Memory (UVM) and direct Scatter-Gather PCIe DMA.

## Cloning & Initial Setup

CI implementation、手動 bitstream 產生方式與 AI triage / HIL 後續規劃見 [CI Pipeline](docs/ci/README.md)。

```bash
git clone --recurse-submodules https://github.com/James-Lu-none/fpga-gpu.git
cd fpga-gpu
git submodule update --init --recursive
```

## Build & Quick Start Guide

### 1. LLVM Compiler Toolchain Build

```bash
cd fpga-gpu-compiler
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Compile a sample kernel to machine code (.hex or .bin)
cd ..
./scripts/fpgagpu-clang -O2 examples/01_vec_add/vec_add.c -o vec_add.hex
```

### 2. Hardware RTL Synthesis & Bitstream Generation

```bash
cd fpga-gpu-hardware
vivado -mode batch -source implement.tcl
# Optional: generate bitstream from routed checkpoint
vivado -mode batch -source write_bitstream.tcl
```

### 3. Linux Kernel Driver Build & Installation

```bash
cd fpga-gpu-driver
make clean
make

sudo rmmod driver/fpgagpu_driver.ko
sudo insmod driver/fpgagpu_driver.ko queue_mode=0

sudo lspci -d 10ee:7021 -vvv
sudo dmesg | tail -n 20

sudo ./tests/test_dma
sudo ./tests/test_compute
```

### 4. RISC-V Firmware Compilation

```bash
cd fpga-gpu-firmware
make clean
make
sudo ./load_fw
```
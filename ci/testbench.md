# FPGA testbench CI

- Job order: build-sim, implementation, bitstream, power-on, load-bitstream, cold-boot, hardware-test, power-off.
- `ci/testbench.py`: A controls Arduino, SSH, deployment, Vivado Lab and log collection.
- `ci/dut.py`: B handles PCIe and UART.
- `ci/hardware-test.sh`: B builds components, loads firmware/module, runs tests and cleans up.
- `fpga-gpu-hardware/*.tcl`: Vivado project, implementation, bitstream and programming.
- Files are deployed to `/tmp/fpgagpu-ci.*` on B. The path is saved in `dut-workspace.txt`.

## Commands

- On A, from the repository root:

```bash
python3 ci/testbench.py smoke --power-action on
bash ci/load-bitstream.sh BUNDLE --source-sha SHA --bin-sha256 HASH --program-mode flash
python3 ci/testbench.py cold-boot
python3 ci/testbench.py hardware-test
python3 ci/testbench.py shutdown
```

- On B, from a deployed workspace or checkout with submodules:

```bash
sudo bash ci/hardware-test.sh
```

## Setup

- A: Python 3, SSH, AMD JTAG drivers and `/opt/Xilinx/2026.1/Vivado_Lab/settings64.sh`.
- A Arduino: `/dev/ttyACM0`, 9600 baud.
- SSH key: `/home/github-runner/.ssh/pve-core`; target: `user@10.0.0.7`.
- Overrides: `DUT_SSH_KEY`, `DUT_SSH_TARGET`, `ARDUINO_DEVICE`, `VIVADO_LAB_SETTINGS`.
- B: passwordless sudo, Python 3 and UART `/dev/ttyUSB0`, 115200 baud, 8N1.
- Close other serial monitors before CI.
- B build dependencies:

```bash
sudo apt-get install build-essential cmake clang-18 llvm-18-dev zlib1g-dev libzstd-dev \
  gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf linux-headers-$(uname -r) kmod
```

## Behavior

- This experiment pins hardware to `fbaf5ac`, before system CSR and the BAR0 GPC alias.
- CI always writes and verifies Flash, then shuts down B, waits 5 seconds and powers it on again.
- A new Linux boot ID is checked before hardware tests. PCIe is enumerated during boot.
- Direct PCIe CSR dumps are disabled for this older hardware; UART diagnostics remain.
- SRAM programming is lost when the FPGA loses power. Flash boot requires matching board jumpers.
- Only `top.bin` is uploaded to GitHub. Its checksum is checked before programming.
- Local logs: `/home/github-runner/ci-artifacts/OWNER/REPO/RUN/ATTEMPT/KIND`.
- Hardware test logs include UART, step logs and `dut-results.tar.gz`.
- Cold-boot logs are retained under the `cold-boot` artifact directory.
- B first runs direct ISA store/copy/register/rs1-add tests, then the four OpenCL minimal cases and larger tests.
- Direct ISA logs are named `isa-store`, `isa-copy`, `isa-register` and `isa-rs1-add`.
- Minimal test logs are named `minimal-constant`, `minimal-scalar`, `minimal-copy` and `minimal-thread-id`.
- All eight minimal cases report results; any failure skips larger tests. Cleanup collects logs and unloads the module.
- Power-off runs after success or failure: SSH shutdown, then Arduino K after 60 seconds if needed.
- Runner/Arduino must remain available for power-off. B workspaces remain for inspection.

L2 isolation mode

1. In Actions, choose Run workflow and set `hardware_mode` to `l2`.
2. CI builds the diagnostic bitstream, programs Flash and cold-boots B as usual.
3. B builds/loads only the driver and runs `test_l2_memory` for all six paths; no firmware or OpenCL kernel is used.

- Paths: direct L2, L1/L2, then LSU/L1/L2 with uniform, paired, lane-0-only and lane-1-only operands. Host verifies DDR `0x1000-0x1FFF` and both guard pages via DMA.
- Inspect `<path>-memory.log` and `<path>_memory_cpu.bin` / `<path>_memory_gpu.bin`; first L1/L2/AXI addresses are printed in Actions. All six cases report before the job fails.
- Push builds and the default manual option use `gpu`.

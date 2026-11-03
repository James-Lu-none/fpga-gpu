# FPGA testbench CI

1. Build and simulate on the `vivado` runner, implement and generate `top.bin`.
2. Power on B through Arduino on runner A and wait for SSH.
3. Verify the binary checksum, remove the unbound PCIe endpoint, program Flash, boot the FPGA and rescan PCIe. B stays powered on.
4. Build the compiler, firmware and driver on B; load firmware/module and run DMA, buffer copy, vector add, matrix multiplication, occupancy and branch divergence tests.
5. Collect UART, dmesg and test results; unload the module and shut B down after success or failure.

- A uses `/dev/ttyACM0` at 9600 baud and `/opt/Xilinx/2026.1/Vivado_Lab/settings64.sh`.
- SSH uses `/home/github-runner/.ssh/pve-core` and `user@10.0.0.7`; B needs passwordless sudo and running-kernel headers.
- B captures `/dev/ttyUSB0` at 115200 baud. Close other serial monitors.
- `ci/testbench.py` handles A-side control, deployment and evidence collection. `ci/dut.py` handles B PCIe/UART operations; `ci/hardware-test.sh` builds and tests on B.
- Only `top.bin` is uploaded. Logs remain at `/home/github-runner/ci-artifacts/OWNER/REPO/RUN/ATTEMPT/KIND`; deployed B workspaces remain under `/tmp/fpgagpu-ci.*`.
- See `changelog.md` for root causes, archived diagnostics and review bases.

B build dependencies:

```bash
sudo apt-get install build-essential cmake clang-18 llvm-18-dev zlib1g-dev libzstd-dev \
  gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf linux-headers-$(uname -r) kmod
```

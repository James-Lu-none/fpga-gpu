# FPGA-GPU: Xilinx Artix-7 (AX7A200B) PCIe Accelerator

## design decisions

### pcie ip

originally, a custom pcie ip (`axi_pcie` + custom `gpu_dma_master.v` + software page table) was used to communicate with the host. However, it was later replaced with the XDMA IP (`DMA/Bridge Subsystem for PCI Express` in AXI-Stream mode) provided by Xilinx to support Scatter-Gather (SG) DMA via Linux `dma_map_sg()`.

### riscv command processor (cp) softcore

To mirror modern GPGPU hardware architectures (e.g. NVIDIA GSP / AMD CP):
- An official **YosysHQ PicoRV32 RV32I RISC-V** core ([`rtl/picorv32.v`](file:///c:/Users/user/workspace/fpga-gpu/rtl/picorv32.v)) is integrated as an on-chip Command Processor.
- **Direct Mailbox & Hardware IRQ Architecture (0-Latency Best Practice)**:
  1. **`picorv32_axi` (CPU Softcore Top Module)**: PicoRV32 core wrapper with AXI4-Lite master interface and hardware interrupt (`irq[0]`) enabled.
  2. **`riscv_bram.v` (Dual-Port On-Chip BRAM)**:
     - **Port A**: Connected to RISC-V CPU for code and data execution.
     - **Port B**: Connected directly to PCIe XDMA BAR0 MMIO for Host PC direct Mailbox writes (`0x3F00`).
  3. **`riscv_cp_system.v` (SoC Top & Direct Mailbox Interconnect)**:
     - Detects Host writes to Mailbox address `0x3F00` and generates a 1-cycle hardware interrupt pulse (`irq[0]`).
     - Routes RISC-V AXI Master to `gpu_compute_core` (`0x4000_0000`) and HDMI SiI9134 I2C controller (`0x5000_0000`).
- **Role**:
  1. Offloads SiI9134 HDMI display controller I2C configuration.
  2. Interrupt-driven parsing of Host PCIe CUDA Task Descriptors directly from BRAM Mailbox (`0x3F00`).
  3. Dispatches parallel execution tasks to `gpu_compute_core` SIMD ALUs.
- **Resource Footprint**: Consumes ~1,200 LUTs (< 1.5% of Artix-7 XC7A200T resources) with 16KB dual-port on-chip BRAM.

### clock and reset architecture

- **PCIe Reference Clock Buffer (`IBUFDS_GTE2`)**: 
  - The PCIe 100MHz reference clock uses Bank 216 GTP dedicated reference clock pins `F10` (`sys_clk_clk_p`) and `E10` (`sys_clk_clk_n`).
  - In 7-Series FPGAs, MGTREFCLK pins cannot connect to standard single-ended `IBUF` primitives due to physical silicon routing constraints.
  - A Utility Buffer IP (`util_ds_buf`) with `C_BUF_TYPE` set to `IBUFDSGTE` (`IBUFDS_GTE2`) is instantiated in Block Design (`design_1.bd`) to convert the differential clock input into `IBUF_OUT` for `xdma_0/sys_clk`.
- **System Reset & Internal Clocking**:
  - External PCIe reset `sys_rst_n` (`T18`) feeds directly into `xdma_0/sys_rst_n`.
  - All internal user modules (`gpu_top`, `gpu_regs_slave_lite_v1_0_S00_AXI`, `gpu_compute_core`) operate on XDMA's generated clock `xdma_0/axi_aclk` (125MHz) and active-low reset `xdma_0/axi_aresetn`.

### GPU AXI4 peripheral (register space) logic modifications

The register space is built using Vivado IP Wizard generated AXI4-Lite Slave peripheral ([`rtl/gpu_regs_slave_lite_v1_0_S00_AXI.v`](file:///c:/Users/user/workspace/fpga-gpu/rtl/gpu_regs_slave_lite_v1_0_S00_AXI.v)).

1. **Pristine Register Case**:
   - The wizard-generated AXI-Lite write `case` statement remains 100% untouched for standard register write storage (`slv_reg0` .. `slv_reg15`).
   - The `assign S_AXI_RDATA` statement remains pristine Vivado template code returning `slv_reg0` .. `slv_reg15`.

2. **Encapsulated User Logic Block**:
   - All custom hardware logic is encapsulated inside the dedicated `// Add user logic here` block at the end of the module.
   - **Doorbell (`0x00`)**: Generates a 1-cycle `doorbell_pulse` start trigger when writing non-zero to `slv_reg0`.
   - **INT_STATUS (`0x04`)**: Hardware latches `slv_reg1[0] <= 1'b1` when GPU compute completes (`task_done_irq`).
   - **INT_ACK (`0x08`)**: Clears `slv_reg1[0] <= 1'b0` and generates a 1-cycle `irq_ack_pulse` when writing to `0x08` (`slv_reg2`).
   - **DMA Addresses (`0x0C`~`0x18`)**: Output continuous 64-bit bus addresses `reg_ring_dma_addr` (`{slv_reg4, slv_reg3}`) and `reg_desc_dma_addr` (`{slv_reg6, slv_reg5}`) to top-level logic.
   - **OPCODE (`0x1C`)**: Outputs 32-bit SIMD vector opcode `reg_opcode` (`slv_reg7`).

### cuda kernel submission & host pipeline

- **Host Task Descriptor Application ([`host/cuda_kernel_submit.cpp`](file:///c:/Users/user/workspace/fpga-gpu/host/cuda_kernel_submit.cpp))**:
  - Provides a CUDA-like kernel submission C++ runtime application.
  - Constructs 64-byte aligned `cuda_task_descriptor` (Magic `0x43554441`, Opcode, Grid/Block dimensions, DMA pointers).
  - Streams vector payload data to FPGA over XDMA H2C device (`/dev/xdma0_h2c_0`).
  - Triggers GPU doorbell register (`0x00`) via XDMA User BAR MMIO (`/dev/xdma0_user`).
  - Reads back parallel GPU compute results from C2H device (`/dev/xdma0_c2h_0`) and verifies 100% numerical correctness.

### cuda compute core & shared memory (smem) hierarchy

- **SIMD Vector Compute Core ([`rtl/gpu_compute_core.v`](file:///c:/Users/user/workspace/fpga-gpu/rtl/gpu_compute_core.v))**:
  - Implements an AXI4-Stream 64-bit SIMD vector compute pipeline.
  - **CUDA Shared Memory (SMEM / Scratchpad SRAM)**: Integrates an ultra-fast 256-word x 64-bit On-Chip SRAM inside the core, mirroring modern NVIDIA GPU Memory Hierarchies (RMEM/SMEM tier).
  - **Supported Opcodes**:
    - **`Opcode 1` (Vector Add)**: $Output = Input + 1$ (Streams to C2H).
    - **`Opcode 2` (Vector Multiply)**: $Output = Input \times 2$ (Streams to C2H).
    - **`Opcode 3` (CUDA Parallel Render)**: Computes 24-bit RGB pixel data and writes directly to Framebuffer VRAM (`framebuffer_ram.v`) for HDMI 1080P output.
    - **`Opcode 4` (SMEM Write)**: Stores incoming stream payload into SMEM Scratchpad SRAM.
    - **`Opcode 5` (SMEM Multi-Pass Accumulate)**: Multi-pass execution ($Output[i] = Input[i] + \text{SMEM}[i]$).

### framebuffer & hdmi parallel rendering pipeline

- **Dual-Port Framebuffer VRAM ([`rtl/framebuffer_ram.v`](file:///c:/Users/user/workspace/fpga-gpu/rtl/framebuffer_ram.v))**:
  - Bridges GPU SIMD Compute Core parallel rendering output (`gpu_compute_core.v` Opcode 3) to SiI9134 HDMI Transmitter display pipeline.
  - Allows Host CUDA Kernels to submit parallel render jobs, compute 24-bit RGB pixel data on FPGA SIMD cores, write directly to Framebuffer VRAM, and output real-time 1080P/720P video over HDMI!

### issues during implementation

The entire system uses XDMA's generated clock (axi_aclk: 125MHz) and asynchronous reset (axi_aresetn)

1. Reset across clock domains: reset from XDMA to HDMI IP
  In HDMI top module, a MMCME2_BASE ip is used to generate pixel clock (clk_pix), which is desynchronized with XDMA's clock domain. So when we try to reset HDMI module with axi_aresetn, it will not be reset properly. To fix this issue, we use a two-flop synchronizer to convert the asynchronous reset to a synchronous reset for the HDMI IP. (see rtl/hdmi/hdmi_top.sv:66 in detail)

2. Setup/Hold time violations from XDMA to GPU submodules
  Since in GPU modules, there are thousands of registers connected to the global reset signal (`axi_aresetn`), the massive fanout and long routing distances across the FPGA fabric cause severe recovery/removal time violations. Thus, a Reset Tree (Reset Pipeline) is implemented, so that each reset net is locally bounded, ensuring perfect timing closure regardless of chip size. In this project, the reset signal from XDMA is only distributed to the top-level GPU module. Then, the reset signal is registered at each hierarchical boundary (e.g., Top -> GPC -> SM -> Submodules).
3. reduce fanout for reset signal
  By removing reset logic from all "Datapath" registers (e.g., 256-bit buses, operands) and only resetting "Control" registers (e.g., FSM states, valid signals).
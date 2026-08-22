# FPGA-GPU: Xilinx Artix-7 (AX7A200B) PCIe Accelerator

## design decisions

### pcie ip

originally, a custom pcie ip (`axi_pcie` + custom `vgpu_dma_master.v` + software page table) was used to communicate with the host. However, it was later replaced with the XDMA IP (`DMA/Bridge Subsystem for PCI Express` in AXI-Stream mode) provided by Xilinx to support Scatter-Gather (SG) DMA via Linux `dma_map_sg()`.

### clock and reset architecture

- external pcie reference clock (`sys_clk_p` / `sys_clk_n`) and reset (`sys_rst_n`) feed directly into the XDMA IP (`xdma_0`).
- all internal user modules (`vgpu_top`, `vgpu_regs_slave_lite_v1_0_S00_AXI`, `vgpu_compute_core`) use XDMA's generated clock `xdma_0/axi_aclk` and active-low reset `xdma_0/axi_aresetn`.

### GPU AXI4 peripheral (register space) logic modifications

The register space is built using Vivado IP Wizard generated AXI4-Lite Slave peripheral ([`rtl/vgpu_regs_slave_lite_v1_0_S00_AXI.v`](file:///c:/Users/user/workspace/fpga-gpu/rtl/vgpu_regs_slave_lite_v1_0_S00_AXI.v)).

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

### compute core interface

- Converted `vgpu_compute_core.v` from custom AXI-Full DMA master to standard AXI4-Stream slave (`s_axis_dma`) and master (`m_axis_dma`).
- Supports vector operation modes (`0` = Passthrough, `1` = Vector Add, `2` = Vector Mul).
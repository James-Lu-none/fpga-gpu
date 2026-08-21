`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/20
// Design Name: vGPU Core Top Level IP Wrapper
// Module Name: vgpu_top
// Project Name: fpga-gpu (Accelerated Computing with Linux Kernel vGPU-Core)
// Target Devices: Xilinx Artix-7 (XC7A200T-2FBG484)
// Tool Versions: Vivado 2026+
//
// ==============================================================================
// 1. SYSTEM ARCHITECTURE & BLOCK DIAGRAM
// ==============================================================================
//
//   +-------------------------------------------------------------------------+
//   |                             Linux Host (CPU)                            |
//   |  User App (VFS/IOCTL) <---> vGPU Kernel Driver <---> PCIe Root Complex   |
//   +------------------------------------+------------------------------------+
//                                        | PCIe Gen2 x2
//   +------------------------------------+------------------------------------+
//   | FPGA Hardware                      |                                    |
//   |                                    v                                    |
//   |                      +--------------------------+                        |
//   |                      | axi_pcie / XDMA Endpoint |                        |
//   |                      +------------+-------------+                        |
//   |                                   |                                     |
//   |             +---------------------+---------------------+               |
//   |             | (BAR0 MMIO: 32-bit)                       | (DMA: 64-bit) |
//   |             v                                           ^               |
//   |    +-----------------+                                  |               |
//   |    | AXI SmartConnect|                                  |               |
//   |    +--------+--------+                                  |               |
//   |             |                                           |               |
//   |             v [s_axi_ctrl] (32-bit AXI-Lite)            | [m_axi_dma]   |
//   |   +-----------------------------------------------------+-------------+ |
//   |   | vgpu_top                                            | (64-bit)    | |
//   |   |                                                     |             | |
//   |   |  +--------------------+        +--------------------+----------+  | |
//   |   |  | vgpu_axi_lite_regs |------->|        vgpu_dma_master        |  | |
//   |   |  | (MMIO Config/Door) |        |    (AXI4-Full Bus Master)     |  | |
//   |   |  +---------+----------+        +---------------+---------------+  | |
//   |   |            ^                                   |                  | |
//   |   |            |                                   v                  | |
//   |   |            | ACK                     +-------------------+        | |
//   |   |            +-------------------------| vgpu_compute_core |        | |
//   |   |                                      | (Vector SIMD ALU) |        | |
//   |   |                                      +-------------------+        | |
//   |   +-------------------------------------------------------------------+ |
//   +-------------------------------------------------------------------------+
//
// ==============================================================================
// 2. BUS INTERFACE DESIGN RATIONALE (WHY 32-BIT VS 64-BIT?)
// ==============================================================================
//
// [A] Control Plane: `s_axi_ctrl` (AXI4-Lite, 32-bit Data, 6-bit Addr)
//   - Purpose: Low-bandwidth control plane for BAR0 MMIO register access.
//   - Why 32-bit:
//       1. Standard PCIe MMIO Register Alignment: PCIe MMIO registers are
//          traditionally DWORD-aligned (4 bytes: 0x00, 0x04, 0x08, 0x0C...).
//       2. CPU Driver Compatibility: Linux drivers use standard 32-bit MMIO
//          accessors (`ioread32()`, `iowrite32()`). 64-bit addresses (such as
//          `dma_handle` and `page_table_dma`) are split into LOW and HIGH
//          32-bit registers (0x0C/0x10 and 0x14/0x18), ensuring cross-platform
//          compatibility across 32-bit and 64-bit CPU architectures without
//          requiring 64-bit atomic MMIO bus transactions.
//       3. Resource Efficiency: Minimizes FPGA LUT/FF footprint for register
//          decoding logic without any performance bottleneck.
//
// [B] Data Plane: `m_axi_dma` (AXI4-Full, 64-bit Data, 64-bit Addr)
//   - Purpose: High-bandwidth bulk data transfer between Host RAM and FPGA.
//   - Why 64-bit:
//       1. 64-bit Address Width: Allows direct physical addressing of Host
//          RAM above the 4GB boundary (>0x1_0000_0000) allocated by Linux
//          `dma_alloc_coherent()` / `dma_map_page()`, achieving zero-copy DMA
//          without slow SWIOTLB bounce buffers.
//       2. 64-bit Data Width: At 125 MHz AXI clock, 64-bit data bus provides
//          1.0 GB/s throughput (125 MHz * 8 Bytes), fully saturating the
//          PCIe Gen2 x2 physical link bandwidth.
//       3. Structure Alignment: Matches the 16-byte (128-bit) `struct vgpu_command`
//          (Beat 0: 32-bit opcode + 32-bit payload_size; Beat 1: 64-bit payload_vaddr),
//          enabling complete command packet fetching in exactly 2 clock cycles.
//       4. SIMD Parallel Computing: Feeds the Compute Core with 2x 32-bit
//          parallel vector elements per clock cycle for dual-issue compute.
//
// ==============================================================================
// 3. BAR0 MMIO REGISTER MAP (Base Address: PCIe BAR0)
// ==============================================================================
//   Offset | Name           | Access | Description
//   -------+----------------+--------+------------------------------------------
//   0x00   | DOORBELL       | W      | Write non-zero value to trigger DMA FSM
//   0x04   | INT_STATUS     | R      | Bit 0: 1 = Task compute completed
//   0x08   | INT_ACK        | W      | Write 1 to clear interrupt status bit
//   0x0C   | RING_ADDR_LOW  | R/W    | Lower 32 bits of Ring Buffer Host DMA Bus Address
//   0x10   | RING_ADDR_HIGH | R/W    | Upper 32 bits of Ring Buffer Host DMA Bus Address
//   0x14   | PT_ADDR_LOW    | R/W    | Lower 32 bits of Page Table / Payload DMA Address
//   0x18   | PT_ADDR_HIGH   | R/W    | Upper 32 bits of Page Table / Payload DMA Address
//   0x20   | UVM_MODE       | R/W    | 0 = Contiguous IOVA (IOMMU), 1 = Scatter-Gather PT
//
// ==============================================================================
// 4. HARDWARE EXECUTION & INTERRUPT DATAFLOW LIFECYCLE
// ==============================================================================
//   1. Driver init configures Ring Buffer Base (0x0C/0x10) and PT Base (0x14/0x18).
//   2. User App submits command to Host Ring Buffer; Driver writes 1 to Doorbell (0x00).
//   3. `vgpu_dma_master` initiates AXI4 Read burst to fetch `cmds[head]` (16 Bytes).
//   4. `vgpu_dma_master` reads payload data from Host RAM.
//   5. `vgpu_compute_core` executes vector operations (Add / Mul / Passthrough).
//   6. `vgpu_dma_master` writes computed result back to Host RAM.
//   7. `vgpu_dma_master` writes updated `head` pointer to Host Ring Buffer (Offset 0x00).
//   8. Hardware asserts `usr_irq_req` to PCIe IP, firing an MSI interrupt to CPU.
//   9. Linux Driver `vgpu_irq_handler` reads INT_STATUS (0x04), sends INT_ACK (0x08),
//      and wakes up waiting User space thread via wait_queue.
//
//////////////////////////////////////////////////////////////////////////////////

module vgpu_top (
    // Clock and Reset (Synchronous with PCIe axi_aclk_out 125MHz)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi_ctrl:m_axi_dma, ASSOCIATED_RESET axi_aresetn, FREQ_HZ 125000000" *)
    input  wire        axi_aclk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        axi_aresetn,

    // AXI4-Lite Slave Interface (Control / MMIO BAR0 from PCIe M_AXI)
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl AWADDR" *)
    input  wire [5:0]  s_axi_ctrl_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl AWVALID" *)
    input  wire        s_axi_ctrl_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl AWREADY" *)
    output wire        s_axi_ctrl_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl WDATA" *)
    input  wire [31:0] s_axi_ctrl_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl WSTRB" *)
    input  wire [3:0]  s_axi_ctrl_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl WVALID" *)
    input  wire        s_axi_ctrl_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl WREADY" *)
    output wire        s_axi_ctrl_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl BRESP" *)
    output wire [1:0]  s_axi_ctrl_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl BVALID" *)
    output wire        s_axi_ctrl_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl BREADY" *)
    input  wire        s_axi_ctrl_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl ARADDR" *)
    input  wire [5:0]  s_axi_ctrl_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl ARVALID" *)
    input  wire        s_axi_ctrl_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl ARREADY" *)
    output wire        s_axi_ctrl_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl RDATA" *)
    output wire [31:0] s_axi_ctrl_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl RRESP" *)
    output wire [1:0]  s_axi_ctrl_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl RVALID" *)
    output wire        s_axi_ctrl_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl RREADY" *)
    input  wire        s_axi_ctrl_rready,

    // AXI4-Full Master Interface (DMA Bus Master to PCIe S_AXI)
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma ARADDR" *)
    output wire [63:0] m_axi_dma_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma ARLEN" *)
    output wire [7:0]  m_axi_dma_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma ARSIZE" *)
    output wire [2:0]  m_axi_dma_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma ARBURST" *)
    output wire [1:0]  m_axi_dma_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma ARVALID" *)
    output wire        m_axi_dma_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma ARREADY" *)
    input  wire        m_axi_dma_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma RDATA" *)
    input  wire [63:0] m_axi_dma_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma RRESP" *)
    input  wire [1:0]  m_axi_dma_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma RLAST" *)
    input  wire        m_axi_dma_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma RVALID" *)
    input  wire        m_axi_dma_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma RREADY" *)
    output wire        m_axi_dma_rready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma AWADDR" *)
    output wire [63:0] m_axi_dma_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma AWLEN" *)
    output wire [7:0]  m_axi_dma_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma AWSIZE" *)
    output wire [2:0]  m_axi_dma_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma AWBURST" *)
    output wire [1:0]  m_axi_dma_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma AWVALID" *)
    output wire        m_axi_dma_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma AWREADY" *)
    input  wire        m_axi_dma_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma WDATA" *)
    output wire [63:0] m_axi_dma_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma WSTRB" *)
    output wire [7:0]  m_axi_dma_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma WLAST" *)
    output wire        m_axi_dma_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma WVALID" *)
    output wire        m_axi_dma_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma WREADY" *)
    input  wire        m_axi_dma_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma BRESP" *)
    output wire [1:0]  m_axi_dma_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma BVALID" *)
    output wire        m_axi_dma_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_dma BREADY" *)
    output wire        m_axi_dma_bready,

    // Interrupt Request Interface (Connected to PCIe INTX_MSI_Request / INTX_MSI_Grant)
    output wire        usr_irq_req,
    input  wire        usr_irq_ack
);

    // Internal Interconnect Wires
    wire        doorbell_pulse;
    wire [63:0] ring_base_addr;
    wire [63:0] pt_base_addr;
    wire [31:0] uvm_mode;
    wire        task_done_irq;
    wire        irq_ack_pulse;

    assign usr_irq_req = task_done_irq;

    // AXI-Lite MMIO Registers Instance
    vgpu_axi_lite_regs u_regs (
        .s_axi_aclk             (axi_aclk),
        .s_axi_aresetn          (axi_aresetn),
        .s_axi_awaddr           (s_axi_ctrl_awaddr),
        .s_axi_awvalid          (s_axi_ctrl_awvalid),
        .s_axi_awready          (s_axi_ctrl_awready),
        .s_axi_wdata            (s_axi_ctrl_wdata),
        .s_axi_wstrb            (s_axi_ctrl_wstrb),
        .s_axi_wvalid           (s_axi_ctrl_wvalid),
        .s_axi_wready           (s_axi_ctrl_wready),
        .s_axi_bresp            (s_axi_ctrl_bresp),
        .s_axi_bvalid           (s_axi_ctrl_bvalid),
        .s_axi_bready           (s_axi_ctrl_bready),
        .s_axi_araddr           (s_axi_ctrl_araddr),
        .s_axi_arvalid          (s_axi_ctrl_arvalid),
        .s_axi_arready          (s_axi_ctrl_arready),
        .s_axi_rdata            (s_axi_ctrl_rdata),
        .s_axi_rresp            (s_axi_ctrl_rresp),
        .s_axi_rvalid           (s_axi_ctrl_rvalid),
        .s_axi_rready           (s_axi_ctrl_rready),
        .doorbell_pulse         (doorbell_pulse),
        .reg_ring_dma_addr      (ring_base_addr),
        .reg_pagetable_dma_addr (pt_base_addr),
        .reg_uvm_mode           (uvm_mode),
        .task_done_irq          (task_done_irq),
        .irq_ack_pulse          (irq_ack_pulse)
    );

    // AXI4 DMA Engine Instance
    vgpu_dma_master u_dma_master (
        .m_axi_aclk             (axi_aclk),
        .m_axi_aresetn          (axi_aresetn),
        .start_doorbell         (doorbell_pulse),
        .ring_base_addr         (ring_base_addr),
        .pt_base_addr           (pt_base_addr),
        .uvm_mode               (uvm_mode),
        .task_done_irq          (task_done_irq),
        .m_axi_araddr           (m_axi_dma_araddr),
        .m_axi_arlen            (m_axi_dma_arlen),
        .m_axi_arsize           (m_axi_dma_arsize),
        .m_axi_arburst          (m_axi_dma_arburst),
        .m_axi_arvalid          (m_axi_dma_arvalid),
        .m_axi_arready          (m_axi_dma_arready),
        .m_axi_rdata            (m_axi_dma_rdata),
        .m_axi_rresp            (m_axi_dma_rresp),
        .m_axi_rlast            (m_axi_dma_rlast),
        .m_axi_rvalid           (m_axi_dma_rvalid),
        .m_axi_rready           (m_axi_dma_rready),
        .m_axi_awaddr           (m_axi_dma_awaddr),
        .m_axi_awlen            (m_axi_dma_awlen),
        .m_axi_awsize           (m_axi_dma_awsize),
        .m_axi_awburst          (m_axi_dma_awburst),
        .m_axi_awvalid          (m_axi_dma_awvalid),
        .m_axi_awready          (m_axi_dma_awready),
        .m_axi_wdata            (m_axi_dma_wdata),
        .m_axi_wstrb            (m_axi_dma_wstrb),
        .m_axi_wlast            (m_axi_dma_wlast),
        .m_axi_wvalid           (m_axi_dma_wvalid),
        .m_axi_wready           (m_axi_dma_wready),
        .m_axi_bresp            (m_axi_dma_bresp),
        .m_axi_bvalid           (m_axi_dma_bvalid),
        .m_axi_bready           (m_axi_dma_bready)
    );

endmodule

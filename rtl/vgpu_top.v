`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/22
// Design Name: vGPU Core Top Level IP Wrapper (XDMA AXI-Stream Architecture)
// Module Name: vgpu_top
// Project Name: fpga-gpu (Accelerated Computing with Linux Kernel vGPU-Core)
// Target Devices: Xilinx Artix-7 (XC7A200T-2FBG484)
// Tool Versions: Vivado 2026+
//
// ==============================================================================
// 1. SYSTEM ARCHITECTURE
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
//   |                     +-----------------------------+                     |
//   |                     | XDMA Subsystem (PCIe IP Core)|                     |
//   |                     +------------+----------------+                     |
//   |                                  |                                      |
//   |             +--------------------+--------------------+                 |
//   |             | (MMIO BAR0: 32-bit)| (AXI-Stream)       |                 |
//   |             v                    v [s_axis_dma]       ^ [m_axis_dma]    |
//   |   +-------------------+  +--------------------------------+             |
//   |   |vgpu_axi_lite_regs |  |       vgpu_compute_core        |             |
//   |   | (MMIO Registers)  |  |  (AXI4-Stream SIMD Vector Core)|             |
//   |   +---------+---------+  +--------------------------------+             |
//   |             | (Opcode)                   ^                              |
//   |             +----------------------------+                              |
//   +-------------------------------------------------------------------------+
//
//////////////////////////////////////////////////////////////////////////////////

module vgpu_top (
    // Clock and Reset (Synchronous with PCIe axi_aclk 125MHz)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi_ctrl:s_axis_dma:m_axis_dma, ASSOCIATED_RESET axi_aresetn, FREQ_HZ 125000000" *)
    input  wire        axi_aclk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        axi_aresetn,

    // AXI4-Lite Slave Interface (Control / MMIO BAR0 from PCIe XDMA M_AXI_LITE)
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

    // AXI4-Stream Slave Interface (Input Stream from XDMA M_AXIS_H2C)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_dma TDATA" *)
    input  wire [63:0] s_axis_dma_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_dma TKEEP" *)
    input  wire [7:0]  s_axis_dma_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_dma TVALID" *)
    input  wire        s_axis_dma_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_dma TREADY" *)
    output wire        s_axis_dma_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_dma TLAST" *)
    input  wire        s_axis_dma_tlast,

    // AXI4-Stream Master Interface (Output Stream to XDMA S_AXIS_C2H)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_dma TDATA" *)
    output wire [63:0] m_axis_dma_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_dma TKEEP" *)
    output wire [7:0]  m_axis_dma_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_dma TVALID" *)
    output wire        m_axis_dma_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_dma TREADY" *)
    input  wire        m_axis_dma_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_dma TLAST" *)
    output wire        m_axis_dma_tlast,

    // Interrupt Request Interface (Connected to XDMA usr_irq_req)
    output wire        usr_irq_req,
    input  wire        usr_irq_ack
);

    // Internal Signals
    wire        doorbell_pulse;
    wire [63:0] ring_base_addr;
    wire [63:0] desc_base_addr;
    wire [31:0] compute_opcode;
    reg         task_done_irq;
    wire        irq_ack_pulse;

    assign usr_irq_req = task_done_irq;

    // Trigger IRQ when compute stream finishes (m_axis_dma_tlast) or on Doorbell
    always @(posedge axi_aclk) begin
        if (!axi_aresetn) begin
            task_done_irq <= 1'b0;
        end else begin
            if (m_axis_dma_tvalid && m_axis_dma_tready && m_axis_dma_tlast) begin
                task_done_irq <= 1'b1;
            end else if (irq_ack_pulse) begin
                task_done_irq <= 1'b0;
            end
        end
    end

    // AXI-Lite MMIO Registers Instance
    vgpu_regs_slave_lite_v1_0_S00_AXI u_regs (
        .S_AXI_ACLK             (axi_aclk),
        .S_AXI_ARESETN          (axi_aresetn),
        .S_AXI_AWADDR           (s_axi_ctrl_awaddr),
        .S_AXI_AWPROT           (3'b000),
        .S_AXI_AWVALID          (s_axi_ctrl_awvalid),
        .S_AXI_AWREADY          (s_axi_ctrl_awready),
        .S_AXI_WDATA            (s_axi_ctrl_wdata),
        .S_AXI_WSTRB            (s_axi_ctrl_wstrb),
        .S_AXI_WVALID           (s_axi_ctrl_wvalid),
        .S_AXI_WREADY           (s_axi_ctrl_wready),
        .S_AXI_BRESP            (s_axi_ctrl_bresp),
        .S_AXI_BVALID           (s_axi_ctrl_bvalid),
        .S_AXI_BREADY           (s_axi_ctrl_bready),
        .S_AXI_ARADDR           (s_axi_ctrl_araddr),
        .S_AXI_ARPROT           (3'b000),
        .S_AXI_ARVALID          (s_axi_ctrl_arvalid),
        .S_AXI_ARREADY          (s_axi_ctrl_arready),
        .S_AXI_RDATA            (s_axi_ctrl_rdata),
        .S_AXI_RRESP            (s_axi_ctrl_rresp),
        .S_AXI_RVALID           (s_axi_ctrl_rvalid),
        .S_AXI_RREADY           (s_axi_ctrl_rready),
        .doorbell_pulse         (doorbell_pulse),
        .reg_ring_dma_addr      (ring_base_addr),
        .reg_desc_dma_addr      (desc_base_addr),
        .reg_opcode             (compute_opcode),
        .task_done_irq          (task_done_irq),
        .irq_ack_pulse          (irq_ack_pulse)
    );

    // AXI4-Stream GPU Vector Compute Core Instance
    vgpu_compute_core #(
        .C_AXIS_DATA_WIDTH(64)
    ) u_compute_core (
        .clk                    (axi_aclk),
        .rst_n                  (axi_aresetn),
        .opcode                 (compute_opcode),
        .s_axis_tdata           (s_axis_dma_tdata),
        .s_axis_tkeep           (s_axis_dma_tkeep),
        .s_axis_tvalid          (s_axis_dma_tvalid),
        .s_axis_tready          (s_axis_dma_tready),
        .s_axis_tlast           (s_axis_dma_tlast),
        .m_axis_tdata           (m_axis_dma_tdata),
        .m_axis_tkeep           (m_axis_dma_tkeep),
        .m_axis_tvalid          (m_axis_dma_tvalid),
        .m_axis_tready          (m_axis_dma_tready),
        .m_axis_tlast           (m_axis_dma_tlast)
    );

endmodule

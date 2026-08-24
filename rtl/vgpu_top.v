`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/22
// Design Name: vGPU Core Top Level IP Wrapper (Direct Host-to-CP Mailbox Architecture)
// Module Name: vgpu_top
// Project Name: fpga-gpu (Accelerated Computing with Linux Kernel vGPU-Core)
// Target Devices: Xilinx Artix-7 (XC7A200T-2FBG484)
// Tool Versions: Vivado 2026+
//////////////////////////////////////////////////////////////////////////////////

module vgpu_top (
    // Clock and Reset (Synchronous with PCIe axi_aclk 125MHz)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi_ctrl:s_axis_dma:m_axis_dma, ASSOCIATED_RESET axi_aresetn, FREQ_HZ 125000000" *)
    input  wire        axi_aclk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        axi_aresetn,

    // AXI4-Lite Slave Interface (Control / MMIO BAR0 Direct Mailbox from PCIe XDMA M_AXI_LITE)
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl AWADDR" *)
    input  wire [13:0] s_axi_ctrl_awaddr,
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
    input  wire [13:0] s_axi_ctrl_araddr,
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
    input  wire        usr_irq_ack,

    // SiI9134 HDMI Physical Display Ports (Mapped to constrs/hdmi.xdc)
    output wire        hdmi_nreset,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 hdmi_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 148500000" *)
    output wire        hdmi_clk,
    output wire        hdmi_hs,
    output wire        hdmi_vs,
    output wire        hdmi_de,
    output wire [23:0] hdmi_d,
    inout  wire        hdmi_scl,
    inout  wire        hdmi_sda,
    output wire        hdmi_init_done
);

    // Internal Signals
    wire [31:0] compute_opcode;
    reg         task_done_irq;
    wire        cp_trap;

    assign usr_irq_req = task_done_irq;
    assign s_axi_ctrl_bresp = 2'b00;
    assign s_axi_ctrl_rresp = 2'b00;

    // Trigger IRQ when compute stream finishes (m_axis_dma_tlast)
    always @(posedge axi_aclk) begin
        if (!axi_aresetn) begin
            task_done_irq <= 1'b0;
        end else begin
            if (m_axis_dma_tvalid && m_axis_dma_tready && m_axis_dma_tlast) begin
                task_done_irq <= 1'b1;
            end else if (usr_irq_ack) begin
                task_done_irq <= 1'b0;
            end
        end
    end

    // RISC-V Command Processor (CP) SoC Instance (Direct BRAM Mailbox & IRQ Driven)
    riscv_cp_system u_riscv_cp (
        .clk                    (axi_aclk),
        .rst_n                  (axi_aresetn),

        // Host PCIe XDMA AXI-Lite Slave Interface (Direct BAR0 BRAM Mailbox 0x3F00)
        .s_axi_awvalid          (s_axi_ctrl_awvalid),
        .s_axi_awready          (s_axi_ctrl_awready),
        .s_axi_awaddr           ({18'd0, s_axi_ctrl_awaddr}),
        .s_axi_wvalid           (s_axi_ctrl_wvalid),
        .s_axi_wready           (s_axi_ctrl_wready),
        .s_axi_wdata            (s_axi_ctrl_wdata),
        .s_axi_wstrb            (s_axi_ctrl_wstrb),
        .s_axi_bvalid           (s_axi_ctrl_bvalid),
        .s_axi_bready           (s_axi_ctrl_bready),

        .s_axi_arvalid          (s_axi_ctrl_arvalid),
        .s_axi_arready          (s_axi_ctrl_arready),
        .s_axi_araddr           ({18'd0, s_axi_ctrl_araddr}),
        .s_axi_rvalid           (s_axi_ctrl_rvalid),
        .s_axi_rready           (s_axi_ctrl_rready),
        .s_axi_rdata            (s_axi_ctrl_rdata),

        // GPU Compute Core Register Output Interface (0x4000_0000)
        .gpu_axi_awvalid        (),
        .gpu_axi_awready        (1'b1),
        .gpu_axi_awaddr         (),
        .gpu_axi_wvalid         (),
        .gpu_axi_wready         (1'b1),
        .gpu_axi_wdata          (compute_opcode),
        .gpu_axi_wstrb          (),
        .gpu_axi_bvalid         (1'b1),
        .gpu_axi_bready         (),

        .gpu_axi_arvalid        (),
        .gpu_axi_arready        (1'b1),
        .gpu_axi_araddr         (),
        .gpu_axi_rvalid         (1'b1),
        .gpu_axi_rready         (),
        .gpu_axi_rdata          (32'd0),

        .trap_out               (cp_trap)
    );

    // Framebuffer Video Memory Signals
    wire        fb_we;
    wire [18:0] fb_addr;
    wire [23:0] fb_rgb;

    // Instantiate Dual-Port Framebuffer VRAM (GPU Core Write, HDMI Display Read)
    framebuffer_ram #(
        .H_RES(640),
        .V_RES(480),
        .DATA_WIDTH(24)
    ) u_framebuffer (
        .clk_gpu                (axi_aclk),
        .we_gpu                 (fb_we),
        .addr_gpu               (fb_addr),
        .din_gpu                (fb_rgb),
        .clk_pix                (hdmi_clk),
        .addr_pix               (fb_addr),
        .dout_pix               ()
    );

    // HDMI Video Output Interface (SiI9134 1080P@60Hz Display Pipeline)
    hdmi_top u_hdmi (
        .sys_clk_125m          (axi_aclk),
        .rst_n                 (axi_aresetn),
        .hdmi_nreset           (hdmi_nreset),
        .hdmi_clk              (hdmi_clk),
        .hdmi_hs               (hdmi_hs),
        .hdmi_vs               (hdmi_vs),
        .hdmi_de               (hdmi_de),
        .hdmi_d                (hdmi_d),
        .hdmi_scl              (hdmi_scl),
        .hdmi_sda              (hdmi_sda),
        .hdmi_init_done        (hdmi_init_done)
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
        .m_axis_tlast           (m_axis_dma_tlast),
        .fb_we                  (fb_we),
        .fb_addr                (fb_addr),
        .fb_rgb                 (fb_rgb)
    );

endmodule

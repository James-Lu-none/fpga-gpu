`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////--
// GPU Top Module
// Encapsulates the RISC-V Command Processor (CP) and the Graphics Processing Cluster
////////////////////////////////////////////////////////////////////////////////--

module gpu_top (
    input  wire                              clk,
    input  wire                              rst_n,

    // PCIe XDMA BAR0 AXI-Lite Slave Interface (Host Control)
    axi_lite_if.slave                        s_axi_lite,

    // 256-bit AXI4-Full Master Interface (To Global Memory Crossbar)
    axi4_if.master                           m_axi_gmem,

    // Framebuffer Parallel Render Output Interface
    output wire                              fb_we,
    output wire [18:0]                       fb_addr,
    output wire [23:0]                       fb_rgb,

    // PCIe Host Interrupts
    output wire                              usr_irq_req,
    input  wire                              usr_irq_ack
);

    // -------------------------------------------------------------------------
    // Internal Interconnect
    // -------------------------------------------------------------------------
    // AXI-Lite connection between RISC-V CP and GPC
    axi_lite_if #(.ADDR_W(32), .DATA_W(32)) rv_gpu_axil();

    // -------------------------------------------------------------------------
    // 1. RISC-V Command Processor SoC (Control Plane)
    // -------------------------------------------------------------------------
    riscv_cp_system u_riscv_cp (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .s_axi                  (s_axi_lite),
        .m_axi_lite             (rv_gpu_axil),
        .trap_out               (internal_cp_trap)
    );

    // -------------------------------------------------------------------------
    // Interrupt Handshake Logic for PCIe XDMA
    // -------------------------------------------------------------------------
    wire internal_cp_trap;
    reg  cp_trap_d;
    reg  irq_req_reg;
    
    wire trap_edge = internal_cp_trap & ~cp_trap_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cp_trap_d   <= 1'b0;
            irq_req_reg <= 1'b0;
        end else begin
            cp_trap_d <= internal_cp_trap;
            
            if (trap_edge) begin
                irq_req_reg <= 1'b1;
            end else if (usr_irq_ack) begin
                irq_req_reg <= 1'b0;
            end
        end
    end

    assign usr_irq_req = irq_req_reg;

    // -------------------------------------------------------------------------
    // 2. Graphics Processing Cluster (Compute Plane)
    // -------------------------------------------------------------------------
    gpu_processing_cluster #(
        .NUM_SMS(1)
    ) u_gpc (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .s_axi_lite             (rv_gpu_axil),
        .m_axi_gmem             (m_axi_gmem),
        .fb_we                  (fb_we),
        .fb_addr                (fb_addr),
        .fb_rgb                 (fb_rgb)
    );

endmodule

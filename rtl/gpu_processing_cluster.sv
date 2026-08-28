`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////--
// Graphics Processing Cluster (GPC)
// Wraps one or more Streaming Multiprocessors (SMs)
////////////////////////////////////////////////////////////////////////////////--

module gpu_processing_cluster #(
    parameter NUM_SMS = 1
)(
    input  wire                              clk,
    input  wire                              rst_n,

    // AXI4-Lite Slave Interface (From RISC-V Command Processor)
    axi_lite_if.slave                        s_axi_lite,

    // 256-bit AXI4-Full Master Interface (To Global Memory Crossbar)
    axi4_if.master                           m_axi_gmem,

    // Framebuffer Parallel Render Output Interface (from SM Core)
    output wire                              fb_we,
    output wire [18:0]                       fb_addr,
    output wire [23:0]                       fb_rgb
);

    // -------------------------------------------------------------------------
    // SM Instantiation (Currently NUM_SMS = 1, pass-through mode)
    // -------------------------------------------------------------------------
    
    // Future scaling note: If NUM_SMS > 1, an AXI Arbiter/Crossbar must be 
    // implemented here to aggregate the m_axi_gmem signals from multiple SMs,
    // and an AXI-Lite decoder to broadcast/address the individual SMs.
    
    gpu_streaming_multiprocessor u_sm_0 (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .s_axi_lite             (s_axi_lite),
        .m_axi_gmem             (m_axi_gmem),
        .fb_we                  (fb_we),
        .fb_addr                (fb_addr),
        .fb_rgb                 (fb_rgb)
    );

endmodule

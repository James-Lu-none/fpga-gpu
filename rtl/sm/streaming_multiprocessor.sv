`timescale 1ns / 1ps

// GPU Streaming Multiprocessor (SM)
// Receives dynamic Thread Block assignments from the GigaThread Engine (TBS).

module streaming_multiprocessor (
    input wire clk,
    input wire rst_n,

    // TBS Dispatch Interface (From GPC)
    input wire block_issue_valid,
    input wire [15:0] block_idx_x,
    input wire [15:0] block_idx_y,
    input wire [9:0] warps_per_block,
    
    output wire block_accepted,
    output wire [4:0] available_warp_slots,

    // Global Config & I-RAM Interface (From GPC)
    input wire [31:0] dma_src_addr,
    input wire [31:0] dma_dst_addr,
    input wire iram_we,
    input wire [11:0] iram_waddr,
    input wire [31:0] iram_wdata,

    // L1 to L2 Cache Interface
    output wire l1_req_valid,
    output wire [31:0] l1_req_addr,
    output wire [255:0]l1_req_wdata,
    output wire [31:0] l1_req_wstrb,
    output wire l1_req_we,
    input wire l1_req_ready,
    input wire l1_rsp_valid,
    input wire [255:0]l1_rsp_rdata,

    output wire fb_we,
    output wire [18:0] fb_addr,
    output wire [23:0] fb_rgb
);

    // 1. Thread Block Receiver (Local Scheduler)
    warp_alloc_if alloc();

    block_receiver u_block_rx (
        .clk (clk),
        .rst_n (rst_n),
        .block_issue_valid (block_issue_valid),
        .block_idx_x (block_idx_x),
        .block_idx_y (block_idx_y),
        .warps_per_block (warps_per_block),
        .block_accepted (block_accepted),
        
        .alloc (alloc)
    );
    
    assign available_warp_slots = alloc.available_slots;

    // 2. Sub-Core (Processing Block)
    wire sm_smem_we;
    wire [7:0] sm_smem_waddr;
    wire [63:0] sm_smem_wdata;
    wire [7:0] sm_smem_raddr;
    wire [63:0] smem_rdata = 64'd0; // Dummy for now since we removed local SMEM RAM dump

    processing_block u_sub_core (
        .clk (clk),
        .rst_n (rst_n),
        
        // I-RAM Loading
        .iram_we (iram_we),
        .iram_waddr (iram_waddr),
        .iram_wdata (iram_wdata),

        // Warp Allocation
        .alloc (alloc),
        
        .l1_req_valid (l1_req_valid),
        .l1_req_addr (l1_req_addr),
        .l1_req_wdata (l1_req_wdata),
        .l1_req_wstrb (l1_req_wstrb),
        .l1_req_we (l1_req_we),
        .l1_req_ready (l1_req_ready),
        .l1_rsp_valid (l1_rsp_valid),
        .l1_rsp_rdata (l1_rsp_rdata),

        // SMEM Interface
        .smem_we (sm_smem_we),
        .smem_waddr (sm_smem_waddr),
        .smem_wdata (sm_smem_wdata),
        .smem_raddr (sm_smem_raddr),
        .smem_rdata (smem_rdata),
        
        // Display
        .fb_we (fb_we),
        .fb_addr (fb_addr),
        .fb_rgb (fb_rgb)
    );

endmodule

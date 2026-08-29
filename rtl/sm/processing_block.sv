`timescale 1ns / 1ps
// Streaming Multiprocessor (SM) Compute Core - TRUE SIMT ARCHITECTURE
// Top-level module encapsulating the Warp Scheduler, Fetch/Decode, 
// Vector Register File, and Execution Pipeline.

module processing_block (
    input wire clk,
    input wire rst_n,

    // Instruction Load Interface (From Hardware Engine)
    input wire iram_we,
    input wire [11:0] iram_waddr,
    input wire [31:0] iram_wdata,

    // Warp Launch Interface (From Warp Scheduler)
    input wire alloc_valid,
    input wire [15:0] alloc_block_id,
    input wire [15:0] alloc_block_idx_x,
    input wire [15:0] alloc_block_idx_y,
    input wire [15:0] alloc_thread_id_start,
    input wire [31:0] alloc_active_mask,
    output wire alloc_ready,
    output wire [4:0] available_warp_slots,

    // L1 to L2 Cache Interface
    output wire l1_req_valid,
    output wire [31:0] l1_req_addr,
    output wire [255:0]l1_req_wdata,
    output wire [31:0] l1_req_wstrb,
    output wire l1_req_we,
    input wire l1_req_ready,
    input wire l1_rsp_valid,
    input wire [255:0]l1_rsp_rdata,

    // Legacy Memory & Render Interfaces (Tied off for now during refactor)
    output wire [7:0] smem_raddr,
    input wire [63:0] smem_rdata,
    output wire smem_we,
    output wire [7:0] smem_waddr,
    output wire [63:0] smem_wdata,
    output wire fb_we,
    output wire [18:0] fb_addr,
    output wire [23:0] fb_rgb
);

    // Tie-off Legacy Interfaces
    assign smem_raddr = 8'd0;
    assign smem_we = 1'b0;
    assign smem_waddr = 8'd0;
    assign smem_wdata = 64'd0;
    assign fb_we = 1'b0;
    assign fb_addr = 19'd0;
    assign fb_rgb = 24'd0;

    // Inter-module Interconnect Signals
    
    // Context -> Fetch
    wire issue_valid;
    wire [3:0] issue_warp_id;
    wire [11:0] issue_pc;
    wire [31:0] issue_active_mask;
    wire [15:0] issue_block_idx_x;
    wire [15:0] issue_block_idx_y;
    wire [15:0] issue_thread_id_start;

    // Fetch -> VRF
    wire decode_valid;
    wire [3:0] decode_warp_id;
    wire [11:0] decode_pc;
    wire [31:0] decode_active_mask;
    wire [15:0] decode_block_idx_x;
    wire [15:0] decode_block_idx_y;
    wire [15:0] decode_thread_id_start;
    wire [7:0] decode_opcode;
    wire [4:0] decode_rd;
    wire [4:0] decode_rs1;
    wire [4:0] decode_rs2;
    wire [15:0] decode_imm;
    wire decode_is_imm;

    // VRF -> Execute
    wire op_valid;
    wire [3:0] op_warp_id;
    wire [11:0] op_pc;
    wire [31:0] op_active_mask;
    wire [15:0] op_block_idx_x;
    wire [15:0] op_block_idx_y;
    wire [15:0] op_thread_id_start;
    wire [7:0] op_opcode;
    wire [4:0] op_rd;
    wire [31:0] op_imm;
    wire op_is_imm;
    wire [63:0] op_rs1_data;
    wire [63:0] op_rs2_data;

    // Execute -> VRF (Write-Back)
    wire alu_wb_valid;
    wire [3:0] alu_wb_warp_id;
    wire [4:0] alu_wb_rd;
    // 2 alus in alu now, so data is concatenated as {alu1_wb_data, alu2_wb_data}
    wire [63:0] alu_wb_data; 
    
    wire ctx_alu_wb_valid;
    wire [3:0] ctx_alu_wb_warp_id;
    wire [11:0] ctx_alu_wb_next_pc;
    wire ctx_alu_wb_is_done;
    wire [31:0] ctx_alu_wb_taken_mask;
    wire [31:0] ctx_alu_wb_not_taken_mask;
    wire ctx_alu_wb_is_divergent;
    wire ctx_alu_wb_is_sync;
    
    // LSU Write-Back
    wire lsu_wb_valid;
    wire [3:0] lsu_wb_warp_id;
    wire [11:0] lsu_wb_next_pc;
    wire [4:0] lsu_wb_rd;
    wire [63:0] lsu_wb_data;

    // Arbiter Outputs
    wire wb_valid;
    wire [3:0] wb_warp_id;
    wire [4:0] wb_rd;
    // 2 alus in alu now formated as {alu1_wb_data, alu2_wb_data}
    wire [63:0] wb_data;
    wire ctx_wb_valid;
    wire [3:0] ctx_wb_warp_id;
    wire [11:0] ctx_wb_next_pc;
    wire ctx_wb_is_done;
    wire [31:0] ctx_wb_taken_mask;
    wire [31:0] ctx_wb_not_taken_mask;
    wire ctx_wb_is_divergent;
    wire ctx_wb_is_sync;

    // Write-Back Arbiter (LSU has priority)
    assign wb_valid = lsu_wb_valid ? lsu_wb_valid : alu_wb_valid;
    assign wb_warp_id = lsu_wb_valid ? lsu_wb_warp_id : alu_wb_warp_id;
    assign wb_rd = lsu_wb_valid ? lsu_wb_rd : alu_wb_rd;
    assign wb_data = lsu_wb_valid ? lsu_wb_data : alu_wb_data;
    
    assign ctx_wb_valid = lsu_wb_valid ? lsu_wb_valid : ctx_alu_wb_valid;
    assign ctx_wb_warp_id = lsu_wb_valid ? lsu_wb_warp_id : ctx_alu_wb_warp_id;
    assign ctx_wb_next_pc = lsu_wb_valid ? lsu_wb_next_pc : ctx_alu_wb_next_pc;
    assign ctx_wb_is_done = lsu_wb_valid ? 1'b0 : ctx_alu_wb_is_done;
    assign ctx_wb_taken_mask = lsu_wb_valid ? 32'd0 : ctx_alu_wb_taken_mask;
    assign ctx_wb_not_taken_mask = lsu_wb_valid ? 32'd0 : ctx_alu_wb_not_taken_mask;
    assign ctx_wb_is_divergent = lsu_wb_valid ? 1'b0 : ctx_alu_wb_is_divergent;
    assign ctx_wb_is_sync = lsu_wb_valid ? 1'b0 : ctx_alu_wb_is_sync;

    // 1. Warp Context & Dynamic Scheduler
    warp_context #(
        .MAX_WARPS(16)
    ) u_warp_context (
        .clk (clk),
        .rst_n (rst_n),
        .alloc_ready (alloc_ready),
        .available_warp_slots(available_warp_slots),
        .alloc_valid (alloc_valid),
        .alloc_block_id (alloc_block_id),
        .alloc_block_idx_x (alloc_block_idx_x),
        .alloc_block_idx_y (alloc_block_idx_y),
        .alloc_thread_id_start (alloc_thread_id_start),
        .alloc_active_mask (alloc_active_mask),
        .issue_valid (issue_valid),
        .issue_warp_id (issue_warp_id),
        .issue_pc (issue_pc),
        .issue_active_mask (issue_active_mask),
        .issue_block_idx_x (issue_block_idx_x),
        .issue_block_idx_y (issue_block_idx_y),
        .issue_thread_id_start (issue_thread_id_start),
        .wb_valid (ctx_wb_valid),
        .wb_warp_id (ctx_wb_warp_id),
        .wb_next_pc (ctx_wb_next_pc),
        .wb_is_done (ctx_wb_is_done),
        .wb_is_divergent (ctx_wb_is_divergent),
        .wb_taken_mask (ctx_wb_taken_mask),
        .wb_not_taken_mask (ctx_wb_not_taken_mask),
        .wb_is_sync (ctx_wb_is_sync)
    );

    // 2. Instruction Fetch & Decode
    fetch_decode #(
        .IRAM_DEPTH(1024)
    ) u_fetch_decode (
        .clk (clk),
        .rst_n (rst_n),
        .iram_we (iram_we),
        .iram_waddr (iram_waddr),
        .iram_wdata (iram_wdata),
        .issue_valid (issue_valid),
        .issue_warp_id (issue_warp_id),
        .issue_pc (issue_pc),
        .issue_active_mask (issue_active_mask),
        .issue_block_idx_x (issue_block_idx_x),
        .issue_block_idx_y (issue_block_idx_y),
        .issue_thread_id_start (issue_thread_id_start),
        .decode_valid (decode_valid),
        .decode_warp_id (decode_warp_id),
        .decode_pc (decode_pc),
        .decode_active_mask (decode_active_mask),
        .decode_block_idx_x (decode_block_idx_x),
        .decode_block_idx_y (decode_block_idx_y),
        .decode_thread_id_start (decode_thread_id_start),
        .decode_opcode (decode_opcode),
        .decode_rd (decode_rd),
        .decode_rs1 (decode_rs1),
        .decode_rs2 (decode_rs2),
        .decode_imm (decode_imm),
        .decode_is_imm (decode_is_imm)
    );

    // 3. Vector Register File (VRF)
    vector_regfile #(
        .MAX_WARPS(16),
        .NUM_REGS(32),
        .DATA_W(64)
    ) u_vector_regfile (
        .clk (clk),
        .rst_n (rst_n),
        .decode_valid (decode_valid),
        .decode_warp_id (decode_warp_id),
        .decode_pc (decode_pc),
        .decode_active_mask (decode_active_mask),
        .decode_block_idx_x (decode_block_idx_x),
        .decode_block_idx_y (decode_block_idx_y),
        .decode_thread_id_start (decode_thread_id_start),
        .decode_opcode (decode_opcode),
        .decode_rd (decode_rd),
        .decode_rs1 (decode_rs1),
        .decode_rs2 (decode_rs2),
        .decode_imm (decode_imm),
        .decode_is_imm (decode_is_imm),
        .op_valid (op_valid),
        .op_warp_id (op_warp_id),
        .op_pc (op_pc),
        .op_active_mask (op_active_mask),
        .op_block_idx_x (op_block_idx_x),
        .op_block_idx_y (op_block_idx_y),
        .op_thread_id_start (op_thread_id_start),
        .op_opcode (op_opcode),
        .op_rd (op_rd),
        .op_imm (op_imm),
        .op_is_imm (op_is_imm),
        .op_rs1_data (op_rs1_data),
        .op_rs2_data (op_rs2_data),
        .wb_valid (wb_valid),
        .wb_warp_id (wb_warp_id),
        .wb_rd (wb_rd),
        .wb_data (wb_data)
    );

    // 4. ALU & PC (Execution & Control)
    wire alu_updates_nzp;
    wire [2:0] next_nzp0;
    wire [2:0] next_nzp1;
    wire is_exit;
    wire is_branch;
    wire is_sync;

    alu #(
        .DATA_W(64)
    ) u_alu (
        .clk (clk),
        .rst_n (rst_n),
        .op_valid (op_valid),
        .op_warp_id (op_warp_id),
        .op_block_idx_x (op_block_idx_x),
        .op_block_idx_y (op_block_idx_y),
        .op_thread_id_start (op_thread_id_start),
        .op_opcode (op_opcode),
        .op_rd (op_rd),
        .op_imm (op_imm),
        .op_is_imm (op_is_imm),
        .op_rs1_data (op_rs1_data),
        .op_rs2_data (op_rs2_data),
        .wb_valid (alu_wb_valid),
        .wb_warp_id (alu_wb_warp_id),
        .wb_rd (alu_wb_rd),
        .wb_data (alu_wb_data),
        .alu_updates_nzp (alu_updates_nzp),
        .next_nzp0 (next_nzp0),
        .next_nzp1 (next_nzp1),
        .is_exit (is_exit),
        .is_branch (is_branch),
        .is_sync (is_sync)
    );

    pc #(
        .MAX_WARPS(16)
    ) u_pc (
        .clk (clk),
        .rst_n (rst_n),
        .op_valid (op_valid),
        .op_warp_id (op_warp_id),
        .op_pc (op_pc),
        .op_active_mask (op_active_mask),
        .op_rd (op_rd),
        .op_imm (op_imm),
        .alu_updates_nzp (alu_updates_nzp),
        .next_nzp0 (next_nzp0),
        .next_nzp1 (next_nzp1),
        .is_exit (is_exit),
        .is_branch (is_branch),
        .is_sync (is_sync),
        .ctx_wb_valid (ctx_alu_wb_valid),
        .ctx_wb_warp_id (ctx_alu_wb_warp_id),
        .ctx_wb_next_pc (ctx_alu_wb_next_pc),
        .ctx_wb_is_done (ctx_alu_wb_is_done),
        .ctx_wb_taken_mask (ctx_alu_wb_taken_mask),
        .ctx_wb_not_taken_mask (ctx_alu_wb_not_taken_mask),
        .ctx_wb_is_divergent (ctx_alu_wb_is_divergent),
        .ctx_wb_is_sync (ctx_alu_wb_is_sync)
    );

    // 5. Load/Store Unit (LSU) & L1 Cache
    wire l1_req_valid_int;
    wire [31:0] l1_req_addr_int;
    wire [63:0] l1_req_wdata_int;
    wire l1_req_we_int;
    wire l1_req_ready_int;
    
    wire l1_rsp_valid_int;
    wire [63:0] l1_rsp_rdata_int;
    wire lsu_ready;

    lsu u_lsu (
        .clk (clk),
        .rst_n (rst_n),
        .op_valid (op_valid),
        .op_warp_id (op_warp_id),
        .op_pc (op_pc),
        .op_opcode (op_opcode),
        .op_rd (op_rd),
        .op_rs1_data (op_rs1_data),
        .op_rs2_data (op_rs2_data),
        .lsu_ready (lsu_ready),
        
        .l1_req_valid (l1_req_valid_int),
        .l1_req_addr (l1_req_addr_int),
        .l1_req_wdata (l1_req_wdata_int),
        .l1_req_we (l1_req_we_int),
        .l1_req_ready (l1_req_ready_int),
        .l1_rsp_valid (l1_rsp_valid_int),
        .l1_rsp_rdata (l1_rsp_rdata_int),
        
        .lsu_wb_valid (lsu_wb_valid),
        .lsu_wb_warp_id (lsu_wb_warp_id),
        .lsu_wb_next_pc (lsu_wb_next_pc),
        .lsu_wb_rd (lsu_wb_rd),
        .lsu_wb_data (lsu_wb_data)
    );

    l1_cache u_l1_cache (
        .clk (clk),
        .rst_n (rst_n),
        
        .req_valid (l1_req_valid_int),
        .req_addr (l1_req_addr_int),
        .req_wdata (l1_req_wdata_int),
        .req_we (l1_req_we_int),
        .req_ready (l1_req_ready_int),
        .rsp_valid (l1_rsp_valid_int),
        .rsp_rdata (l1_rsp_rdata_int),
        
        .l2_req_valid (l1_req_valid),
        .l2_req_addr (l1_req_addr),
        .l2_req_wdata (l1_req_wdata),
        .l2_req_wstrb (l1_req_wstrb),
        .l2_req_we (l1_req_we),
        .l2_req_ready (l1_req_ready),
        .l2_rsp_valid (l1_rsp_valid),
        .l2_rsp_rdata (l1_rsp_rdata)
    );

endmodule
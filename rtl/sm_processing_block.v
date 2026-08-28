`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////--
// Streaming Multiprocessor (SM) Compute Core - TRUE SIMT ARCHITECTURE
// Top-level module encapsulating the Warp Scheduler, Fetch/Decode, 
// Vector Register File, and Execution Pipeline.
////////////////////////////////////////////////////////////////////////////////--

module sm_processing_block (
    input  wire        clk,
    input  wire        rst_n,

    // -------------------------------------------------------------------------
    // Instruction Load Interface (From Hardware Engine)
    // -------------------------------------------------------------------------
    input  wire        iram_we,
    input  wire [11:0] iram_waddr,
    input  wire [31:0] iram_wdata,

    // -------------------------------------------------------------------------
    // Warp Launch Interface (From Warp Scheduler)
    // -------------------------------------------------------------------------
    input  wire        alloc_valid,
    input  wire [15:0] alloc_block_id,
    input  wire [31:0] alloc_active_mask,
    output wire        alloc_ready,

    // -------------------------------------------------------------------------
    // Legacy Memory & Render Interfaces (Tied off for now during refactor)
    // -------------------------------------------------------------------------
    output wire [7:0]  smem_raddr,
    input  wire [63:0] smem_rdata,
    output wire        smem_we,
    output wire [7:0]  smem_waddr,
    output wire [63:0] smem_wdata,
    output wire        fb_we,
    output wire [18:0] fb_addr,
    output wire [23:0] fb_rgb
);

    // Tie-off Legacy Interfaces
    assign smem_raddr = 8'd0;
    assign smem_we    = 1'b0;
    assign smem_waddr = 8'd0;
    assign smem_wdata = 64'd0;
    assign fb_we      = 1'b0;
    assign fb_addr    = 19'd0;
    assign fb_rgb     = 24'd0;

    // =========================================================================
    // Inter-module Interconnect Signals
    // =========================================================================
    
    // Context -> Fetch
    wire        issue_valid;
    wire [3:0]  issue_warp_id;
    wire [11:0] issue_pc;
    wire [31:0] issue_active_mask;

    // Fetch -> VRF
    wire        decode_valid;
    wire [3:0]  decode_warp_id;
    wire [11:0] decode_pc;
    wire [31:0] decode_active_mask;
    wire [7:0]  decode_opcode;
    wire [4:0]  decode_rd;
    wire [4:0]  decode_rs1;
    wire [4:0]  decode_rs2;
    wire [15:0] decode_imm;
    wire        decode_is_imm;

    // VRF -> Execute
    wire        op_valid;
    wire [3:0]  op_warp_id;
    wire [11:0] op_pc;
    wire [31:0] op_active_mask;
    wire [7:0]  op_opcode;
    wire [4:0]  op_rd;
    wire [63:0] op_rs1_data;
    wire [63:0] op_rs2_data;

    // Execute -> VRF (Write-Back)
    wire        wb_valid;
    wire [3:0]  wb_warp_id;
    wire [4:0]  wb_rd;
    wire [63:0] wb_data;

    // Execute -> Context (State Update)
    wire        ctx_wb_valid;
    wire [3:0]  ctx_wb_warp_id;
    wire [11:0] ctx_wb_next_pc;
    wire        ctx_wb_is_done;

    // =========================================================================
    // 1. Warp Context & Dynamic Scheduler
    // =========================================================================
    sm_warp_context #(
        .MAX_WARPS(16)
    ) u_warp_context (
        .clk                (clk),
        .rst_n              (rst_n),
        .alloc_ready        (alloc_ready),
        .alloc_valid        (alloc_valid),
        .alloc_block_id     (alloc_block_id),
        .alloc_active_mask  (alloc_active_mask),
        .issue_valid        (issue_valid),
        .issue_warp_id      (issue_warp_id),
        .issue_pc           (issue_pc),
        .issue_active_mask  (issue_active_mask),
        .wb_valid           (ctx_wb_valid),
        .wb_warp_id         (ctx_wb_warp_id),
        .wb_next_pc         (ctx_wb_next_pc),
        .wb_is_done         (ctx_wb_is_done)
    );

    // =========================================================================
    // 2. Instruction Fetch & Decode
    // =========================================================================
    sm_fetch_decode #(
        .IRAM_DEPTH(1024)
    ) u_fetch_decode (
        .clk                (clk),
        .rst_n              (rst_n),
        .iram_we            (iram_we),
        .iram_waddr         (iram_waddr),
        .iram_wdata         (iram_wdata),
        .issue_valid        (issue_valid),
        .issue_warp_id      (issue_warp_id),
        .issue_pc           (issue_pc),
        .issue_active_mask  (issue_active_mask),
        .decode_valid       (decode_valid),
        .decode_warp_id     (decode_warp_id),
        .decode_pc          (decode_pc),
        .decode_active_mask (decode_active_mask),
        .decode_opcode      (decode_opcode),
        .decode_rd          (decode_rd),
        .decode_rs1         (decode_rs1),
        .decode_rs2         (decode_rs2),
        .decode_imm         (decode_imm),
        .decode_is_imm      (decode_is_imm)
    );

    // =========================================================================
    // 3. Vector Register File (VRF)
    // =========================================================================
    sm_vector_regfile #(
        .MAX_WARPS(16),
        .NUM_REGS(32),
        .DATA_W(64)
    ) u_vector_regfile (
        .clk                (clk),
        .rst_n              (rst_n),
        .decode_valid       (decode_valid),
        .decode_warp_id     (decode_warp_id),
        .decode_pc          (decode_pc),
        .decode_active_mask (decode_active_mask),
        .decode_opcode      (decode_opcode),
        .decode_rd          (decode_rd),
        .decode_rs1         (decode_rs1),
        .decode_rs2         (decode_rs2),
        .decode_imm         (decode_imm),
        .decode_is_imm      (decode_is_imm),
        .op_valid           (op_valid),
        .op_warp_id         (op_warp_id),
        .op_pc              (op_pc),
        .op_active_mask     (op_active_mask),
        .op_opcode          (op_opcode),
        .op_rd              (op_rd),
        .op_rs1_data        (op_rs1_data),
        .op_rs2_data        (op_rs2_data),
        .wb_valid           (wb_valid),
        .wb_warp_id         (wb_warp_id),
        .wb_rd              (wb_rd),
        .wb_data            (wb_data)
    );

    // =========================================================================
    // 4. CUDA Cores (Streaming Processors array)
    // =========================================================================
    sm_cuda_cores #(
        .DATA_W(64)
    ) u_cuda_cores (
        .clk                (clk),
        .rst_n              (rst_n),
        .op_valid           (op_valid),
        .op_warp_id         (op_warp_id),
        .op_pc              (op_pc),
        .op_active_mask     (op_active_mask),
        .op_opcode          (op_opcode),
        .op_rd              (op_rd),
        .op_rs1_data        (op_rs1_data),
        .op_rs2_data        (op_rs2_data),
        .wb_valid           (wb_valid),
        .wb_warp_id         (wb_warp_id),
        .wb_rd              (wb_rd),
        .wb_data            (wb_data),
        .ctx_wb_valid       (ctx_wb_valid),
        .ctx_wb_warp_id     (ctx_wb_warp_id),
        .ctx_wb_next_pc     (ctx_wb_next_pc),
        .ctx_wb_is_done     (ctx_wb_is_done)
    );

endmodule
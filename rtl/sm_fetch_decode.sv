`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////--
// Streaming Multiprocessor (SM) - Instruction Fetch & Decode
// 1. Stores Kernel Code in a local Instruction RAM (I-RAM).
// 2. Receives issued PC from Warp Scheduler, fetches instruction (1 cycle latency).
// 3. Decodes instruction and passes control signals to Execution Pipeline.
////////////////////////////////////////////////////////////////////////////////--

module sm_fetch_decode #(
    parameter IRAM_DEPTH = 1024 // 1024 instructions = 4KB I-RAM
)(
    input  wire        clk,
    input  wire        rst_n,

    // -------------------------------------------------------------------------
    // I-RAM Host Load Interface (From Hardware Engine / DMA)
    // -------------------------------------------------------------------------
    input  wire        iram_we,
    input  wire [11:0] iram_waddr,
    input  wire [31:0] iram_wdata,

    // -------------------------------------------------------------------------
    // Issue Interface (From sm_warp_context)
    // -------------------------------------------------------------------------
    input  wire        issue_valid,
    input  wire [3:0]  issue_warp_id,
    input  wire [11:0] issue_pc,
    input  wire [31:0] issue_active_mask,

    // -------------------------------------------------------------------------
    // Decode Interface (To sm_vector_regfile / sm_execution_pipe)
    // -------------------------------------------------------------------------
    output reg         decode_valid,
    output reg  [3:0]  decode_warp_id,
    output reg  [11:0] decode_pc,
    output reg  [31:0] decode_active_mask,
    
    // Instruction Fields
    output reg  [7:0]  decode_opcode,
    output reg  [4:0]  decode_rd,
    output reg  [4:0]  decode_rs1,
    output reg  [4:0]  decode_rs2,
    output reg  [15:0] decode_imm,      // Extended Immediate
    output reg         decode_is_imm    // Flag: 1 if instruction uses immediate instead of rs2
);

    // =========================================================================
    // 1. Instruction RAM (I-RAM)
    // =========================================================================
    // Xilinx BRAM Inference
    (* ram_style = "block" *) reg [31:0] iram [0:IRAM_DEPTH-1];

    reg [31:0] fetched_instr;

    always @(posedge clk) begin
        // Port A: Host Write
        if (iram_we) begin
            iram[iram_waddr] <= iram_wdata;
        end
        // Port B: Fetch Read (Implicit 1-cycle latency)
        fetched_instr <= iram[issue_pc];
    end

    // =========================================================================
    // 2. Fetch Pipeline Register
    // To align the control signals (warp_id, pc, mask) with the fetched instruction 
    // from BRAM, we need a 1-cycle delay pipeline.
    // =========================================================================
    reg        issue_valid_q;
    reg [3:0]  issue_warp_id_q;
    reg [11:0] issue_pc_q;
    reg [31:0] issue_active_mask_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_valid_q       <= 1'b0;
            issue_warp_id_q     <= 4'd0;
            issue_pc_q          <= 12'd0;
            issue_active_mask_q <= 32'd0;
        end else begin
            issue_valid_q       <= issue_valid;
            issue_warp_id_q     <= issue_warp_id;
            issue_pc_q          <= issue_pc;
            issue_active_mask_q <= issue_active_mask;
        end
    end

    // =========================================================================
    // 3. Instruction Decode Stage
    // Formats (Simplified 32-bit Custom GPU ISA):
    // R-Type (Register): [31:24] Opcode | [23:19] Rd | [18:14] Rs1 | [13:9] Rs2 | [8:0] Unused
    // I-Type (Immediate):[31:24] Opcode | [23:19] Rd | [18:14] Rs1 | [13:0] Immediate (14-bit)
    // =========================================================================
    
    wire [7:0] op   = fetched_instr[31:24];
    wire [4:0] rd   = fetched_instr[23:19];
    wire [4:0] rs1  = fetched_instr[18:14];
    wire [4:0] rs2  = fetched_instr[13:9];
    wire [13:0] imm = fetched_instr[13:0]; // 14-bit immediate
    
    // Quick Decode Logic for Immediate Flag
    // E.g., Opcode bit 7 could indicate an immediate instruction, 
    // or we can decode specific opcodes. For now, let's assume opcodes >= 8'h80 are Immediate.
    wire is_imm = (op >= 8'h80); 

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decode_valid       <= 1'b0;
            decode_warp_id     <= 4'd0;
            decode_pc          <= 12'd0;
            decode_active_mask <= 32'd0;
            decode_opcode      <= 8'd0;
            decode_rd          <= 5'd0;
            decode_rs1         <= 5'd0;
            decode_rs2         <= 5'd0;
            decode_imm         <= 16'd0;
            decode_is_imm      <= 1'b0;
        end else begin
            decode_valid <= issue_valid_q;
            
            if (issue_valid_q) begin
                decode_warp_id     <= issue_warp_id_q;
                decode_pc          <= issue_pc_q;
                decode_active_mask <= issue_active_mask_q;
                
                // Extract fields
                decode_opcode      <= op;
                decode_rd          <= rd;
                decode_rs1         <= rs1;
                decode_rs2         <= rs2;
                decode_is_imm      <= is_imm;
                
                // Sign-extend or zero-extend immediate (assuming zero-extend for simple GPU logic)
                decode_imm         <= {2'b00, imm}; 
            end
        end
    end

endmodule

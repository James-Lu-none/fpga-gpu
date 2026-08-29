`timescale 1ns / 1ps
// Streaming Multiprocessor (SM) - Vector Register File (VRF)
// Manages the registers for all resident warps.
// Uses duplicated BRAMs to provide 2 Read Ports and 1 Write Port.

module vector_regfile #(
    parameter MAX_WARPS = 16,
    parameter NUM_REGS = 32,
    parameter DATA_W = 64 // 2 lanes x 32-bit for now
)(
    input wire clk,
    input wire rst_n,

    // Decode Interface (From fetch_decode)
    input wire decode_valid,
    input wire [3:0] decode_warp_id,
    input wire [11:0] decode_pc,
    input wire [31:0] decode_active_mask,
    input wire [7:0] decode_opcode,
    input wire [4:0] decode_rd,
    input wire [4:0] decode_rs1,
    input wire [4:0] decode_rs2,
    input wire [31:0] decode_imm,
    input wire decode_is_imm,

    // Operand Interface (To sm_execution_pipe)
    output reg op_valid,
    output reg [3:0] op_warp_id,
    output reg [11:0] op_pc,
    output reg [31:0] op_active_mask,
    output reg [7:0] op_opcode,
    output reg [4:0] op_rd,
    output reg [31:0] op_imm,
    output reg op_is_imm,
    output reg [63:0] op_rs1_data, // Vector Data (64-bit)
    output reg [63:0] op_rs2_data, // Vector Data (64-bit)
    
    // Write-Back Interface (From sm_execution_pipe)
    input wire wb_valid,
    input wire [3:0] wb_warp_id,
    input wire [4:0] wb_rd,
    input wire [63:0] wb_data,
    input wire [31:0] wb_mask // Per-lane write mask (Optional for pure register files)
);

    // Total registers = 16 warps * 32 regs = 512 entries
    localparam RAM_DEPTH = MAX_WARPS * NUM_REGS;

    // To get 2R1W from FPGA BRAMs, we duplicate the memory.
    (* ram_style = "block" *) reg [DATA_W-1:0] ram_rs1 [0:RAM_DEPTH-1];
    (* ram_style = "block" *) reg [DATA_W-1:0] ram_rs2 [0:RAM_DEPTH-1];

    wire [8:0] addr_rs1 = {decode_warp_id, decode_rs1};
    wire [8:0] addr_rs2 = {decode_warp_id, decode_rs2};
    wire [8:0] addr_wb = {wb_warp_id, wb_rd};

    reg [DATA_W-1:0] rs1_data_read;
    reg [DATA_W-1:0] rs2_data_read;

    // Pipeline registers for control signals
    reg decode_valid_q;
    reg [3:0] decode_warp_id_q;
    reg [11:0] decode_pc_q;
    reg [31:0] decode_active_mask_q;
    reg [7:0] decode_opcode_q;
    reg [4:0] decode_rd_q;
    reg [31:0] decode_imm_q;
    reg decode_is_imm_q;

    // Synchronous Read and Write
    always @(posedge clk) begin
        // Write Port (Write-back from ALU)
        // If the execution pipe provides per-lane masking, we could use byte-enables.
        // For simplicity, we assume the ALU merges the original data if masked.
        if (wb_valid && (wb_rd != 5'd0)) begin // Assuming R0 is read-only zero or normal reg
            ram_rs1[addr_wb] <= wb_data;
            ram_rs2[addr_wb] <= wb_data;
        end

        // Read Ports (1 cycle latency)
        rs1_data_read <= ram_rs1[addr_rs1];
        rs2_data_read <= ram_rs2[addr_rs2];
    end

    // Delay Control Signals to match BRAM read latency
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decode_valid_q <= 1'b0;
            decode_warp_id_q <= 4'd0;
            decode_pc_q <= 12'd0;
            decode_active_mask_q <= 32'd0;
            decode_opcode_q <= 8'd0;
            decode_rd_q <= 5'd0;
            decode_imm_q <= 32'd0;
            decode_is_imm_q <= 1'b0;
        end else begin
            decode_valid_q <= decode_valid;
            decode_warp_id_q <= decode_warp_id;
            decode_pc_q <= decode_pc;
            decode_active_mask_q <= decode_active_mask;
            decode_opcode_q <= decode_opcode;
            decode_rd_q <= decode_rd;
            decode_imm_q <= decode_imm;
            decode_is_imm_q <= decode_is_imm;
        end
    end

    // Operand Formatting (Output to ALU)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_valid <= 1'b0;
            op_warp_id <= 4'd0;
            op_pc <= 12'd0;
            op_active_mask <= 32'd0;
            op_opcode <= 8'd0;
            op_rd <= 5'd0;
            op_imm <= 32'd0;
            op_is_imm <= 1'b0;
            op_rs1_data <= 64'd0;
            op_rs2_data <= 64'd0;
        end else begin
            op_valid <= decode_valid_q;
            
            if (decode_valid_q) begin
                op_warp_id <= decode_warp_id_q;
                op_pc <= decode_pc_q;
                op_active_mask <= decode_active_mask_q;
                op_opcode <= decode_opcode_q;
                op_rd <= decode_rd_q;
                op_imm <= decode_imm_q;
                op_is_imm <= decode_is_imm_q;
                
                op_rs1_data <= rs1_data_read;
                op_rs2_data <= rs2_data_read; // Keep rs2 vector clean; ALU multiplexes imm
            end
        end
    end

endmodule

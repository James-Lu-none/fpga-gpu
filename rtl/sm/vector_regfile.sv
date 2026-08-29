`timescale 1ns / 1ps
// Streaming Multiprocessor (SM) - Vector Register File (VRF)
//
// Unlike a scalar CPU register that holds a single value (e.g. 32-bit), a GPU 
// register holds a "vector" of values, one for each thread in the warp. 
// For example, R1 here contains [Thread1's R1, Thread0's R1].
//
// rs1: Register Source 1 (The first operand to read, e.g., R2 in ADD R1, R2, R3)
// rs2: Register Source 2 (The second operand to read, e.g., R3 in ADD R1, R2, R3)
// rd: Register Destination (The target register to write, e.g., R1 in ADD R1, R2, R3)
// wb: Write-Back (The action of writing the ALU/LSU computed result back to rd)
//
// Current supported instruction needs to read two sources (rs1, rs2) at most and write one 
// result (rd) simultaneously. However, FPGA BRAMs typically only have 2 ports total 
// (e.g., 1 read + 1 write, or 2 reads). 
// To solve this, we use the "Memory Duplication" technique: we instantiate two 
// identical BRAMs (`ram_rs1` and `ram_rs2`).
// - The 2 Reads: We use port A of `ram_rs1` to read `rs1`, and port A of `ram_rs2` to read `rs2`.
// - The 1 Write: We use port B of both `ram_rs1` and `ram_rs2` to write the `wb_data` 
//   simultaneously, ensuring both BRAMs always hold the exact same identical data.
//
// # All 32 registers for each thread in each warp are uninitialized (or zero) before execution.
// But in order to let the alu (thread) know its ID, the Hardware will preload the thread's ID 
// (e.g., threadIdx.x and blockIdx.x) into register R1 and R2 before the fetch_decode
// receives the first instruction.
//
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
    // ram_rs1 is exclusively used to read the rs1 operand.
    // ram_rs2 is exclusively used to read the rs2 operand.
    // Both are updated identically during a write-back.
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
        // Write Port (Write-back from ALU/LSU)
        // This handles the "1 Write". When the execution pipeline finishes a computation,
        // it provides the result (wb_data) and the destination register (wb_rd).
        // We write this data into BOTH ram_rs1 and ram_rs2 at the same time to keep them synced.
        if (wb_valid && (wb_rd != 5'd0)) begin // Assuming R0 is read-only zero or normal reg
            // alus will write back in format {alu1_out, alu0_out}
            ram_rs1[addr_wb] <= wb_data;
            ram_rs2[addr_wb] <= wb_data;
        end

        // Read Ports (1 cycle latency)
        // This handles the "2 Reads". We supply the addresses (addr_rs1, addr_rs2) to 
        // the BRAMs, and they will output the data (rs1_data_read, rs2_data_read) on the next cycle.
        rs1_data_read <= ram_rs1[addr_rs1];
        rs2_data_read <= ram_rs2[addr_rs2];
    end

    // Pipeline Alignment:
    // Since BRAM on FPGA has a 1-cycle read latency, we must delay all control 
    // signals (opcode, pc, etc.) by 1 cycle using D-Flip-Flops (_q). 
    // This ensures that when the BRAM outputs the register data on the next cycle, 
    // the control signals arrive at the ALU at the exact same time.
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

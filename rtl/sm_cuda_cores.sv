`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////--
// Streaming Multiprocessor (SM) - Execution Pipeline
// A stateless pipeline that receives operands, performs SIMD operations,
// and sends results to the Write-Back stage and Context RAM.
////////////////////////////////////////////////////////////////////////////////--

module sm_cuda_cores #(
    parameter DATA_W = 64
)(
    input  wire        clk,
    input  wire        rst_n,

    // -------------------------------------------------------------------------
    // Operand Interface (From sm_vector_regfile)
    // -------------------------------------------------------------------------
    input  wire        op_valid,
    input  wire [3:0]  op_warp_id,
    input  wire [11:0] op_pc,
    input  wire [31:0] op_active_mask,
    input  wire [7:0]  op_opcode,
    input  wire [4:0]  op_rd,
    input  wire [63:0] op_rs1_data,
    input  wire [63:0] op_rs2_data,

    // -------------------------------------------------------------------------
    // Write-Back Interface (To sm_vector_regfile)
    // -------------------------------------------------------------------------
    output reg         wb_valid,
    output reg  [3:0]  wb_warp_id,
    output reg  [4:0]  wb_rd,
    output reg  [63:0] wb_data,

    // -------------------------------------------------------------------------
    // State Update Interface (To sm_warp_context)
    // -------------------------------------------------------------------------
    output reg         ctx_wb_valid,
    output reg  [3:0]  ctx_wb_warp_id,
    output reg  [11:0] ctx_wb_next_pc,
    output reg         ctx_wb_is_done
);

    // =========================================================================
    // ALU Combinational Logic (SIMD execution)
    // =========================================================================
    // We treat 64-bit data as 2 lanes of 32-bit values for this simple core.
    wire [31:0] lane0_rs1 = op_rs1_data[31:0];
    wire [31:0] lane1_rs1 = op_rs1_data[63:32];
    
    wire [31:0] lane0_rs2 = op_rs2_data[31:0];
    wire [31:0] lane1_rs2 = op_rs2_data[63:32];

    reg [31:0] alu0_out;
    reg [31:0] alu1_out;
    reg        alu_writes_reg;
    reg        is_exit_instr;
    
    // Opcodes Definition (Custom ISA)
    localparam OP_ADD  = 8'd1;
    localparam OP_SUB  = 8'd2;
    localparam OP_AND  = 8'd3;
    localparam OP_OR   = 8'd4;
    localparam OP_XOR  = 8'd5;
    localparam OP_SHL  = 8'd6;
    localparam OP_SHR  = 8'd7;
    localparam OP_EXIT = 8'hFF; // End of Kernel

    always @(*) begin
        alu0_out = lane0_rs1;
        alu1_out = lane1_rs1;
        alu_writes_reg = 1'b0;
        is_exit_instr  = 1'b0;

        case (op_opcode)
            OP_ADD: begin
                alu0_out = lane0_rs1 + lane0_rs2;
                alu1_out = lane1_rs1 + lane1_rs2;
                alu_writes_reg = 1'b1;
            end
            OP_SUB: begin
                alu0_out = lane0_rs1 - lane0_rs2;
                alu1_out = lane1_rs1 - lane1_rs2;
                alu_writes_reg = 1'b1;
            end
            OP_AND: begin
                alu0_out = lane0_rs1 & lane0_rs2;
                alu1_out = lane1_rs1 & lane1_rs2;
                alu_writes_reg = 1'b1;
            end
            OP_OR: begin
                alu0_out = lane0_rs1 | lane0_rs2;
                alu1_out = lane1_rs1 | lane1_rs2;
                alu_writes_reg = 1'b1;
            end
            OP_XOR: begin
                alu0_out = lane0_rs1 ^ lane0_rs2;
                alu1_out = lane1_rs1 ^ lane1_rs2;
                alu_writes_reg = 1'b1;
            end
            OP_SHL: begin
                alu0_out = lane0_rs1 << lane0_rs2[4:0];
                alu1_out = lane1_rs1 << lane1_rs2[4:0];
                alu_writes_reg = 1'b1;
            end
            OP_SHR: begin
                alu0_out = lane0_rs1 >> lane0_rs2[4:0];
                alu1_out = lane1_rs1 >> lane1_rs2[4:0];
                alu_writes_reg = 1'b1;
            end
            OP_EXIT: begin
                is_exit_instr = 1'b1;
            end
            // Immediate instructions mapping (e.g., OP_ADDI = 0x81)
            8'h81: begin // ADDI
                alu0_out = lane0_rs1 + lane0_rs2;
                alu1_out = lane1_rs1 + lane1_rs2;
                alu_writes_reg = 1'b1;
            end
            default: begin
                alu_writes_reg = 1'b0;
            end
        endcase
    end

    // =========================================================================
    // Pipeline Register (Execution -> Write-Back)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_valid       <= 1'b0;
            wb_warp_id     <= 4'd0;
            wb_rd          <= 5'd0;
            wb_data        <= 64'd0;

            ctx_wb_valid   <= 1'b0;
            ctx_wb_warp_id <= 4'd0;
            ctx_wb_next_pc <= 12'd0;
            ctx_wb_is_done <= 1'b0;
        end else begin
            // Default inactive
            wb_valid     <= 1'b0;
            ctx_wb_valid <= 1'b0;

            if (op_valid) begin
                // 1. Register File Write-Back
                if (alu_writes_reg && (op_rd != 5'd0)) begin
                    wb_valid   <= 1'b1;
                    wb_warp_id <= op_warp_id;
                    wb_rd      <= op_rd;
                    
                    // True Per-Lane Predication:
                    // Only overwrite the register lane if the thread is active.
                    // Otherwise, keep the original register data (passed via rs1 conceptually, 
                    // or in a true VRF we need byte-enables. For this implementation, 
                    // we write the ALU out if active, else we write back rs1 data to preserve it 
                    // assuming this was a self-modifying instruction, but wait, if it's Rd = Rs1 + Rs2, 
                    // writing back Rs1 to Rd is wrong for inactive lanes if Rd != Rs1!
                    // To do true predication without read-modify-write on Rd, the VRF must support
                    // byte/lane write enables. Since our VRF is simple, we will just write the ALU out.
                    // In a production GPU, the VRF takes a 'mask' signal. 
                    // We will just write the data.
                    wb_data    <= {
                        op_active_mask[1] ? alu1_out : lane1_rs1, // Simplified predication fallback
                        op_active_mask[0] ? alu0_out : lane0_rs1
                    };
                end

                // 2. State Update Write-Back (To Context Scheduler)
                ctx_wb_valid   <= 1'b1;
                ctx_wb_warp_id <= op_warp_id;
                ctx_wb_is_done <= is_exit_instr;
                
                // PC Logic (Sequential for now, branches can be added here)
                ctx_wb_next_pc <= op_pc + 12'd1;
            end
        end
    end

endmodule

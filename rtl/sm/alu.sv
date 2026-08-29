`timescale 1ns / 1ps
// ALU (Arithmetic Logic Unit)
// 
// ALU is instantiated in processing_block.sv
// currently it only supports integer arithmetic (ADD, SUB, MUL) 
// and logical operations for all active threads in a warp. 
// It processes multiple lanes in parallel
//

module alu #(
    parameter DATA_W = 64
)(
    input wire clk,
    input wire rst_n,

    // Operand Interface
    input wire op_valid,
    input wire [3:0] op_warp_id,
    input wire [7:0] op_opcode,
    input wire [4:0] op_rd,
    input wire [31:0] op_imm,
    input wire op_is_imm,
    input wire [63:0] op_rs1_data,
    input wire [63:0] op_rs2_data,

    // Write-Back Interface (To vector_regfile)
    output reg wb_valid,
    output reg [3:0] wb_warp_id,
    output reg [4:0] wb_rd,
    output reg [63:0] wb_data,

    // To PC module
    output wire alu_updates_nzp,
    output wire [2:0] next_nzp0,
    output wire [2:0] next_nzp1,
    output wire is_exit,
    output wire is_branch,
    output wire is_sync
);

    // Opcodes Definition
    localparam OP_ADD = 8'h01;
    localparam OP_SUB = 8'h02;
    localparam OP_MUL = 8'h03;
    localparam OP_CMP = 8'h04;
    localparam OP_ADDI = 8'h81;
    localparam OP_BR = 8'hC0;
    localparam OP_SYNC = 8'hE0;
    localparam OP_EXIT = 8'hFF;

    // ALU Combinational Logic
    wire [31:0] lane0_rs1 = op_rs1_data[31:0];
    wire [31:0] lane1_rs1 = op_rs1_data[63:32];
    
    wire [31:0] lane0_rs2 = op_is_imm ? op_imm : op_rs2_data[31:0];
    wire [31:0] lane1_rs2 = op_is_imm ? op_imm : op_rs2_data[63:32];

    reg [31:0] alu0_out;
    reg [31:0] alu1_out;
    reg alu_writes_reg;
    reg _alu_updates_nzp;
    reg _is_exit;
    reg _is_branch;
    reg _is_sync;
    
    always @(*) begin
        alu0_out = 32'd0;
        alu1_out = 32'd0;
        alu_writes_reg = 1'b0;
        _alu_updates_nzp = 1'b0;
        _is_exit = 1'b0;
        _is_branch = 1'b0;
        _is_sync = 1'b0;

        case (op_opcode)
            OP_ADD, OP_ADDI: begin
                alu0_out = lane0_rs1 + lane0_rs2;
                alu1_out = lane1_rs1 + lane1_rs2;
                alu_writes_reg = 1'b1;
                _alu_updates_nzp = 1'b1;
            end
            OP_SUB, OP_CMP: begin
                alu0_out = lane0_rs1 - lane0_rs2;
                alu1_out = lane1_rs1 - lane1_rs2;
                alu_writes_reg = (op_opcode == OP_SUB);
                _alu_updates_nzp = 1'b1;
            end
            OP_MUL: begin
                alu0_out = lane0_rs1 * lane0_rs2;
                alu1_out = lane1_rs1 * lane1_rs2;
                alu_writes_reg = 1'b1;
                _alu_updates_nzp = 1'b1;
            end
            OP_BR: begin
                _is_branch = 1'b1;
            end
            OP_SYNC: begin
                _is_sync = 1'b1;
            end
            OP_EXIT: begin
                _is_exit = 1'b1;
            end
            default: ;
        endcase
    end

    assign alu_updates_nzp = _alu_updates_nzp;
    assign is_exit = _is_exit;
    assign is_branch = _is_branch;
    assign is_sync = _is_sync;

    wire next_n0 = alu0_out[31];
    wire next_z0 = (alu0_out == 32'd0);
    wire next_p0 = (!next_n0 && !next_z0);
    assign next_nzp0 = {next_n0, next_z0, next_p0};

    wire next_n1 = alu1_out[31];
    wire next_z1 = (alu1_out == 32'd0);
    wire next_p1 = (!next_n1 && !next_z1);
    assign next_nzp1 = {next_n1, next_z1, next_p1};

    // Pipeline Register (Execution -> Write-Back)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_valid <= 1'b0;
            wb_warp_id <= 4'd0;
            wb_rd <= 5'd0;
            wb_data <= 64'd0;
        end else begin
            wb_valid <= 1'b0;
            if (op_valid) begin
                if (alu_writes_reg && (op_rd != 5'd0)) begin
                    wb_valid <= 1'b1;
                    wb_warp_id <= op_warp_id;
                    wb_rd <= op_rd;
                    wb_data <= {alu1_out, alu0_out};
                end
            end
        end
    end

endmodule

`timescale 1ns / 1ps
// ALU (Arithmetic Logic Unit)
// 
// ALU is instantiated in processing_block.sv
// currently it only supports integer arithmetic (ADD, SUB, MUL) 
// and logical operations for all active threads in a warp. 
// It processes multiple lanes in parallel
//

import gpu_pkg::*;

module alu (
    input wire clk,
    input wire rst_n,

    // Operand Interface
    operand_if.slave op,

    // Write-Back Interface (To vector_regfile)
    wb_if.master wb,

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
    localparam OP_S2R = 8'hB0;
    localparam OP_BR = 8'hC0;
    localparam OP_SYNC = 8'hE0;
    localparam OP_EXIT = 8'hFF;

    // ALU Combinational Logic
    wire [31:0] lane0_rs1 = op.rs1_data[31:0];
    wire [31:0] lane1_rs1 = op.rs1_data[63:32];
    
    wire [31:0] lane0_rs2 = op.is_imm ? op.imm : op.rs2_data[31:0];
    wire [31:0] lane1_rs2 = op.is_imm ? op.imm : op.rs2_data[63:32];

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

        case (op.opcode)
            OP_ADD, OP_ADDI: begin
                alu0_out = lane0_rs1 + lane0_rs2;
                alu1_out = lane1_rs1 + lane1_rs2;
                alu_writes_reg = 1'b1;
                _alu_updates_nzp = 1'b1;
            end
            OP_SUB, OP_CMP: begin
                alu0_out = lane0_rs1 - lane0_rs2;
                alu1_out = lane1_rs1 - lane1_rs2;
                alu_writes_reg = (op.opcode == OP_SUB);
                _alu_updates_nzp = 1'b1;
            end
            OP_MUL: begin
                alu0_out = lane0_rs1 * lane0_rs2;
                alu1_out = lane1_rs1 * lane1_rs2;
                alu_writes_reg = 1'b1;
                _alu_updates_nzp = 1'b1;
            end
            OP_S2R: begin
                alu_writes_reg = 1'b1;
                // Imm specifies which system register to read
                case (op.imm)
                    32'd0: begin // SR_TID.X
                        alu0_out = op.thread_id_start;
                        alu1_out = op.thread_id_start + 32'd1;
                    end
                    32'd1: begin // SR_TID.Y (Assume 1D for now, output 0)
                        alu0_out = 32'd0;
                        alu1_out = 32'd0;
                    end
                    32'd2: begin // SR_BID.X
                        alu0_out = op.block_idx_x;
                        alu1_out = op.block_idx_x;
                    end
                    32'd3: begin // SR_BID.Y
                        alu0_out = op.block_idx_y;
                        alu1_out = op.block_idx_y;
                    end
                    default: begin
                        alu0_out = 32'd0;
                        alu1_out = 32'd0;
                    end
                endcase
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
            wb.valid <= 1'b0;
            wb.warp_id <= 4'd0;
            wb.rd <= 5'd0;
            wb.data <= 64'd0;
            wb.mask <= 32'hFFFFFFFF; // Assuming all lanes active for now, or drive properly if added to operand_if
        end else begin
            wb.valid <= 1'b0;
            if (op.valid) begin
                if (alu_writes_reg && (op.rd != 5'd0)) begin
                    wb.valid <= 1'b1;
                    wb.warp_id <= op.warp_id;
                    wb.rd <= op.rd;
                    wb.data <= {alu1_out, alu0_out};
                    wb.mask <= 32'hFFFFFFFF;
                end
            end
        end
    end

endmodule

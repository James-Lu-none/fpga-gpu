`timescale 1ns / 1ps
// PC (Program Counter & Branch Control Unit)
// Evaluates branch conditions, divergence masks, and next PC

module pc #(
    parameter MAX_WARPS = 16
)(
    input wire clk,
    input wire rst_n,

    // Operand Interface
    input wire op_valid,
    input wire [3:0] op_warp_id,
    input wire [11:0] op_pc,
    input wire [31:0] op_active_mask,
    input wire [4:0] op_rd, // for branch cond
    input wire [31:0] op_imm,

    // From ALU
    input wire alu_updates_nzp,
    input wire [2:0] next_nzp0,
    input wire [2:0] next_nzp1,
    input wire is_exit,
    input wire is_branch,
    input wire is_sync,

    // State Update Interface (To sm_warp_context)
    output reg ctx_wb_valid,
    output reg [3:0] ctx_wb_warp_id,
    output reg [11:0] ctx_wb_next_pc,
    output reg ctx_wb_is_done,
    output reg [31:0] ctx_wb_taken_mask,
    output reg [31:0] ctx_wb_not_taken_mask,
    output reg ctx_wb_is_divergent,
    output reg ctx_wb_is_sync
);

    // NZP Registers (Condition Codes per Warp, Per Lane)
    // [2]=N, [1]=Z, [0]=P
    reg [2:0] warp_nzp [0:MAX_WARPS-1][0:31];

    integer i, j;
    initial begin
        for (i=0; i<MAX_WARPS; i=i+1) begin
            for (j=0; j<32; j=j+1) begin
                warp_nzp[i][j] = 3'b000;
            end
        end
    end

    // Combinational Branch Evaluator
    wire [2:0] branch_cond = op_rd[2:0];
    wire branch_take0 = ((branch_cond & warp_nzp[op_warp_id][0]) != 3'b000) && op_active_mask[0];
    wire branch_take1 = ((branch_cond & warp_nzp[op_warp_id][1]) != 3'b000) && op_active_mask[1];
    
    wire [31:0] comb_taken_mask = {30'd0, branch_take1, branch_take0};
    wire [31:0] comb_not_taken_mask = op_active_mask & ~comb_taken_mask;

    // Pipeline Register (Execution -> Write-Back)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctx_wb_valid <= 1'b0;
            ctx_wb_warp_id <= 4'd0;
            ctx_wb_next_pc <= 12'd0;
            ctx_wb_is_done <= 1'b0;
            ctx_wb_taken_mask <= 32'd0;
            ctx_wb_not_taken_mask <= 32'd0;
            ctx_wb_is_divergent <= 1'b0;
            ctx_wb_is_sync <= 1'b0;
        end else begin
            ctx_wb_valid <= 1'b0;
            ctx_wb_is_divergent <= 1'b0;
            ctx_wb_is_sync <= 1'b0;

            if (op_valid) begin
                // 1. Update NZP Register
                if (alu_updates_nzp) begin
                    if (op_active_mask[0]) warp_nzp[op_warp_id][0] <= next_nzp0;
                    if (op_active_mask[1]) warp_nzp[op_warp_id][1] <= next_nzp1;
                end

                // 2. PC & State Update
                ctx_wb_valid <= 1'b1;
                ctx_wb_warp_id <= op_warp_id;
                ctx_wb_is_done <= is_exit;
                
                // Branch & Sync Logic (Divergence Tester)
                if (is_sync) begin
                    ctx_wb_is_sync <= 1'b1;
                    ctx_wb_next_pc <= op_pc + 12'd1;
                end else if (is_branch) begin
                    if (comb_taken_mask != 32'd0 && comb_not_taken_mask != 32'd0) begin
                        // Divergence!
                        ctx_wb_is_divergent <= 1'b1;
                        ctx_wb_taken_mask <= comb_taken_mask;
                        ctx_wb_not_taken_mask <= comb_not_taken_mask;
                        ctx_wb_next_pc <= op_pc + op_imm[11:0]; // Taken path executes first
                    end else if (comb_taken_mask != 32'd0) begin
                        // All active threads take the branch (No Divergence)
                        ctx_wb_next_pc <= op_pc + op_imm[11:0];
                    end else begin
                        // All active threads don't take the branch
                        ctx_wb_next_pc <= op_pc + 12'd1;
                    end
                end else begin
                    // Normal execution
                    ctx_wb_next_pc <= op_pc + 12'd1;
                end
            end
        end
    end

endmodule

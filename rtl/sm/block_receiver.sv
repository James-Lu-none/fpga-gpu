`timescale 1ns / 1ps

// SM Block Receiver (Local Thread Block Dispatcher)
// Receives a single Thread Block from the global TBS and slices it into
// Warps, allocating them into the local warp_context.

import gpu_pkg::*;

module block_receiver (
    input wire clk,
    input wire rst_n,

    // TBS Interface (From thread_block_scheduler)
    input wire block_issue_valid,
    input wire [15:0] block_idx_x,
    input wire [15:0] block_idx_y,
    input wire [9:0] warps_per_block,
    
    output reg block_accepted,

    // Warp Allocation Interface (To warp_context)
    warp_alloc_if.master alloc
);

    localparam ST_IDLE = 3'd0;
    localparam ST_ISSUE_WARP = 3'd1;
    localparam ST_WAIT_WARP = 3'd2;
    localparam ST_NEXT_WARP = 3'd3;

    reg [2:0] state;
    reg [9:0] warp_cnt;

    // Linearize block ID for local context tracking
    wire [15:0] linear_block_id = block_idx_x + (block_idx_y * 16'd65535); // Simplified for local context

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            alloc.valid <= 1'b0;
            block_accepted <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    alloc.valid <= 1'b0;
                    block_accepted <= 1'b0;
                    if (block_issue_valid) begin
                        warp_cnt <= 10'd0;
                        block_accepted <= 1'b1;
                        state <= ST_ISSUE_WARP;
                    end
                end

                ST_ISSUE_WARP: begin
                    block_accepted <= 1'b0; // Deassert ack
                    alloc.valid <= 1'b1;
                    alloc.block_id <= linear_block_id;
                    alloc.block_idx_x <= block_idx_x;
                    alloc.block_idx_y <= block_idx_y;
                    alloc.thread_id_start <= warp_cnt * WARP_SIZE; // Thread offset within the block

                    // Active Mask Calculation for boundary Warps
                    // Simplified: assume full warps for now, or use a bitmask generator if thread count is not a multiple of 32.
                    alloc.active_mask <= 32'hFFFFFFFF;

                    if (alloc.ready) begin
                        state <= ST_WAIT_WARP;
                    end
                end

                ST_WAIT_WARP: begin
                    alloc.valid <= 1'b0;
                    if (alloc.ready) begin
                        state <= ST_NEXT_WARP;
                    end
                end

                ST_NEXT_WARP: begin
                    if (warp_cnt + 1 < warps_per_block) begin
                        warp_cnt <= warp_cnt + 1'b1;
                        state <= ST_ISSUE_WARP;
                    end else begin
                        // Finished issuing this block
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

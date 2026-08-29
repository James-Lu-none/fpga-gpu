`timescale 1ns / 1ps

// SM Block Receiver (Local Thread Block Dispatcher)
// Receives a single Thread Block from the global TBS and slices it into
// Warps, allocating them into the local warp_context.

module block_receiver #(
    parameter integer WARP_SIZE = 32
)(
    input wire clk,
    input wire rst_n,

    // TBS Interface (From thread_block_scheduler)
    input wire block_issue_valid,
    input wire [15:0] block_idx_x,
    input wire [15:0] block_idx_y,
    input wire [9:0] warps_per_block,
    
    output reg block_accepted,

    // Warp Allocation Interface (To warp_context)
    output reg warp_valid,
    input wire warp_ready, // Has at least 1 free slot
    output reg [15:0] current_warp_id,
    output reg [15:0] current_block_id, // Linearized Block ID
    output reg [15:0] alloc_block_idx_x,
    output reg [15:0] alloc_block_idx_y,
    output reg [31:0] active_mask, 
    output reg [15:0] thread_id_start 
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
            warp_valid <= 1'b0;
            block_accepted <= 1'b0;
            current_warp_id <= 16'd0;
            current_block_id <= 16'd0;
            alloc_block_idx_x <= 16'd0;
            alloc_block_idx_y <= 16'd0;
            active_mask <= 32'hFFFFFFFF;
            thread_id_start <= 16'd0;
            warp_cnt <= 10'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    warp_valid <= 1'b0;
                    block_accepted <= 1'b0;
                    if (block_issue_valid) begin
                        warp_cnt <= 10'd0;
                        block_accepted <= 1'b1;
                        state <= ST_ISSUE_WARP;
                    end
                end

                ST_ISSUE_WARP: begin
                    block_accepted <= 1'b0; // Deassert ack
                    warp_valid <= 1'b1;
                    current_block_id <= linear_block_id;
                    alloc_block_idx_x <= block_idx_x;
                    alloc_block_idx_y <= block_idx_y;
                    current_warp_id <= warp_cnt;
                    thread_id_start <= warp_cnt * WARP_SIZE; // Thread offset within the block

                    // Active Mask Calculation for boundary Warps
                    // Simplified: assume full warps for now, or use a bitmask generator if thread count is not a multiple of 32.
                    active_mask <= 32'hFFFFFFFF;

                    if (warp_ready) begin
                        state <= ST_WAIT_WARP;
                    end
                end

                ST_WAIT_WARP: begin
                    warp_valid <= 1'b0;
                    if (warp_ready) begin
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

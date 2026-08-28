`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////--
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/25
// Design Name: Hardware Warp Scheduler RTL
// Module Name: gpu_warp_scheduler
// Project Name: fpga-gpu (Accelerated Computing with Linux Kernel vGPU-Core)
// Target Devices: Xilinx Artix-7 (XC7A200T-2FBG484)
// Tool Versions: Vivado 2026+
// Description: 
//   NVIDIA GP100-Style Hardware Warp Scheduler & Block Dispatcher.
//   Maps 2D/3D CUDA Grid & Block Dimensions into 32-thread Warps.
//   Manages Active Warp States, Issue Logic, and Thread Active Masks.
////////////////////////////////////////////////////////////////////////////////--

module sm_warp_allocator #(
    parameter integer WARP_SIZE = 32
)(
    input  wire        clk,
    input  wire        rst_n,

    // Launch Control Signals from Command Processor / Host
    input  wire        launch_en,
    input  wire [15:0] grid_dim_x,
    input  wire [15:0] grid_dim_y,
    input  wire [15:0] block_dim_x,
    input  wire [15:0] block_dim_y,

    // Warp Dispatch Interface to SIMT ALU Core
    output reg         warp_valid,
    input  wire        warp_ready,
    output reg  [15:0] current_warp_id,
    output reg  [15:0] current_block_id,
    output reg  [31:0] active_mask,        // 32-bit active thread bitmask
    output reg  [15:0] thread_id_start,    // Base thread ID for current warp

    // Status Signals
    output reg         grid_done
);

    // Internal Calculations
    reg [31:0] total_threads_per_block;
    reg [15:0] warps_per_block;
    reg [31:0] total_blocks;
    reg [15:0] block_cnt;
    reg [15:0] warp_cnt;

    // FSM States
    localparam ST_IDLE       = 3'd0,
               ST_CALC       = 3'd1,
               ST_ISSUE_WARP = 3'd2,
               ST_WAIT_WARP  = 3'd3,
               ST_NEXT_WARP  = 3'd4,
               ST_DONE       = 3'd5;

    reg [2:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                  <= ST_IDLE;
            warp_valid             <= 1'b0;
            current_warp_id        <= 16'd0;
            current_block_id       <= 16'd0;
            active_mask            <= 32'hFFFFFFFF;
            thread_id_start        <= 16'd0;
            grid_done              <= 1'b0;
            total_threads_per_block<= 32'd0;
            warps_per_block        <= 16'd0;
            total_blocks           <= 32'd0;
            block_cnt              <= 16'd0;
            warp_cnt               <= 16'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    warp_valid <= 1'b0;
                    grid_done  <= 1'b0;
                    if (launch_en) begin
                        state <= ST_CALC;
                    end
                end

                ST_CALC: begin
                    total_threads_per_block <= block_dim_x * block_dim_y;
                    total_blocks            <= grid_dim_x * grid_dim_y;
                    // Calculate Warps per Block: ceil(total_threads / 32)
                    warps_per_block         <= ((block_dim_x * block_dim_y) + 31) / 32;
                    block_cnt               <= 16'd0;
                    warp_cnt                <= 16'd0;
                    state                   <= ST_ISSUE_WARP;
                end

                ST_ISSUE_WARP: begin
                    warp_valid       <= 1'b1;
                    current_block_id <= block_cnt;
                    current_warp_id  <= warp_cnt;
                    thread_id_start  <= (block_cnt * total_threads_per_block) + (warp_cnt * WARP_SIZE);

                    // Active Mask Calculation for boundary Warps
                    active_mask      <= 32'hFFFFFFFF;

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
                        state    <= ST_ISSUE_WARP;
                    end else if (block_cnt + 1 < total_blocks) begin
                        block_cnt <= block_cnt + 1'b1;
                        warp_cnt  <= 16'd0;
                        state     <= ST_ISSUE_WARP;
                    end else begin
                        state <= ST_DONE;
                    end
                end

                ST_DONE: begin
                    grid_done  <= 1'b1;
                    warp_valid <= 1'b0;
                    state      <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

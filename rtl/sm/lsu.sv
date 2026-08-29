`timescale 1ns / 1ps
// SM Load/Store Unit (LSU)
// Receives memory instructions, communicates with L1 Data Cache, 
// and writes back data to the VRF upon completion.

module lsu (
    input wire clk,
    input wire rst_n,

    // Operand Interface (From Dispatcher / VRF)
    input wire op_valid,
    input wire [3:0] op_warp_id,
    input wire [11:0] op_pc,
    input wire [7:0] op_opcode,
    input wire [4:0] op_rd,
    input wire [63:0] op_rs1_data, // Address (Lane 0)
    input wire [63:0] op_rs2_data, // Store Data
    output wire lsu_ready, // LSU can accept new instruction

    // L1 Cache Interface
    output reg l1_req_valid,
    output reg [31:0] l1_req_addr,
    output reg [63:0] l1_req_wdata,
    output reg l1_req_we,
    input wire l1_req_ready,

    input wire l1_rsp_valid,
    input wire [63:0] l1_rsp_rdata,

    // Write-Back Interface (To VRF and Context Scheduler)
    output reg lsu_wb_valid,
    output reg [3:0] lsu_wb_warp_id,
    output reg [11:0] lsu_wb_next_pc,
    output reg [4:0] lsu_wb_rd,
    output reg [63:0] lsu_wb_data
);

    localparam OP_LDR = 8'hA0;
    localparam OP_STR = 8'hA1;

    // We keep it simple: 1 active request at a time for this simple LSU
    // In a real GPU, M LSUs can track M outstanding requests using a scoreboard/MSHR.
    localparam STATE_IDLE = 1'b0;
    localparam STATE_WAIT = 1'b1;

    reg state;
    reg [3:0] active_warp_id;
    reg [11:0] active_pc;
    reg [4:0] active_rd;
    reg is_load;

    assign lsu_ready = (state == STATE_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            active_warp_id <= 4'd0;
            active_pc <= 12'd0;
            active_rd <= 5'd0;
            is_load <= 1'b0;
            
            l1_req_valid <= 1'b0;
            l1_req_addr <= 32'd0;
            l1_req_wdata <= 64'd0;
            l1_req_we <= 1'b0;
            
            lsu_wb_valid <= 1'b0;
            lsu_wb_warp_id <= 4'd0;
            lsu_wb_next_pc <= 12'd0;
            lsu_wb_rd <= 5'd0;
            lsu_wb_data <= 64'd0;
        end else begin
            // Default de-asserts
            lsu_wb_valid <= 1'b0;
            
            case (state)
                STATE_IDLE: begin
                    if (op_valid && lsu_ready) begin
                        if (op_opcode == OP_LDR || op_opcode == OP_STR) begin
                            l1_req_valid <= 1'b1;
                            l1_req_addr <= op_rs1_data[31:0]; // Use Lane 0 RS1 as Address
                            l1_req_wdata <= op_rs2_data; // Write data
                            l1_req_we <= (op_opcode == OP_STR);
                            
                            active_warp_id <= op_warp_id;
                            active_pc <= op_pc;
                            active_rd <= op_rd;
                            is_load <= (op_opcode == OP_LDR);
                            
                            state <= STATE_WAIT;
                        end
                    end
                end

                STATE_WAIT: begin
                    if (l1_req_valid && l1_req_ready) begin
                        l1_req_valid <= 1'b0; // Handshake complete
                    end
                    
                    if (l1_rsp_valid) begin
                        // L1 operation completed
                        if (is_load && (active_rd != 5'd0)) begin
                            lsu_wb_valid <= 1'b1;
                            lsu_wb_warp_id <= active_warp_id;
                            lsu_wb_next_pc <= active_pc + 12'd1;
                            lsu_wb_rd <= active_rd;
                            lsu_wb_data <= l1_rsp_rdata;
                        end else begin
                            // Store or dummy load
                            lsu_wb_valid <= 1'b1; // Still need to wake up the warp
                            lsu_wb_warp_id <= active_warp_id;
                            lsu_wb_next_pc <= active_pc + 12'd1;
                            lsu_wb_rd <= 5'd0;
                        end
                        state <= STATE_IDLE;
                    end
                end
            endcase
        end
    end

endmodule

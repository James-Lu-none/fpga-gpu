`timescale 1ns / 1ps
// SM L1 Data Cache (Write-Through, Read-Allocate)
// Services memory requests from LSU. Connects to Shared L2 Cache.
// Capacity: 2KB (64 lines x 32 Bytes) Direct Mapped

module l1_cache (
    input wire clk,
    input wire rst_n,

    // LSU Interface (Simple Handshake)
    input wire req_valid,
    input wire [31:0] req_addr,
    input wire [63:0] req_wdata, // 64-bit (2 lanes x 32-bit)
    input wire req_we,
    output reg req_ready, // Ready to accept new request
    
    output reg rsp_valid,
    output reg [63:0] rsp_rdata,

    // L2 Cache Interface (To GPC L2 Arbiter)
    output reg l2_req_valid,
    output reg [31:0] l2_req_addr, // 32-byte aligned address
    output reg [255:0] l2_req_wdata, // Write-through data (mask handled by L2 if needed)
    output reg [31:0] l2_req_wstrb, // Byte enables
    output reg l2_req_we,
    input wire l2_req_ready,

    input wire l2_rsp_valid,
    input wire [255:0] l2_rsp_rdata
);

    // Cache Parameters & Breakdown
    // 32-bit Address = [31:11] Tag (21 bits) | [10:5] Index (6 bits) | [4:0] Offset (5 bits)
    localparam LINE_SIZE_BYTES = 32;
    localparam NUM_LINES = 64;
    
    wire [20:0] req_tag = req_addr[31:11];
    wire [5:0] req_index = req_addr[10:5];
    wire [4:0] req_offset= req_addr[4:0];

    // Storage (Tag & Data)
    (* ram_style = "block" *) reg [255:0] data_ram [0:NUM_LINES-1];
    (* ram_style = "distributed" *) reg [20:0] tag_ram [0:NUM_LINES-1];
    (* ram_style = "distributed" *) reg valid_ram [0:NUM_LINES-1];

    integer i;
    initial begin
        for (i=0; i<NUM_LINES; i=i+1) begin
            valid_ram[i] = 1'b0;
        end
    end

    // FSM
    localparam STATE_IDLE = 2'd0;
    localparam STATE_MISS = 2'd1;
    localparam STATE_WR_THRU = 2'd2;
    
    reg [1:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            req_ready <= 1'b1;
            rsp_valid <= 1'b0;
            rsp_rdata <= 64'd0;
            l2_req_valid <= 1'b0;
            l2_req_addr <= 32'd0;
            l2_req_wdata <= 256'd0;
            l2_req_wstrb <= 32'd0;
            l2_req_we <= 1'b0;
        end else begin
            // Default de-asserts
            rsp_valid <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    if (req_valid && req_ready) begin
                        req_ready <= 1'b0; // Block further requests
                        
                        // Hit/Miss Check
                        if (valid_ram[req_index] && (tag_ram[req_index] == req_tag)) begin
                            // HIT
                            if (req_we) begin
                                // Write-Through: Must go to L2
                                l2_req_valid <= 1'b1;
                                l2_req_addr <= {req_addr[31:5], 5'd0};
                                l2_req_we <= 1'b1;
                                
                                // Shift wdata to correct position
                                // req_offset[4:3] selects which 64-bit chunk (0 to 3)
                                l2_req_wdata <= {192'd0, req_wdata} << (req_offset[4:3] * 64);
                                l2_req_wstrb <= 32'h00_00_00_FF << req_offset;
                                
                                // Also update local L1 Cache Data
                                // In Verilog, we can just do a partial update if we model byte-enables,
                                // but for simplicity, we'll just invalidate on write or implement a RMW.
                                // Actually, since we're writing through, let's just invalidate L1 on write 
                                // to avoid RMW complexity in a simple 1-cycle hit path.
                                valid_ram[req_index] <= 1'b0; 
                                
                                state <= STATE_WR_THRU;
                            end else begin
                                // Read Hit
                                rsp_valid <= 1'b1;
                                // Extract 64-bit data from 256-bit line
                                case (req_offset[4:3])
                                    2'd0: rsp_rdata <= data_ram[req_index][63:0];
                                    2'd1: rsp_rdata <= data_ram[req_index][127:64];
                                    2'd2: rsp_rdata <= data_ram[req_index][191:128];
                                    2'd3: rsp_rdata <= data_ram[req_index][255:192];
                                endcase
                                req_ready <= 1'b1; // Ready for next cycle
                            end
                        end else begin
                            // MISS
                            if (req_we) begin
                                // Write-Miss: Write-Around (send to L2 only)
                                l2_req_valid <= 1'b1;
                                l2_req_addr <= {req_addr[31:5], 5'd0};
                                l2_req_we <= 1'b1;
                                l2_req_wdata <= {192'd0, req_wdata} << (req_offset[4:3] * 64);
                                l2_req_wstrb <= 32'h00_00_00_FF << req_offset;
                                state <= STATE_WR_THRU;
                            end else begin
                                // Read-Miss: Fetch from L2
                                l2_req_valid <= 1'b1;
                                l2_req_addr <= {req_addr[31:5], 5'd0};
                                l2_req_we <= 1'b0;
                                l2_req_wstrb <= 32'd0;
                                state <= STATE_MISS;
                            end
                        end
                    end
                end

                STATE_MISS: begin
                    if (l2_req_valid && l2_req_ready) begin
                        l2_req_valid <= 1'b0; // Handshake complete
                    end
                    if (l2_rsp_valid) begin
                        // Refill L1
                        valid_ram[req_index] <= 1'b1;
                        tag_ram[req_index] <= req_tag;
                        data_ram[req_index] <= l2_rsp_rdata;
                        
                        // Return data to LSU
                        rsp_valid <= 1'b1;
                        case (req_offset[4:3])
                            2'd0: rsp_rdata <= l2_rsp_rdata[63:0];
                            2'd1: rsp_rdata <= l2_rsp_rdata[127:64];
                            2'd2: rsp_rdata <= l2_rsp_rdata[191:128];
                            2'd3: rsp_rdata <= l2_rsp_rdata[255:192];
                        endcase
                        
                        req_ready <= 1'b1;
                        state <= STATE_IDLE;
                    end
                end

                STATE_WR_THRU: begin
                    if (l2_req_valid && l2_req_ready) begin
                        l2_req_valid <= 1'b0;
                        // For a simple Write-Through, we assume write completes when accepted by L2 Arbiter
                        // (L2 will buffer it or stall itself)
                        // Return ACK to LSU
                        rsp_valid <= 1'b1;
                        rsp_rdata <= 64'd0;
                        req_ready <= 1'b1;
                        state <= STATE_IDLE;
                    end
                end
            endcase
        end
    end

endmodule

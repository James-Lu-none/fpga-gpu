`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////--
// Streaming Multiprocessor (SM) Compute Core
// Pure Data Path and ALU Execution Logic
////////////////////////////////////////////////////////////////////////////////--

module sm_core (
    input  wire        clk,
    input  wire        rst_n,

    // Execution Control
    input  wire        start_exec,
    input  wire [31:0] opcode,
    input  wire [31:0] active_mask,
    output wire        exec_done,

    // SMEM Interface (Asynchronous Read, Synchronous Write)
    output wire [7:0]  smem_raddr,
    input  wire [63:0] smem_rdata,

    output reg         smem_we,
    output reg  [7:0]  smem_waddr,
    output reg  [63:0] smem_wdata,

    // Framebuffer Render Interface
    output reg         fb_we,
    output reg  [18:0] fb_addr,
    output reg  [23:0] fb_rgb
);

    reg [8:0] tile_cnt;
    reg       running;

    assign smem_raddr = tile_cnt[7:0];
    assign exec_done  = (running && tile_cnt == 9'd255);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tile_cnt   <= 9'd0;
            running    <= 1'b0;
            smem_we    <= 1'b0;
            smem_waddr <= 8'd0;
            smem_wdata <= 64'd0;
            fb_we      <= 1'b0;
            fb_addr    <= 19'd0;
            fb_rgb     <= 24'd0;
        end else begin
            smem_we <= 1'b0;
            fb_we   <= 1'b0;

            if (start_exec && !running) begin
                running  <= 1'b1;
                tile_cnt <= 9'd0;
            end else if (running) begin
                
                // SIMD Execution based on Opcode
                case (opcode)
                    32'd1: begin // Opcode 1: Vector Add (+1) on VRAM Tile
                        smem_we    <= active_mask[0]; // Mask applies to write enable
                        smem_waddr <= tile_cnt[7:0];
                        smem_wdata <= {smem_rdata[63:32] + 32'd1, smem_rdata[31:0] + 32'd1};
                    end

                    32'd2: begin // Opcode 2: Vector Multiply (*2) on VRAM Tile
                        smem_we    <= active_mask[0];
                        smem_waddr <= tile_cnt[7:0];
                        smem_wdata <= {smem_rdata[63:32] << 1, smem_rdata[31:0] << 1};
                    end

                    32'd3: begin // Opcode 3: CUDA Render to Framebuffer VRAM
                        fb_we   <= active_mask[0];
                        fb_addr <= smem_rdata[18:0];
                        fb_rgb  <= {smem_rdata[23:16], smem_rdata[15:8], smem_rdata[7:0]};
                    end

                    32'd5: begin // Opcode 5: Multi-Pass SMEM Accumulate
                        smem_we    <= active_mask[0];
                        smem_waddr <= tile_cnt[7:0];
                        smem_wdata <= smem_rdata + 64'd10;
                    end

                    default: begin // Passthrough (No Operation)
                        smem_we <= 1'b0;
                    end
                endcase

                // Loop over 256 SMEM words
                if (tile_cnt == 9'd255) begin
                    running  <= 1'b0;
                end else begin
                    tile_cnt <= tile_cnt + 9'd1;
                end
            end
        end
    end

endmodule

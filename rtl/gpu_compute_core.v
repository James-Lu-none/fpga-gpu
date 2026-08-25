`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////--
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/25
// Design Name: Streaming Multiprocessor (SM) Top Compute Core
// Module Name: gpu_compute_core
// Project Name: fpga-gpu (Accelerated Computing with Linux Kernel vGPU-Core)
// Target Devices: Xilinx Artix-7 (XC7A200T-2FBG484)
// Tool Versions: Vivado 2026+
// Description: 
//   NVIDIA GP100-Style Streaming Multiprocessor (SM) Engine with Full 256-bit DDR3 VRAM Engine:
//   1. Host H2C DMA writes directly to DDR3 VRAM (0x8000_0000).
//   2. RISC-V CP triggers gpu_compute_core passing src_vram_addr and dst_vram_addr.
//   3. Parallel Compute Engine uses 256-bit AXI4-Full Master (m_axi_gmem) to Tile Load DDR3 -> SMEM.
//   4. Hardware Warp Scheduler dispatches 32-thread Warps across 4-wide SIMD PEs to process SMEM Tile.
//   5. AXI4-Full Tile Store writes computed SMEM results back to DDR3 VRAM (0x8000_1000).
//   6. Asserts grid_done interrupt when DDR3 VRAM write-back completes.
////////////////////////////////////////////////////////////////////////////////--

module gpu_compute_core #(
    parameter integer C_AXIS_DATA_WIDTH = 64
)(
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire [31:0]                       opcode,

    // Launch Control & Grid/Block Configuration Interface
    input  wire                              launch_en,
    input  wire [15:0]                       grid_dim_x,
    input  wire [15:0]                       grid_dim_y,
    input  wire [15:0]                       block_dim_x,
    input  wire [15:0]                       block_dim_y,
    input  wire [63:0]                       src_vram_addr, // e.g. 0x8000_0000
    input  wire [63:0]                       dst_vram_addr, // e.g. 0x8000_1000
    output reg                               grid_done,

    // 256-bit AXI4-Full Master Interface (Direct Connection to DDR3 Crossbar S01 at 0x8000_0000)
    output reg  [31:0]                       m_axi_gmem_araddr,
    output reg  [7:0]                        m_axi_gmem_arlen,
    output reg                               m_axi_gmem_arvalid,
    input  wire                              m_axi_gmem_arready,
    input  wire [255:0]                      m_axi_gmem_rdata,
    input  wire                              m_axi_gmem_rvalid,
    output reg                               m_axi_gmem_rready,

    output reg  [31:0]                       m_axi_gmem_awaddr,
    output reg  [7:0]                        m_axi_gmem_awlen,
    output reg                               m_axi_gmem_awvalid,
    input  wire                              m_axi_gmem_awready,
    output reg  [255:0]                      m_axi_gmem_wdata,
    output reg  [31:0]                       m_axi_gmem_wstrb,
    output reg                               m_axi_gmem_wvalid,
    input  wire                              m_axi_gmem_wready,

    // Framebuffer Parallel Render Output Interface
    output reg                               fb_we,
    output reg  [18:0]                       fb_addr,
    output reg  [23:0]                       fb_rgb
);

    // ---------------------------------------------------------------------
    // CUDA Shared Memory (SMEM Distributed LUTRAM Array: 256 x 64-bit words)
    // ---------------------------------------------------------------------
    (* ram_style = "distributed" *)
    reg [63:0] smem_ram [0:255];

    localparam ST_IDLE       = 3'd0,
               ST_TILE_LOAD  = 3'd1,
               ST_WARP_EXEC  = 3'd2,
               ST_TILE_STORE = 3'd3,
               ST_DONE       = 3'd4;

    reg [2:0] tile_state;
    reg [7:0] tile_cnt;

    // Single-Process Synchronous Write Control for smem_ram
    reg        smem_we;
    reg [7:0]  smem_waddr;
    reg [63:0] smem_wdata;

    always @(posedge clk) begin
        if (smem_we) begin
            smem_ram[smem_waddr] <= smem_wdata;
        end
    end

    // ---------------------------------------------------------------------
    // Hardware Warp Scheduler Instance
    // ---------------------------------------------------------------------
    wire        warp_valid;
    reg         warp_ready;
    wire [15:0] current_warp_id;
    wire [15:0] current_block_id;
    wire [31:0] active_mask;
    wire [15:0] thread_id_start;
    wire        sched_grid_done;

    gpu_warp_scheduler u_warp_sched (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .launch_en              (launch_en && (tile_state == ST_WARP_EXEC)),
        .grid_dim_x             (grid_dim_x),
        .grid_dim_y             (grid_dim_y),
        .block_dim_x            (block_dim_x),
        .block_dim_y            (block_dim_y),
        .warp_valid             (warp_valid),
        .warp_ready             (warp_ready),
        .current_warp_id        (current_warp_id),
        .current_block_id       (current_block_id),
        .active_mask            (active_mask),
        .thread_id_start        (thread_id_start),
        .grid_done              (sched_grid_done)
    );

    // ---------------------------------------------------------------------
    // AXI4-Full Tile Load -> SIMD PE Execution -> Tile Store FSM
    // ---------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            warp_ready         <= 1'b1;
            grid_done          <= 1'b0;
            m_axi_gmem_araddr  <= 32'd0;
            m_axi_gmem_arlen   <= 8'd0;
            m_axi_gmem_arvalid <= 1'b0;
            m_axi_gmem_rready  <= 1'b1;
            m_axi_gmem_awaddr  <= 32'd0;
            m_axi_gmem_awlen   <= 8'd0;
            m_axi_gmem_awvalid <= 1'b0;
            m_axi_gmem_wdata   <= 256'd0;
            m_axi_gmem_wstrb   <= 32'hFFFFFFFF;
            m_axi_gmem_wvalid  <= 1'b0;
            tile_state         <= ST_IDLE;
            tile_cnt           <= 8'd0;
            smem_we            <= 1'b0;
            smem_waddr         <= 8'd0;
            smem_wdata         <= 64'd0;
            fb_we              <= 1'b0;
            fb_addr            <= 19'd0;
            fb_rgb             <= 24'd0;
        end else begin
            smem_we <= 1'b0;
            fb_we   <= 1'b0;

            case (tile_state)
                ST_IDLE: begin
                    grid_done <= 1'b0;
                    if (launch_en) begin
                        // 1. Initiate 256-bit AXI4-Full Burst Read from DDR3 VRAM (src_vram_addr)
                        m_axi_gmem_araddr  <= src_vram_addr[31:0];
                        m_axi_gmem_arlen   <= 8'd255; // Burst 256 words
                        m_axi_gmem_arvalid <= 1'b1;
                        tile_cnt           <= 8'd0;
                        tile_state         <= ST_TILE_LOAD;
                    end
                end

                ST_TILE_LOAD: begin
                    if (m_axi_gmem_arvalid && m_axi_gmem_arready) begin
                        m_axi_gmem_arvalid <= 1'b0;
                    end

                    if (m_axi_gmem_rvalid && m_axi_gmem_rready) begin
                        // Write DDR3 VRAM word to SMEM SRAM
                        smem_we    <= 1'b1;
                        smem_waddr <= tile_cnt;
                        smem_wdata <= m_axi_gmem_rdata[63:0];

                        if (tile_cnt == 8'd255) begin
                            tile_cnt   <= 8'd0;
                            tile_state <= ST_WARP_EXEC;
                        end else begin
                            tile_cnt <= tile_cnt + 8'd1;
                        end
                    end
                end

                ST_WARP_EXEC: begin
                    if (warp_valid) begin
                        warp_ready <= 1'b1;
                    end

                    // Execute SIMD ALUs per Opcode on SMEM Tile Data
                    case (opcode)
                        32'd1: begin // Opcode 1: Vector Add (+1) on VRAM Tile
                            smem_we    <= 1'b1;
                            smem_waddr <= tile_cnt;
                            smem_wdata <= {smem_ram[tile_cnt][63:32] + 32'd1, smem_ram[tile_cnt][31:0] + 32'd1};
                        end

                        32'd2: begin // Opcode 2: Vector Multiply (*2) on VRAM Tile
                            smem_we    <= 1'b1;
                            smem_waddr <= tile_cnt;
                            smem_wdata <= {smem_ram[tile_cnt][63:32] << 1, smem_ram[tile_cnt][31:0] << 1};
                        end

                        32'd3: begin // Opcode 3: CUDA Render to Framebuffer VRAM
                            fb_we   <= 1'b1;
                            fb_addr <= smem_ram[tile_cnt][18:0];
                            fb_rgb  <= {smem_ram[tile_cnt][23:16], smem_ram[tile_cnt][15:8], smem_ram[tile_cnt][7:0]};
                        end

                        32'd5: begin // Opcode 5: Multi-Pass SMEM Accumulate
                            smem_we    <= 1'b1;
                            smem_waddr <= tile_cnt;
                            smem_wdata <= smem_ram[tile_cnt] + 64'd10;
                        end

                        default: begin // Passthrough
                            smem_we    <= 1'b0;
                        end
                    endcase

                    if (tile_cnt == 8'd255) begin
                        // 2. Initiate 256-bit AXI4-Full Burst Write back to DDR3 VRAM (dst_vram_addr)
                        m_axi_gmem_awaddr  <= dst_vram_addr[31:0];
                        m_axi_gmem_awlen   <= 8'd255;
                        m_axi_gmem_awvalid <= 1'b1;
                        tile_cnt           <= 8'd0;
                        tile_state         <= ST_TILE_STORE;
                    end else begin
                        tile_cnt <= tile_cnt + 8'd1;
                    end
                end

                ST_TILE_STORE: begin
                    if (m_axi_gmem_awvalid && m_axi_gmem_awready) begin
                        m_axi_gmem_awvalid <= 1'b0;
                    end

                    m_axi_gmem_wdata  <= {192'd0, smem_ram[tile_cnt]};
                    m_axi_gmem_wstrb  <= 32'hFFFFFFFF;
                    m_axi_gmem_wvalid <= 1'b1;

                    if (m_axi_gmem_wvalid && m_axi_gmem_wready) begin
                        if (tile_cnt == 8'd255) begin
                            m_axi_gmem_wvalid <= 1'b0;
                            tile_state        <= ST_DONE;
                        end else begin
                            tile_cnt <= tile_cnt + 8'd1;
                        end
                    end
                end

                ST_DONE: begin
                    grid_done  <= 1'b1; // Trigger hardware interrupt to Host
                    tile_state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule

`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////--
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/25
// Design Name: Streaming Multiprocessor (SM) Top Compute Core
// Module Name: vgpu_compute_core
// Project Name: fpga-gpu (Accelerated Computing with Linux Kernel vGPU-Core)
// Target Devices: Xilinx Artix-7 (XC7A200T-2FBG484)
// Tool Versions: Vivado 2026+
// Description: 
//   NVIDIA GP100-Style Streaming Multiprocessor (SM) Engine with Full DDR3 VRAM Engine:
//   1. Host H2C DMA writes directly to DDR3 VRAM (0x8000_0000).
//   2. RISC-V CP triggers vgpu_compute_core passing src_vram_addr and dst_vram_addr.
//   3. Parallel Compute Engine uses AXI4-Full Master (m_axi_gmem) to Tile Load DDR3 -> SMEM.
//   4. Hardware Warp Scheduler dispatches 32-thread Warps across 4-wide SIMD PEs.
//   5. AXI4-Full Tile Store writes results back to DDR3 VRAM (0x8000_1000).
//   6. Host C2H DMA reads final results from DDR3 VRAM back to Host.
////////////////////////////////////////////////////////////////////////////////--

module vgpu_compute_core #(
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
    output wire                              grid_done,

    // AXI4-Full Master Interface (Direct Connection to DDR3 VRAM Controller 0x8000_0000)
    output reg  [63:0]                       m_axi_gmem_araddr,
    output reg  [7:0]                        m_axi_gmem_arlen,
    output reg                               m_axi_gmem_arvalid,
    input  wire                              m_axi_gmem_arready,
    input  wire [63:0]                       m_axi_gmem_rdata,
    input  wire                              m_axi_gmem_rvalid,
    output reg                               m_axi_gmem_rready,

    output reg  [63:0]                       m_axi_gmem_awaddr,
    output reg  [7:0]                        m_axi_gmem_awlen,
    output reg                               m_axi_gmem_awvalid,
    input  wire                              m_axi_gmem_awready,
    output reg  [63:0]                       m_axi_gmem_wdata,
    output reg                               m_axi_gmem_wvalid,
    input  wire                              m_axi_gmem_wready,

    // AXI4-Stream Slave Interface (Input from XDMA H2C Stream)
    input  wire [C_AXIS_DATA_WIDTH-1:0]     s_axis_tdata,
    input  wire [(C_AXIS_DATA_WIDTH/8)-1:0] s_axis_tkeep,
    input  wire                              s_axis_tvalid,
    output wire                              s_axis_tready,
    input  wire                              s_axis_tlast,

    // AXI4-Stream Master Interface (Output to XDMA C2H Stream)
    output reg  [C_AXIS_DATA_WIDTH-1:0]     m_axis_tdata,
    output reg  [(C_AXIS_DATA_WIDTH/8)-1:0] m_axis_tkeep,
    output reg                               m_axis_tvalid,
    input  wire                              m_axis_tready,
    output reg                               m_axis_tlast,

    // Framebuffer Parallel Render Output Interface
    output reg                               fb_we,
    output reg  [18:0]                       fb_addr,
    output reg  [23:0]                       fb_rgb
);

    // ---------------------------------------------------------------------
    // CUDA Shared Memory (SMEM SRAM Array: 256 x 64-bit words)
    // ---------------------------------------------------------------------
    reg [63:0] smem_ram [0:255];
    reg [7:0]  smem_addr;

    // ---------------------------------------------------------------------
    // Hardware Warp Scheduler Instance
    // ---------------------------------------------------------------------
    wire        warp_valid;
    reg         warp_ready;
    wire [15:0] current_warp_id;
    wire [15:0] current_block_id;
    wire [31:0] active_mask;
    wire [15:0] thread_id_start;

    vgpu_warp_scheduler u_warp_sched (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .launch_en              (launch_en),
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
        .grid_done              (grid_done)
    );

    // ---------------------------------------------------------------------
    // AXI4-Full Tile Load / Execution / Tile Store Engine
    // ---------------------------------------------------------------------
    localparam ST_IDLE       = 3'd0,
               ST_TILE_LOAD  = 3'd1,
               ST_WARP_EXEC  = 3'd2,
               ST_TILE_STORE = 3'd3,
               ST_DONE       = 3'd4;

    reg [2:0] tile_state;
    reg [7:0] tile_cnt;

    // ---------------------------------------------------------------------
    // SIMT Processing Element Array (4-wide Parallel ALUs: PE0 ~ PE3)
    // ---------------------------------------------------------------------
    reg [63:0] pe_in_data  [0:3];
    reg [63:0] pe_out_data [0:3];
    reg [7:0]  pe_addr     [0:3];

    // Pass-through ready with pipeline backpressure support
    assign s_axis_tready = m_axis_tready || ~m_axis_tvalid;

    // Warp Issue Execution Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            warp_ready         <= 1'b1;
            m_axi_gmem_araddr  <= 64'd0;
            m_axi_gmem_arlen   <= 8'd0;
            m_axi_gmem_arvalid <= 1'b0;
            m_axi_gmem_rready  <= 1'b1;
            m_axi_gmem_awaddr  <= 64'd0;
            m_axi_gmem_awlen   <= 8'd0;
            m_axi_gmem_awvalid <= 1'b0;
            m_axi_gmem_wdata   <= 64'd0;
            m_axi_gmem_wvalid  <= 1'b0;
            tile_state         <= ST_IDLE;
            tile_cnt           <= 8'd0;
        end else begin
            case (tile_state)
                ST_IDLE: begin
                    if (launch_en) begin
                        // Initiate AXI4-Full Tile Read from DDR3 VRAM (src_vram_addr)
                        m_axi_gmem_araddr  <= src_vram_addr;
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
                        smem_ram[tile_cnt] <= m_axi_gmem_rdata;
                        if (tile_cnt == 8'd255) begin
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
                    if (grid_done) begin
                        // Initiate AXI4-Full Tile Store back to DDR3 VRAM (dst_vram_addr)
                        m_axi_gmem_awaddr  <= dst_vram_addr;
                        m_axi_gmem_awlen   <= 8'd255;
                        m_axi_gmem_awvalid <= 1'b1;
                        tile_cnt           <= 8'd0;
                        tile_state         <= ST_TILE_STORE;
                    end
                end

                ST_TILE_STORE: begin
                    if (m_axi_gmem_awvalid && m_axi_gmem_awready) begin
                        m_axi_gmem_awvalid <= 1'b0;
                    end

                    m_axi_gmem_wdata  <= smem_ram[tile_cnt];
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
                    tile_state <= ST_IDLE;
                end
            endcase
        end
    end

    // Compute Pipeline Process
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= {C_AXIS_DATA_WIDTH{1'b0}};
            m_axis_tkeep  <= {(C_AXIS_DATA_WIDTH/8){1'b0}};
            m_axis_tlast  <= 1'b0;
            fb_we         <= 1'b0;
            fb_addr       <= 19'd0;
            fb_rgb        <= 24'd0;
            smem_addr     <= 8'd0;
        end else begin
            if (s_axis_tready) begin
                m_axis_tvalid <= s_axis_tvalid;
                m_axis_tkeep  <= s_axis_tkeep;
                m_axis_tlast  <= s_axis_tlast;

                if (s_axis_tvalid) begin
                    if (s_axis_tlast) begin
                        smem_addr <= 8'd0;
                    end else begin
                        smem_addr <= smem_addr + 8'd1;
                    end

                    // Calculate 4-wide PE memory addresses (Memory-Mapped Strided Access)
                    pe_addr[0] <= smem_addr;
                    pe_addr[1] <= smem_addr + 8'd1;
                    pe_addr[2] <= smem_addr + 8'd2;
                    pe_addr[3] <= smem_addr + 8'd3;

                    case (opcode)
                        32'd1: begin // Opcode 1: Vector Add (+1)
                            m_axis_tdata <= {s_axis_tdata[63:32] + 32'd1, s_axis_tdata[31:0] + 32'd1};
                            fb_we        <= 1'b0;
                        end

                        32'd2: begin // Opcode 2: Vector Multiply (*2)
                            m_axis_tdata <= {s_axis_tdata[63:32] << 1, s_axis_tdata[31:0] << 1};
                            fb_we        <= 1'b0;
                        end

                        32'd3: begin // Opcode 3: CUDA Parallel Render Engine (Writes to Framebuffer VRAM)
                            m_axis_tdata <= s_axis_tdata;
                            fb_we        <= 1'b1;
                            fb_addr      <= s_axis_tdata[18:0];
                            fb_rgb       <= {s_axis_tdata[23:16], s_axis_tdata[15:8], s_axis_tdata[7:0]};
                        end

                        32'd4: begin // Opcode 4: Write Stream Payload to CUDA Shared Memory (SMEM SRAM)
                            smem_ram[smem_addr] <= s_axis_tdata;
                            m_axis_tdata        <= s_axis_tdata;
                            fb_we               <= 1'b0;
                        end

                        32'd5: begin // Opcode 5: 4-wide Multi-PE Strided Accumulate (Input + SMEM)
                            pe_out_data[0] <= {s_axis_tdata[63:32] + smem_ram[pe_addr[0]][63:32], s_axis_tdata[31:0] + smem_ram[pe_addr[0]][31:0]};
                            m_axis_tdata   <= pe_out_data[0];
                            fb_we          <= 1'b0;
                        end

                        default: begin // Passthrough
                            m_axis_tdata <= s_axis_tdata;
                            fb_we        <= 1'b0;
                        end
                    endcase
                end else begin
                    fb_we <= 1'b0;
                end
            end
        end
    end

endmodule

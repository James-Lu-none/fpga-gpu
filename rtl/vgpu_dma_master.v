`timescale 1ns / 1ps
// deprecated as XDMA IP handles DMA requests now
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/20
// Design Name: vGPU Core
// Module Name: vgpu_dma_master
// Project Name: fpga-gpu
// Target Devices: Xilinx Artix-7 (XC7A200T-2FBG484)
// Tool Versions: Vivado 2026+
// Description: 
//   AXI4-Full Master for Host Memory DMA Access with Streaming Burst Pipeline
//   Sequence:
//     1. Fetch Command from Host Ring Buffer (cmds[head])
//     2. Dynamic Burst Length calculation from cmd_payload_size
//     3. Page Table Walk (Mode 1: Scatter-Gather) or Direct Address (Mode 0)
//     4. AXI4 Read Burst: Stream payload data into Compute Core SIMD pipeline
//     5. Stream Buffer captures computed results at wire speed
//     6. AXI4 Write Burst: Write result data back to Host RAM (In-place)
//     7. Update ring->head with 32-bit WSTRB protection
//     8. Assert task_done_irq (PCIe MSI interrupt to CPU)
//////////////////////////////////////////////////////////////////////////////////

module vgpu_dma_master #(
    parameter integer C_M_AXI_ADDR_WIDTH = 64,
    parameter integer C_M_AXI_DATA_WIDTH = 64
)(
    input  wire                          m_axi_aclk,
    input  wire                          m_axi_aresetn,

    // Control from Registers
    input  wire                          start_doorbell,
    input  wire [63:0]                   ring_base_addr,
    input  wire [63:0]                   pt_base_addr,
    input  wire [31:0]                   uvm_mode,
    output reg                           task_done_irq,

    // AXI4 Master - Read Address Channel
    output reg  [C_M_AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output reg  [7:0]                    m_axi_arlen,
    output wire [2:0]                    m_axi_arsize,
    output wire [1:0]                    m_axi_arburst,
    output reg                           m_axi_arvalid,
    input  wire                          m_axi_arready,

    // AXI4 Master - Read Data Channel
    input  wire [C_M_AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [1:0]                    m_axi_rresp,
    input  wire                          m_axi_rlast,
    input  wire                          m_axi_rvalid,
    output reg                           m_axi_rready,

    // AXI4 Master - Write Address Channel
    output reg  [C_M_AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output reg  [7:0]                    m_axi_awlen,
    output wire [2:0]                    m_axi_awsize,
    output wire [1:0]                    m_axi_awburst,
    output reg                           m_axi_awvalid,
    input  wire                          m_axi_awready,

    // AXI4 Master - Write Data Channel
    output reg  [C_M_AXI_DATA_WIDTH-1:0] m_axi_wdata,
    output reg  [7:0]                    m_axi_wstrb,
    output reg                           m_axi_wlast,
    output reg                           m_axi_wvalid,
    input  wire                          m_axi_wready,

    // AXI4 Master - Write Response Channel
    input  wire [1:0]                    m_axi_bresp,
    input  wire                          m_axi_bvalid,
    output reg                           m_axi_bready
);

    assign m_axi_arsize  = 3'b011; // 8 bytes (64-bit)
    assign m_axi_arburst = 2'b01;  // INCR burst
    assign m_axi_awsize  = 3'b011; // 8 bytes (64-bit)
    assign m_axi_awburst = 2'b01;  // INCR burst

    // FSM State Definitions
    localparam [3:0] S_IDLE            = 4'd0;
    localparam [3:0] S_RD_CMD_ADDR     = 4'd1;
    localparam [3:0] S_RD_CMD_DATA     = 4'd2;
    localparam [3:0] S_RD_PTE_ADDR     = 4'd3; // Mode 1: Request Page Table Entry
    localparam [3:0] S_RD_PTE_DATA     = 4'd4; // Mode 1: Read Physical Page Base Address
    localparam [3:0] S_RD_PAYLOAD_ADDR = 4'd5; // Request Payload Burst Read
    localparam [3:0] S_RD_PAYLOAD_DATA = 4'd6; // Stream Payload Data -> Compute Core
    localparam [3:0] S_WAIT_COMPUTE    = 4'd7; // Flush Compute Pipeline into Stream Buffer
    localparam [3:0] S_WR_RES_ADDR     = 4'd8; // Request Payload Burst Write
    localparam [3:0] S_WR_RES_DATA     = 4'd9; // Stream Result Data from Buffer -> PCIe
    localparam [3:0] S_WR_RES_RESP     = 4'd10;
    localparam [3:0] S_WR_HEAD_ADDR    = 4'd11; // Request Update Head
    localparam [3:0] S_WR_HEAD_DATA    = 4'd12; // Write Update Head (Protected WSTRB)
    localparam [3:0] S_WR_HEAD_RESP    = 4'd13;

    reg [3:0]   state;
    reg [31:0]  current_head;
    reg [31:0]  cmd_opcode;
    reg [31:0]  cmd_payload_size;
    reg [63:0]  cmd_payload_vaddr;
    reg [7:0]   payload_burst_len;
    reg [63:0]  final_payload_addr;

    // Streaming Buffer & Counters (256 entries x 64-bit = 2KB Burst Buffer)
    (* ram_style = "block" *) reg [63:0] stream_buf [0:255];
    reg [8:0]   rd_beat_cnt;
    reg [8:0]   wr_stream_cnt;
    reg [7:0]   tx_beat_cnt;

    // Compute Core Signals
    reg [63:0]  compute_in_buf;
    wire[63:0]  compute_out_buf;
    reg         compute_valid_in;
    wire        compute_valid_out;

    // Compute Core Sub-module Instance (1-cycle latency pipeline)
    vgpu_compute_core u_core (
        .clk       (m_axi_aclk),
        .rst_n     (m_axi_aresetn),
        .opcode    (cmd_opcode),
        .valid_in  (compute_valid_in),
        .data_in   (compute_in_buf),
        .valid_out (compute_valid_out),
        .data_out  (compute_out_buf)
    );

    // Capture computed results from Compute Core into Stream Buffer
    always @(posedge m_axi_aclk) begin
        if (!m_axi_aresetn) begin
            wr_stream_cnt <= 9'd0;
        end else begin
            if (state == S_RD_PAYLOAD_ADDR) begin
                wr_stream_cnt <= 9'd0;
            end else if (compute_valid_out) begin
                stream_buf[wr_stream_cnt[7:0]] <= compute_out_buf;
                wr_stream_cnt <= wr_stream_cnt + 1'b1;
            end
        end
    end

    // Main AXI Master State Machine
    always @(posedge m_axi_aclk) begin
        if (!m_axi_aresetn) begin
            state              <= S_IDLE;
            current_head       <= 32'd0;
            task_done_irq      <= 1'b0;
            m_axi_araddr       <= 64'd0;
            m_axi_arlen        <= 8'd0;
            m_axi_arvalid      <= 1'b0;
            m_axi_rready       <= 1'b0;
            m_axi_awaddr       <= 64'd0;
            m_axi_awlen        <= 8'd0;
            m_axi_awvalid      <= 1'b0;
            m_axi_wdata        <= 64'd0;
            m_axi_wstrb        <= 8'hFF;
            m_axi_wvalid       <= 1'b0;
            m_axi_wlast        <= 1'b0;
            m_axi_bready       <= 1'b0;
            compute_valid_in   <= 1'b0;
            compute_in_buf     <= 64'd0;
            cmd_opcode         <= 32'd0;
            cmd_payload_size   <= 32'd0;
            cmd_payload_vaddr  <= 64'd0;
            payload_burst_len  <= 8'd0;
            final_payload_addr <= 64'd0;
            rd_beat_cnt        <= 9'd0;
            tx_beat_cnt        <= 8'd0;
        end else begin
            task_done_irq    <= 1'b0;
            compute_valid_in <= 1'b0;

            case (state)
                // -------------------------------------------------------------
                // S_IDLE: Wait for Doorbell write from Host Driver
                // -------------------------------------------------------------
                S_IDLE: begin
                    m_axi_wstrb <= 8'hFF;
                    if (start_doorbell) begin
                        // Fetch command from Host Ring Buffer: ring_base_addr + 8 + head*16
                        m_axi_araddr  <= ring_base_addr + 64'd8 + (current_head * 64'd16);
                        m_axi_arlen   <= 8'd1; // 2 beats = 16 bytes (128-bit command struct)
                        m_axi_arvalid <= 1'b1;
                        state         <= S_RD_CMD_ADDR;
                    end
                end

                // -------------------------------------------------------------
                // S_RD_CMD_ADDR & S_RD_CMD_DATA: Fetch 128-bit Command Struct
                // -------------------------------------------------------------
                S_RD_CMD_ADDR: begin
                    if (m_axi_arready && m_axi_arvalid) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1;
                        state         <= S_RD_CMD_DATA;
                    end
                end

                S_RD_CMD_DATA: begin
                    if (m_axi_rvalid) begin
                        if (!m_axi_rlast) begin
                            // Beat 0: opcode (lower 32-bit) + payload_size (upper 32-bit)
                            cmd_opcode       <= m_axi_rdata[31:0];
                            cmd_payload_size <= m_axi_rdata[63:32];

                            // Dynamic Burst Length Calculation:
                            // len = ceil(payload_size / 8) - 1, capped between 0 and 255 (2KB)
                            if (m_axi_rdata[63:32] <= 32'd8) begin
                                payload_burst_len <= 8'd0; // 1 beat (8 Bytes)
                            end else if (m_axi_rdata[63:32] >= 32'd2048) begin
                                payload_burst_len <= 8'd255; // 256 beats (2048 Bytes = 2KB max AXI burst)
                            end else begin
                                payload_burst_len <= ((m_axi_rdata[63:32] + 32'd7) >> 3) - 1'b1;
                            end
                        end else begin
                            // Beat 1: payload_vaddr (64-bit virtual address)
                            cmd_payload_vaddr <= m_axi_rdata;
                            m_axi_rready      <= 1'b0;

                            if (uvm_mode[0]) begin
                                // Mode 1 (Scatter-Gather):
                                // PTE physical address = pt_base_addr + (VPN * 8)
                                m_axi_araddr  <= pt_base_addr + ({42'd0, m_axi_rdata[31:12]} << 3);
                                m_axi_arlen   <= 8'd0; // Read 1 page table entry (64-bit)
                                m_axi_arvalid <= 1'b1;
                                state         <= S_RD_PTE_ADDR;
                            end else begin
                                // Mode 0 (Contiguous IOVA): pt_base_addr is direct physical address
                                final_payload_addr <= pt_base_addr;
                                m_axi_araddr       <= pt_base_addr;
                                m_axi_arlen        <= payload_burst_len;
                                m_axi_arvalid      <= 1'b1;
                                state              <= S_RD_PAYLOAD_ADDR;
                            end
                        end
                    end
                end

                // -------------------------------------------------------------
                // S_RD_PTE_ADDR & S_RD_PTE_DATA: Mode 1 Page Table Walk
                // -------------------------------------------------------------
                S_RD_PTE_ADDR: begin
                    if (m_axi_arready && m_axi_arvalid) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1;
                        state         <= S_RD_PTE_DATA;
                    end
                end

                S_RD_PTE_DATA: begin
                    if (m_axi_rvalid) begin
                        // rdata is the physical page base address. Add page offset [11:0]
                        final_payload_addr <= m_axi_rdata + {52'd0, cmd_payload_vaddr[11:0]};
                        m_axi_rready       <= 1'b0;
                        
                        // Issue Payload Burst Read
                        m_axi_araddr       <= m_axi_rdata + {52'd0, cmd_payload_vaddr[11:0]};
                        m_axi_arlen        <= payload_burst_len;
                        m_axi_arvalid      <= 1'b1;
                        state              <= S_RD_PAYLOAD_ADDR;
                    end
                end

                // -------------------------------------------------------------
                // S_RD_PAYLOAD_ADDR & S_RD_PAYLOAD_DATA: Streaming Burst Read
                // -------------------------------------------------------------
                S_RD_PAYLOAD_ADDR: begin
                    // wr_stream_cnt will be reseted here and ready to accept streaming pipeline
                    if (m_axi_arready && m_axi_arvalid) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1; // Open stream pipe
                        rd_beat_cnt   <= 9'd0;
                        state         <= S_RD_PAYLOAD_DATA;
                    end
                end

                S_RD_PAYLOAD_DATA: begin
                    if (m_axi_rvalid) begin
                        // Feed 64-bit stream directly into Compute Core SIMD pipeline
                        compute_in_buf   <= m_axi_rdata;
                        compute_valid_in <= 1'b1;
                        rd_beat_cnt      <= rd_beat_cnt + 1'b1;

                        // keep reading the buffer until its last beat
                        // (update state on last beat)
                        if (m_axi_rlast) begin
                            m_axi_rready <= 1'b0; // Close read pipe
                            state        <= S_WAIT_COMPUTE;
                        end
                    end
                end

                // -------------------------------------------------------------
                // S_WAIT_COMPUTE: Wait 1 cycle for Compute Pipeline to complete
                // -------------------------------------------------------------
                S_WAIT_COMPUTE: begin
                    // Once all read beats have been computed and captured into stream_buf
                    if (wr_stream_cnt == rd_beat_cnt) begin
                        // Issue AXI Write Burst
                        m_axi_awaddr  <= final_payload_addr;
                        m_axi_awlen   <= payload_burst_len;
                        m_axi_awvalid <= 1'b1;
                        state         <= S_WR_RES_ADDR;
                    end
                end

                // -------------------------------------------------------------
                // S_WR_RES_ADDR & S_WR_RES_DATA: Streaming Burst Writeback
                // -------------------------------------------------------------
                S_WR_RES_ADDR: begin
                    if (m_axi_awready && m_axi_awvalid) begin
                        m_axi_awvalid <= 1'b0;
                        tx_beat_cnt   <= 8'd0;
                        m_axi_wdata   <= stream_buf[0];
                        m_axi_wstrb   <= 8'hFF;
                        m_axi_wvalid  <= 1'b1;
                        m_axi_wlast   <= (payload_burst_len == 8'd0);
                        state         <= S_WR_RES_DATA;
                    end
                end

                S_WR_RES_DATA: begin
                    if (m_axi_wready && m_axi_wvalid) begin
                        if (tx_beat_cnt == payload_burst_len) begin
                            m_axi_wvalid <= 1'b0;
                            m_axi_wlast  <= 1'b0;
                            m_axi_bready <= 1'b1;
                            state        <= S_WR_RES_RESP;
                        end else begin
                            tx_beat_cnt  <= tx_beat_cnt + 1'b1;
                            m_axi_wdata  <= stream_buf[tx_beat_cnt + 1'b1];
                            m_axi_wlast  <= (tx_beat_cnt + 1'b1 == payload_burst_len);
                            m_axi_wvalid <= 1'b1;
                        end
                    end
                end

                S_WR_RES_RESP: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 1'b0;
                        // Update Ring Buffer head index (Offset 0x00)
                        m_axi_awaddr  <= ring_base_addr;
                        m_axi_awlen   <= 8'd0;
                        m_axi_awvalid <= 1'b1;
                        state         <= S_WR_HEAD_ADDR;
                    end
                end

                // -------------------------------------------------------------
                // S_WR_HEAD_ADDR & S_WR_HEAD_DATA: Update Head with Protected WSTRB
                // -------------------------------------------------------------
                S_WR_HEAD_ADDR: begin
                    if (m_axi_awready && m_axi_awvalid) begin
                        m_axi_awvalid <= 1'b0;
                        current_head  <= (current_head + 1) % 256;
                        m_axi_wstrb   <= 8'h0F; // Write lower 4 bytes only (protects tail)
                        m_axi_wdata   <= {32'd0, (current_head + 1'b1)};
                        m_axi_wlast   <= 1'b1;
                        m_axi_wvalid  <= 1'b1;
                        state         <= S_WR_HEAD_DATA;
                    end
                end

                S_WR_HEAD_DATA: begin
                    if (m_axi_wready && m_axi_wvalid) begin
                        m_axi_wvalid <= 1'b0;
                        m_axi_wlast  <= 1'b0;
                        m_axi_bready <= 1'b1;
                        state        <= S_WR_HEAD_RESP;
                    end
                end

                S_WR_HEAD_RESP: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready  <= 1'b0;
                        task_done_irq <= 1'b1; // Fire MSI interrupt to CPU
                        state         <= S_IDLE;
                    end
                end

                default: begin
                    m_axi_wstrb <= 8'hFF;
                    state       <= S_IDLE;
                end
            endcase
        end
    end

endmodule

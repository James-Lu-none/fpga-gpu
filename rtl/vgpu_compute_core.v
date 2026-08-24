`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/22
// Design Name: vGPU Core
// Module Name: vgpu_compute_core
// Project Name: fpga-gpu
// Target Devices: Xilinx Artix-7 (XC7A200T-2FBG484)
// Tool Versions: Vivado 2026+
// Description: 
//   AXI4-Stream SIMD Vector Compute Core with CUDA Shared Memory (SMEM / RMEM)
//   Opcodes:
//     1: Vector Add (+1 to high/low 32-bit words)
//     2: Vector Multiply (*2 to high/low 32-bit words)
//     3: CUDA Parallel Render Engine (Outputs RGB pixel & Writes to Framebuffer)
//     4: SMEM Write (Store streaming payload into 256-word On-Chip SMEM SRAM)
//     5: SMEM Multi-Pass Accumulate (Output = Input + SMEM[index])
//     default: Passthrough
//////////////////////////////////////////////////////////////////////////////////

module vgpu_compute_core #(
    parameter integer C_AXIS_DATA_WIDTH = 64
)(
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire [31:0]                       opcode,

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
    // CUDA Shared Memory (SMEM / Scratchpad SRAM Array: 256 x 64-bit words)
    // ---------------------------------------------------------------------
    reg [63:0] smem_ram [0:255];
    reg [7:0]  smem_addr;

    // Pass-through ready with pipeline register backpressure support
    assign s_axis_tready = m_axis_tready || ~m_axis_tvalid;

    always @(posedge clk) begin
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
                    // Auto-increment or reset SMEM Address Index
                    if (s_axis_tlast) begin
                        smem_addr <= 8'd0;
                    end else begin
                        smem_addr <= smem_addr + 8'd1;
                    end

                    case (opcode)
                        32'd1: begin // Vector Add 1
                            m_axis_tdata <= {s_axis_tdata[63:32] + 32'd1, s_axis_tdata[31:0] + 32'd1};
                            fb_we        <= 1'b0;
                        end

                        32'd2: begin // Vector Mul 2
                            m_axis_tdata <= {s_axis_tdata[63:32] << 1, s_axis_tdata[31:0] << 1};
                            fb_we        <= 1'b0;
                        end

                        32'd3: begin // CUDA Parallel Render Engine (Calculates Pixel RGB & Address)
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

                        32'd5: begin // Opcode 5: Multi-Pass Accumulate (Input + SMEM[smem_addr])
                            m_axis_tdata <= {
                                s_axis_tdata[63:32] + smem_ram[smem_addr][63:32],
                                s_axis_tdata[31:0]  + smem_ram[smem_addr][31:0]
                            };
                            fb_we <= 1'b0;
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

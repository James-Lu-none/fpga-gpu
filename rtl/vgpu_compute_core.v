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
//   AXI4-Stream SIMD Vector Compute Core for XDMA Stream Acceleration
//   Opcodes:
//     1: Vector Add (+1 to high/low 32-bit words)
//     2: Vector Multiply (*2 to high/low 32-bit words)
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
    output reg                               m_axis_tlast
);

    // Pass-through ready with pipeline register backpressure support
    assign s_axis_tready = m_axis_tready || ~m_axis_tvalid;

    always @(posedge clk) begin
        if (!rst_n) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= {C_AXIS_DATA_WIDTH{1'b0}};
            m_axis_tkeep  <= {(C_AXIS_DATA_WIDTH/8){1'b0}};
            m_axis_tlast  <= 1'b0;
        end else begin
            if (s_axis_tready) begin
                m_axis_tvalid <= s_axis_tvalid;
                m_axis_tkeep  <= s_axis_tkeep;
                m_axis_tlast  <= s_axis_tlast;

                if (s_axis_tvalid) begin
                    case (opcode)
                        32'd1: m_axis_tdata <= {s_axis_tdata[63:32] + 32'd1, s_axis_tdata[31:0] + 32'd1}; // Vector Add 1
                        32'd2: m_axis_tdata <= {s_axis_tdata[63:32] << 1,    s_axis_tdata[31:0] << 1};    // Vector Mul 2
                        default: m_axis_tdata <= s_axis_tdata; // Passthrough
                    endcase
                end
            end
        end
    end

endmodule

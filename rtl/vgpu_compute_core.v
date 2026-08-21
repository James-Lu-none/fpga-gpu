`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/20
// Design Name: vGPU Core
// Module Name: vgpu_compute_core
// Project Name: fpga-gpu
// Target Devices: Xilinx Artix-7 (XC7A200T-2FBG484)
// Tool Versions: Vivado 2026+
// Description: 
//   GPU Vector Compute Pipeline
//   Opcodes:
//     1: Vector Add (+1 to high/low 32-bit words)
//     2: Vector Multiply (*2 to high/low 32-bit words)
//     default: Passthrough
//////////////////////////////////////////////////////////////////////////////////

module vgpu_compute_core (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] opcode,
    input  wire        valid_in,
    input  wire [63:0] data_in,
    output reg         valid_out,
    output reg  [63:0] data_out
);

    always @(posedge clk) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            data_out  <= 64'd0;
        end else begin
            valid_out <= valid_in;
            if (valid_in) begin
                case (opcode)
                    32'd1: data_out <= {data_in[63:32] + 32'd1, data_in[31:0] + 32'd1}; // Vector Add 1
                    32'd2: data_out <= {data_in[63:32] << 1, data_in[31:0] << 1};       // Vector Mul 2
                    default: data_out <= data_in; // Passthrough
                endcase
            end
        end
    end

endmodule

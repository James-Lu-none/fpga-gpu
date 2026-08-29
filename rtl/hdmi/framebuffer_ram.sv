// GPU Framebuffer Dual-Port Video RAM (VRAM) Module
// Seamlessly bridges GPU SIMD Compute Core Render Output to HDMI Display Pipeline

`timescale 1ns / 1ps

module framebuffer_ram #(
    parameter H_RES = 640, // Resolution Width (640x480 On-chip Framebuffer)
    parameter V_RES = 480, // Resolution Height
    parameter DATA_WIDTH = 24 // 24-bit RGB Color (8-bit R, 8-bit G, 8-bit B)
)(
    // Port A: GPU SIMD Core Write Port (System Clock Domain)
    input wire clk_gpu,
    input wire we_gpu,
    input wire [18:0] addr_gpu, // H_RES * V_RES address
    input wire [DATA_WIDTH-1:0] din_gpu,

    // Port B: HDMI Display Read Port (Pixel Clock Domain)
    input wire clk_pix,
    input wire [18:0] addr_pix,
    output reg [DATA_WIDTH-1:0] dout_pix
);

    // Memory array for Framebuffer (640x480 = 307,200 x 24-bit pixels)
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] vram [0:(H_RES * V_RES)-1];

    // Port A Write (GPU Engine)
    always @(posedge clk_gpu) begin
        if (we_gpu) begin
            vram[addr_gpu] <= din_gpu;
        end
    end

    // Port B Read (HDMI Output)
    always @(posedge clk_pix) begin
        dout_pix <= vram[addr_pix];
    end

endmodule

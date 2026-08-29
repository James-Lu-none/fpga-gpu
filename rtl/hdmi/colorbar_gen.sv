// HDMI Colorbar Generator (8-Bar Standard Color Patterns for Testing)

`timescale 1ns / 1ps

module colorbar_gen #(
    parameter H_ACTIVE = 12'd1920
)(
    input wire clk_pix,
    input wire rst_n,
    input wire video_de,
    input wire [11:0] pixel_x,
    input wire [11:0] pixel_y,

    output reg [23:0] rgb_data // 24-bit RGB (R[23:16], G[15:8], B[7:0])
);

    // Calculate bar width (1920 / 8 = 240 pixels per bar)
    wire [11:0] bar_width = H_ACTIVE >> 3;

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            rgb_data <= 24'h000000;
        end else if (video_de) begin
            case (pixel_x / bar_width)
                3'd0: rgb_data <= 24'hFFFFFF; // White
                3'd1: rgb_data <= 24'hFFFF00; // Yellow
                3'd2: rgb_data <= 24'h00FFFF; // Cyan
                3'd3: rgb_data <= 24'h00FF00; // Green
                3'd4: rgb_data <= 24'hFF00FF; // Magenta
                3'd5: rgb_data <= 24'hFF0000; // Red
                3'd6: rgb_data <= 24'h0000FF; // Blue
                3'd7: rgb_data <= 24'h000000; // Black
                default: rgb_data <= 24'h000000;
            endcase
        end else begin
            rgb_data <= 24'h000000;
        end
    end

endmodule

// =========================================================================
// HDMI Video Timing Generator (Default: 1080P @ 60Hz, 148.5MHz Pixel Clock)
// =========================================================================

`timescale 1ns / 1ps

module hdmi_timing_gen #(
    // CEA-861 Standard 1080P @ 60Hz Timing Parameters
    parameter H_ACTIVE = 12'd1920,
    parameter H_FP     = 12'd88,
    parameter H_SYNC   = 12'd44,
    parameter H_BP     = 12'd148,
    parameter H_TOTAL  = 12'd2200,

    parameter V_ACTIVE = 12'd1080,
    parameter V_FP     = 12'd4,
    parameter V_SYNC   = 12'd5,
    parameter V_BP     = 12'd36,
    parameter V_TOTAL  = 12'd1125,

    // Sync Polarity (1 = Active High, 0 = Active Low)
    parameter H_POLARITY = 1'b1,
    parameter V_POLARITY = 1'b1
)(
    input  wire        clk_pix,     // Pixel Clock (148.5MHz for 1080p, 74.25MHz for 720p)
    input  wire        rst_n,       // Active Low Async Reset

    output reg         video_hs,    // Horizontal Sync
    output reg         video_vs,    // Vertical Sync
    output reg         video_de,    // Data Enable (Active Video Area)
    output reg  [11:0] pixel_x,     // Active Pixel X coordinate (0 ~ 1919)
    output reg  [11:0] pixel_y      // Active Pixel Y coordinate (0 ~ 1079)
);

    // Pixel and Line Counters
    reg [11:0] h_cnt;
    reg [11:0] v_cnt;

    // Horizontal Counter
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n)
            h_cnt <= 12'd0;
        else if (h_cnt == H_TOTAL - 1'b1)
            h_cnt <= 12'd0;
        else
            h_cnt <= h_cnt + 1'b1;
    end

    // Vertical Counter
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n)
            v_cnt <= 12'd0;
        else if (h_cnt == H_TOTAL - 1'b1) begin
            if (v_cnt == V_TOTAL - 1'b1)
                v_cnt <= 12'd0;
            else
                v_cnt <= v_cnt + 1'b1;
        end
    end

    // HSYNC Signal Generation
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n)
            video_hs <= !H_POLARITY;
        else if (h_cnt >= (H_ACTIVE + H_FP) && h_cnt < (H_ACTIVE + H_FP + H_SYNC))
            video_hs <= H_POLARITY;
        else
            video_hs <= !H_POLARITY;
    end

    // VSYNC Signal Generation
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n)
            video_vs <= !V_POLARITY;
        else if (v_cnt >= (V_ACTIVE + V_FP) && v_cnt < (V_ACTIVE + V_FP + V_SYNC))
            video_vs <= V_POLARITY;
        else
            video_vs <= !V_POLARITY;
    end

    // DE (Data Enable) Active Area Signal Generation
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n)
            video_de <= 1'b0;
        else if ((h_cnt < H_ACTIVE) && (v_cnt < V_ACTIVE))
            video_de <= 1'b1;
        else
            video_de <= 1'b0;
    end

    // Pixel X and Y Coordinates
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            pixel_x <= 12'd0;
            pixel_y <= 12'd0;
        end else if (video_de) begin
            pixel_x <= h_cnt;
            pixel_y <= v_cnt;
        end else begin
            pixel_x <= 12'd0;
            pixel_y <= 12'd0;
        end
    end

endmodule

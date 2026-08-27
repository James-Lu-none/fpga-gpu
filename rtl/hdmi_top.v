// =========================================================================
// HDMI Top Module for SiI9134 HDMI Transmitter (ALINX AX7A200B)
// Integrates Clock Generation, Video Timing, Colorbar Test, and I2C Config
// =========================================================================

`timescale 1ns / 1ps

module hdmi_top (
    input  wire        sys_clk_125m, // 125MHz AXI System Clock
    input  wire        rst_n,        // Active Low System Reset

    // SiI9134 HDMI Physical Interface
    output wire        hdmi_nreset,  // Active Low Hardware Reset for SiI9134
    output wire        hdmi_clk,     // Video Pixel Clock to SiI9134
    output wire        hdmi_hs,      // Horizontal Sync
    output wire        hdmi_vs,      // Vertical Sync
    output wire        hdmi_de,      // Data Enable
    output wire [23:0] hdmi_d,       // 24-bit RGB Data (D[23:0])

    // SiI9134 I2C Configuration Ports
    inout  wire        hdmi_scl,
    inout  wire        hdmi_sda,

    output wire        hdmi_init_done
);

    // Hold SiI9134 hardware reset high (normal operation)
    assign hdmi_nreset = rst_n;

    // -------------------------------------------------------------------------
    // Pixel Clock Generation (125MHz -> 148.5MHz using MMCME2_BASE)
    // -------------------------------------------------------------------------
    wire clk_pix;
    wire clk_fb;
    wire locked;

    // MMCME2_BASE: 125MHz * 7.125 / 6.0 = 148.4375MHz (VCO = 890.625MHz within 600-1440MHz range)
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(7.125),
        .CLKFBOUT_PHASE(0.0),
        .CLKIN1_PERIOD(8.0),        // 125MHz = 8.0ns period
        .CLKOUT0_DIVIDE_F(6.0),     // 890.625 / 6.0 = 148.4375MHz (~148.5MHz 1080P60)
        .CLKOUT0_PHASE(0.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .DIVCLK_DIVIDE(1)
    ) u_mmcm_pixclk (
        .CLKOUT0(clk_pix),
        .CLKOUT0B(),
        .CLKOUT1(),
        .CLKOUT1B(),
        .CLKOUT2(),
        .CLKOUT2B(),
        .CLKOUT3(),
        .CLKOUT3B(),
        .CLKOUT4(),
        .CLKOUT5(),
        .CLKOUT6(),
        .CLKFBOUT(clk_fb),
        .CLKFBOUTB(),
        .CLKIN1(sys_clk_125m),
        .PWRDWN(1'b0),
        .RST(!rst_n),
        .CLKFBIN(clk_fb),
        .LOCKED(locked)
    );

    assign hdmi_clk = clk_pix;

    // Internal Reset for HDMI timing (synchronous to pixel clock)
    // Source: u_xdma/inst/xdma_0_pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/user_reset_out_reg/C
    // Dest: u_hdmi/clk_pix_rst_n_reg/CLR
    // 
    // [Reset Synchronizer (Reset Bridge)]
    // Because rst_n (from PCIe userclk) and clk_pix (from MMCME2) are asynchronous to each other,
    // directly routing rst_n to the logic clocked by clk_pix can cause timing violations (Recovery time failures)
    // and metastability when the reset is released exactly at the clock edge.
    // We use a 2-stage cascaded flip-flop to safely cross the reset into the clk_pix domain.
    // The (* ASYNC_REG = "TRUE" *) attribute tells Vivado that these are synchronizer registers,
    // ensuring they are placed very close together in the FPGA slice to minimize routing delay 
    // and resolve metastability quickly.
    (* ASYNC_REG = "TRUE" *) reg [1:0] clk_pix_rst_sync;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n)
            clk_pix_rst_sync <= 2'b00; // Asynchronous assertion
        else
            // after rst_n goes high, clk_pix_rst_sync:
            // 00: Initial State
            // 01: after first pixel clk posedge when locked (pixel clk stable)
            // 11: after second pixel clk posedge when locked
            // we purpose delay one more pixel clk period to release reset
            // so it is safer, avoid metastability.
            clk_pix_rst_sync <= {clk_pix_rst_sync[0], locked}; // Synchronous release
    end
    wire clk_pix_rst_n = clk_pix_rst_sync[1];

    // -------------------------------------------------------------------------
    // Video Timing Generator
    // -------------------------------------------------------------------------
    wire        video_hs;
    wire        video_vs;
    wire        video_de;
    wire [11:0] pixel_x;
    wire [11:0] pixel_y;

    hdmi_timing_gen #(
        .H_ACTIVE(12'd1920),
        .H_FP(12'd88),
        .H_SYNC(12'd44),
        .H_BP(12'd148),
        .H_TOTAL(12'd2200),
        .V_ACTIVE(12'd1080),
        .V_FP(12'd4),
        .V_SYNC(12'd5),
        .V_BP(12'd36),
        .V_TOTAL(12'd1125)
    ) u_timing_gen (
        .clk_pix(clk_pix),
        .rst_n(clk_pix_rst_n),
        .video_hs(video_hs),
        .video_vs(video_vs),
        .video_de(video_de),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y)
    );

    assign hdmi_hs = video_hs;
    assign hdmi_vs = video_vs;
    assign hdmi_de = video_de;

    // -------------------------------------------------------------------------
    // Colorbar Generator (Default HDMI Output Test Pattern)
    // -------------------------------------------------------------------------
    hdmi_colorbar_gen #(
        .H_ACTIVE(12'd1920)
    ) u_colorbar_gen (
        .clk_pix(clk_pix),
        .rst_n(clk_pix_rst_n),
        .video_de(video_de),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),
        .rgb_data(hdmi_d)
    );

    // -------------------------------------------------------------------------
    // SiI9134 I2C Hardware Initializer
    // -------------------------------------------------------------------------
    hdmi_i2c_init #(
        .CLK_FREQ_HZ(125_000_000),
        .I2C_FREQ_HZ(100_000)
    ) u_i2c_init (
        .clk(sys_clk_125m),
        .rst_n(rst_n),
        .i2c_scl(hdmi_scl),
        .i2c_sda(hdmi_sda),
        .init_done(hdmi_init_done)
    );

endmodule

// =========================================================================
// SiI9134 HDMI Transmitter Hardware I2C Master Initializer
// Configures SiI9134 (I2C Address 0x72) for RGB444 24-bit Video Output
// =========================================================================

`timescale 1ns / 1ps

module hdmi_i2c_init #(
    parameter CLK_FREQ_HZ = 125_000_000,  // Input system clock frequency (e.g. 125MHz AXI clock)
    parameter I2C_FREQ_HZ = 100_000       // I2C SCL clock frequency (100kHz standard mode)
)(
    input  wire clk,
    input  wire rst_n,

    inout  wire i2c_scl,
    inout  wire i2c_sda,

    output reg  init_done
);

    // SiI9134 I2C Address (7-bit 0x39 -> 8-bit write address 0x72)
    localparam SLAVE_ADDR = 8'h72;
    localparam NUM_REGS   = 6;

    // Register lookup table: {Register Address, Value}
    reg [15:0] reg_lut [0:NUM_REGS-1];
    initial begin
        reg_lut[0] = 16'h08_35; // Power Control: Normal Power On
        reg_lut[1] = 16'h05_00; // Reset / System Control
        reg_lut[2] = 16'h09_00; // Input Video Format: 24-bit RGB 4:4:4
        reg_lut[3] = 16'h0A_00; // Clock edge & Sync polarity
        reg_lut[4] = 16'h3C_01; // Enable HDMI Output Mode
        reg_lut[5] = 16'h08_35; // Re-verify Power State
    end

    // I2C Timing Divider (125MHz / (4 * 100kHz) = 312.5 ticks per state)
    localparam DIV_MAX = CLK_FREQ_HZ / (I2C_FREQ_HZ * 4);
    reg [15:0] div_cnt;
    reg        i2c_tick;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt  <= 16'd0;
            i2c_tick <= 1'b0;
        end else if (div_cnt == DIV_MAX - 1) begin
            div_cnt  <= 16'd0;
            i2c_tick <= 1'b1;
        end else begin
            div_cnt  <= div_cnt + 1'b1;
            i2c_tick <= 1'b0;
        end
    end

    // Open-drain I2C Tristate Drivers
    reg scl_out, sda_out;
    assign i2c_scl = scl_out ? 1'bz : 1'b0;
    assign i2c_sda = sda_out ? 1'bz : 1'b0;

    // State Machine
    localparam ST_IDLE  = 4'd0,
               ST_START = 4'd1,
               ST_ADDR  = 4'd2,
               ST_ACK1  = 4'd3,
               ST_REG   = 4'd4,
               ST_ACK2  = 4'd5,
               ST_VAL   = 4'd6,
               ST_ACK3  = 4'd7,
               ST_STOP  = 4'd8,
               ST_DONE  = 4'd9;

    reg [3:0] state;
    reg [2:0] reg_idx;
    reg [3:0] bit_cnt;
    reg [7:0] tx_byte;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            reg_idx   <= 3'd0;
            bit_cnt   <= 4'd0;
            scl_out   <= 1'b1;
            sda_out   <= 1'b1;
            init_done <= 1'b0;
        end else if (i2c_tick) begin
            case (state)
                ST_IDLE: begin
                    scl_out <= 1'b1;
                    sda_out <= 1'b1;
                    if (reg_idx < NUM_REGS) begin
                        state <= ST_START;
                    end else begin
                        init_done <= 1'b1;
                        state     <= ST_DONE;
                    end
                end

                ST_START: begin
                    sda_out <= 1'b0;
                    tx_byte <= SLAVE_ADDR;
                    bit_cnt <= 4'd7;
                    state   <= ST_ADDR;
                end

                ST_ADDR: begin
                    scl_out <= 1'b0;
                    sda_out <= tx_byte[bit_cnt];
                    if (bit_cnt == 0) begin
                        state <= ST_ACK1;
                    end else begin
                        bit_cnt <= bit_cnt - 1'b1;
                    end
                end

                ST_ACK1: begin
                    scl_out <= 1'b1;
                    sda_out <= 1'b1; // Release SDA for ACK
                    tx_byte <= reg_lut[reg_idx][15:8]; // Reg Address
                    bit_cnt <= 4'd7;
                    state   <= ST_REG;
                end

                ST_REG: begin
                    scl_out <= 1'b0;
                    sda_out <= tx_byte[bit_cnt];
                    if (bit_cnt == 0) begin
                        state <= ST_ACK2;
                    end else begin
                        bit_cnt <= bit_cnt - 1'b1;
                    end
                end

                ST_ACK2: begin
                    scl_out <= 1'b1;
                    sda_out <= 1'b1;
                    tx_byte <= reg_lut[reg_idx][7:0]; // Reg Value
                    bit_cnt <= 4'd7;
                    state   <= ST_VAL;
                end

                ST_VAL: begin
                    scl_out <= 1'b0;
                    sda_out <= tx_byte[bit_cnt];
                    if (bit_cnt == 0) begin
                        state <= ST_ACK3;
                    end else begin
                        bit_cnt <= bit_cnt - 1'b1;
                    end
                end

                ST_ACK3: begin
                    scl_out <= 1'b1;
                    sda_out <= 1'b1;
                    state   <= ST_STOP;
                end

                ST_STOP: begin
                    scl_out <= 1'b1;
                    sda_out <= 1'b1;
                    reg_idx <= reg_idx + 1'b1;
                    state   <= ST_IDLE;
                end

                ST_DONE: begin
                    init_done <= 1'b1;
                    scl_out   <= 1'b1;
                    sda_out   <= 1'b1;
                end
            endcase
        end
    end

endmodule

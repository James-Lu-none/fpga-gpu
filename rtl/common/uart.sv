`timescale 1ns / 1ps

module uart #(
    parameter integer CLK_FREQ = 125000000,
    parameter integer BAUD_RATE = 115200
) (
    input wire clk,
    input wire rst_n,

    // AXI-Lite Slave Interface
    axi_lite_if.slave s_axi,

    // UART Physical Interface
    input wire rx,
    output wire tx
);
    localparam integer CLK_PER_BIT = CLK_FREQ / BAUD_RATE;

    // UART TX Logic
    reg [2:0] tx_state;
    reg [7:0] tx_data;
    reg [31:0] tx_clk_cnt;
    reg [2:0] tx_bit_cnt;
    reg tx_reg;
    reg tx_busy;
    
    wire tx_start;

    assign tx = tx_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state <= 0;
            tx_data <= 0;
            tx_clk_cnt <= 0;
            tx_bit_cnt <= 0;
            tx_reg <= 1'b1;
            tx_busy <= 1'b0;
        end else begin
            case (tx_state)
                0: begin // IDLE
                    tx_reg <= 1'b1;
                    tx_clk_cnt <= 0;
                    tx_bit_cnt <= 0;
                    if (tx_start) begin
                        tx_busy <= 1'b1;
                        tx_data <= s_axi.wdata[7:0];
                        tx_state <= 1; // START_BIT
                    end else begin
                        tx_busy <= 1'b0;
                    end
                end
                1: begin // START_BIT
                    tx_reg <= 1'b0;
                    if (tx_clk_cnt < CLK_PER_BIT - 1) begin
                        tx_clk_cnt <= tx_clk_cnt + 1;
                    end else begin
                        tx_clk_cnt <= 0;
                        tx_state <= 2; // DATA_BITS
                    end
                end
                2: begin // DATA_BITS
                    tx_reg <= tx_data[tx_bit_cnt];
                    if (tx_clk_cnt < CLK_PER_BIT - 1) begin
                        tx_clk_cnt <= tx_clk_cnt + 1;
                    end else begin
                        tx_clk_cnt <= 0;
                        if (tx_bit_cnt < 7) begin
                            tx_bit_cnt <= tx_bit_cnt + 1;
                        end else begin
                            tx_bit_cnt <= 0;
                            tx_state <= 3; // STOP_BIT
                        end
                    end
                end
                3: begin // STOP_BIT
                    tx_reg <= 1'b1;
                    if (tx_clk_cnt < CLK_PER_BIT - 1) begin
                        tx_clk_cnt <= tx_clk_cnt + 1;
                    end else begin
                        tx_clk_cnt <= 0;
                        tx_state <= 0; // IDLE
                    end
                end
            endcase
        end
    end

    // UART RX Logic (Simple oversampling)
    reg [2:0] rx_state;
    reg [31:0] rx_clk_cnt;
    reg [2:0] rx_bit_cnt;
    reg [7:0] rx_data;
    reg [7:0] rx_data_out;
    reg rx_valid;
    
    // Double FF sync
    reg rx_sync1, rx_sync2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= rx;
            rx_sync2 <= rx_sync1;
        end
    end

    wire rx_read_ack;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state <= 0;
            rx_clk_cnt <= 0;
            rx_bit_cnt <= 0;
            rx_data <= 0;
            rx_data_out <= 0;
            rx_valid <= 1'b0;
        end else begin
            if (rx_read_ack) rx_valid <= 1'b0;
            
            case (rx_state)
                0: begin // WAIT START BIT
                    rx_clk_cnt <= 0;
                    rx_bit_cnt <= 0;
                    if (rx_sync2 == 1'b0) begin
                        rx_state <= 1; // VERIFY START BIT (half bit time)
                    end
                end
                1: begin
                    if (rx_clk_cnt < (CLK_PER_BIT / 2) - 1) begin
                        rx_clk_cnt <= rx_clk_cnt + 1;
                    end else begin
                        if (rx_sync2 == 1'b0) begin // Still 0, valid start bit
                            rx_clk_cnt <= 0;
                            rx_state <= 2;
                        end else begin // Glitch
                            rx_state <= 0;
                        end
                    end
                end
                2: begin // READ DATA BITS
                    if (rx_clk_cnt < CLK_PER_BIT - 1) begin
                        rx_clk_cnt <= rx_clk_cnt + 1;
                    end else begin
                        rx_clk_cnt <= 0;
                        rx_data[rx_bit_cnt] <= rx_sync2;
                        if (rx_bit_cnt < 7) begin
                            rx_bit_cnt <= rx_bit_cnt + 1;
                        end else begin
                            rx_bit_cnt <= 0;
                            rx_state <= 3; // STOP BIT
                        end
                    end
                end
                3: begin // STOP BIT
                    if (rx_clk_cnt < CLK_PER_BIT - 1) begin
                        rx_clk_cnt <= rx_clk_cnt + 1;
                    end else begin
                        if (rx_sync2 == 1'b1) begin // Valid stop bit
                            rx_data_out <= rx_data;
                            rx_valid <= 1'b1;
                        end
                        rx_state <= 0;
                    end
                end
            endcase
        end
    end

    // AXI-Lite Slave Interface Logic
    // Memory Map:
    // 0x00: TX Data (Write-only, writes initiate transmission)
    // 0x04: RX Data (Read-only, reading clears rx_valid)
    // 0x08: Status (Bit 0: tx_busy, Bit 1: rx_valid)

    reg awready_reg;
    reg wready_reg;
    reg bvalid_reg;
    reg arready_reg;
    reg rvalid_reg;
    reg [31:0] rdata_reg;
    
    assign s_axi.awready = awready_reg;
    assign s_axi.wready = wready_reg;
    assign s_axi.bvalid = bvalid_reg;
    assign s_axi.bresp = 2'b00;
    assign s_axi.arready = arready_reg;
    assign s_axi.rvalid = rvalid_reg;
    assign s_axi.rdata = rdata_reg;
    assign s_axi.rresp = 2'b00;
    
    assign tx_start = (s_axi.awvalid && s_axi.wvalid && !awready_reg && !wready_reg && s_axi.awaddr[7:0] == 8'h00);
    assign rx_read_ack = (s_axi.arvalid && !arready_reg && s_axi.araddr[7:0] == 8'h04);

    // Write Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awready_reg <= 1'b0;
            wready_reg <= 1'b0;
            bvalid_reg <= 1'b0;
        end else begin
            if (s_axi.awvalid && s_axi.wvalid && !awready_reg && !wready_reg) begin
                awready_reg <= 1'b1;
                wready_reg <= 1'b1;
            end else begin
                awready_reg <= 1'b0;
                wready_reg <= 1'b0;
            end
            
            if (awready_reg && wready_reg && !bvalid_reg) begin
                bvalid_reg <= 1'b1;
            end else if (s_axi.bready && bvalid_reg) begin
                bvalid_reg <= 1'b0;
            end
        end
    end

    // Read Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arready_reg <= 1'b0;
            rvalid_reg <= 1'b0;
            rdata_reg <= 0;
        end else begin
            if (s_axi.arvalid && !arready_reg && !rvalid_reg) begin
                arready_reg <= 1'b1;
                rvalid_reg <= 1'b1;
                case (s_axi.araddr[7:0])
                    8'h04: rdata_reg <= {24'd0, rx_data_out};
                    8'h08: rdata_reg <= {30'd0, rx_valid, tx_busy};
                    default: rdata_reg <= 0;
                endcase
            end else begin
                arready_reg <= 1'b0;
                if (s_axi.rready && rvalid_reg) begin
                    rvalid_reg <= 1'b0;
                end
            end
        end
    end

endmodule

// RISC-V Block RAM Instruction & Data Memory (16KB Dual-Port RAM)
// Loads Firmware Image (firmware.hex) via $readmemh

`timescale 1ns / 1ps

module boot_ram #(
    parameter MEM_SIZE_BYTES = 16384 // 16KB Instruction + Data BRAM
)(
    input wire clk,
    input wire rst_n,

    // Port A (RISC-V Memory Interface)
    input wire en_a,
    input wire [3:0] we_a,
    input wire [13:0] addr_a, // 16KB = 4096 x 32-bit words (addr[13:2])
    input wire [31:0] din_a,
    output reg [31:0] dout_a,

    // Port B (Host PCIe XDMA Direct BRAM & Mailbox Interface)
    input wire en_b,
    input wire [3:0] we_b,
    input wire [13:0] addr_b,
    input wire [31:0] din_b,
    output reg [31:0] dout_b
);

    // 4096 x 32-bit RAM Array (16KB)
    reg [31:0] mem [0:(MEM_SIZE_BYTES/4)-1];

    // Port A Byte-wise Write & Read Operations (RISC-V CPU)
    always @(posedge clk) begin
        if (en_a) begin
            if (we_a[0]) mem[addr_a[13:2]][ 7: 0] <= din_a[ 7: 0];
            if (we_a[1]) mem[addr_a[13:2]][15: 8] <= din_a[15: 8];
            if (we_a[2]) mem[addr_a[13:2]][23:16] <= din_a[23:16];
            if (we_a[3]) mem[addr_a[13:2]][31:24] <= din_a[31:24];
            dout_a <= mem[addr_a[13:2]];
        end
    end

    // Port B Byte-wise Write & Read Operations (Host PCIe XDMA)
    always @(posedge clk) begin
        if (en_b) begin
            if (we_b[0]) mem[addr_b[13:2]][ 7: 0] <= din_b[ 7: 0];
            if (we_b[1]) mem[addr_b[13:2]][15: 8] <= din_b[15: 8];
            if (we_b[2]) mem[addr_b[13:2]][23:16] <= din_b[23:16];
            if (we_b[3]) mem[addr_b[13:2]][31:24] <= din_b[31:24];
            dout_b <= mem[addr_b[13:2]];
        end
    end

endmodule

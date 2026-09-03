`timescale 1ns / 1ps
// Generic AXI4-Lite 1-to-2 Decoder/Router
// Provides 0-cycle address routing.
// Optionally registers valid response signals to satisfy masters that require
// >= 1 cycle latency (like PicoRV32).

module axi_lite_decoder #(
    parameter [15:0] ADDR_BASE_0 = 16'h0000,
    parameter [15:0] ADDR_BASE_1 = 16'h1000,
    parameter [15:0] ADDR_BASE_2 = 16'h2000,
    parameter integer REGISTER_RESPONSES = 1
) (
    input wire clk,
    input wire rst_n,

    // Master Interface (e.g. RISC-V)
    axi_lite_if.slave s_axi,

    // Slave 0 Interface (e.g. BRAM Wrapper)
    axi_lite_if.master m0_axi,

    // Slave 1 Interface (e.g. GPU Engine)
    axi_lite_if.master m1_axi,

    // Slave 2 Interface (e.g. UART)
    axi_lite_if.master m2_axi
);

    wire sel_0 = (s_axi.araddr[31:16] == ADDR_BASE_0) || (s_axi.awaddr[31:16] == ADDR_BASE_0);
    wire sel_1 = (s_axi.araddr[31:16] == ADDR_BASE_1) || (s_axi.awaddr[31:16] == ADDR_BASE_1);
    wire sel_2 = (s_axi.araddr[31:16] == ADDR_BASE_2) || (s_axi.awaddr[31:16] == ADDR_BASE_2);

    // Address & Write Data Routing (Master -> Slaves)
    assign m0_axi.awvalid = s_axi.awvalid && sel_0;
    assign m0_axi.awaddr = s_axi.awaddr;
    assign m0_axi.awprot = s_axi.awprot;
    assign m0_axi.wvalid = s_axi.wvalid && sel_0;
    assign m0_axi.wdata = s_axi.wdata;
    assign m0_axi.wstrb = s_axi.wstrb;
    assign m0_axi.arvalid = s_axi.arvalid && sel_0;
    assign m0_axi.araddr = s_axi.araddr;
    assign m0_axi.arprot = s_axi.arprot;

    assign m1_axi.awvalid = s_axi.awvalid && sel_1;
    assign m1_axi.awaddr = {16'd0, s_axi.awaddr[15:0]}; // Map to zero-based for Slave 1
    assign m1_axi.awprot = s_axi.awprot;
    assign m1_axi.wvalid = s_axi.wvalid && sel_1;
    assign m1_axi.wdata = s_axi.wdata;
    assign m1_axi.wstrb = s_axi.wstrb;
    assign m1_axi.arvalid = s_axi.arvalid && sel_1;
    assign m1_axi.araddr = {16'd0, s_axi.araddr[15:0]}; // Map to zero-based for Slave 1
    assign m1_axi.arprot = s_axi.arprot;

    assign m2_axi.awvalid = s_axi.awvalid && sel_2;
    assign m2_axi.awaddr = {16'd0, s_axi.awaddr[15:0]}; // Map to zero-based for Slave 2
    assign m2_axi.awprot = s_axi.awprot;
    assign m2_axi.wvalid = s_axi.wvalid && sel_2;
    assign m2_axi.wdata = s_axi.wdata;
    assign m2_axi.wstrb = s_axi.wstrb;
    assign m2_axi.arvalid = s_axi.arvalid && sel_2;
    assign m2_axi.araddr = {16'd0, s_axi.araddr[15:0]}; // Map to zero-based for Slave 2
    assign m2_axi.arprot = s_axi.arprot;

    // Ready Signals Routing (Slaves -> Master)
    assign s_axi.awready = sel_0 ? m0_axi.awready : (sel_1 ? m1_axi.awready : (sel_2 ? m2_axi.awready : 1'b1));
    assign s_axi.wready = sel_0 ? m0_axi.wready : (sel_1 ? m1_axi.wready : (sel_2 ? m2_axi.wready : 1'b1));
    assign s_axi.arready = sel_0 ? m0_axi.arready : (sel_1 ? m1_axi.arready : (sel_2 ? m2_axi.arready : 1'b1));

    // Response Routing (Slaves -> Master)
    assign m0_axi.bready = s_axi.bready;
    assign m0_axi.rready = s_axi.rready;
    assign m1_axi.bready = s_axi.bready;
    assign m1_axi.rready = s_axi.rready;
    assign m2_axi.bready = s_axi.bready;
    assign m2_axi.rready = s_axi.rready;

    wire comb_bvalid = m0_axi.bvalid | m1_axi.bvalid | m2_axi.bvalid;
    wire comb_rvalid = m0_axi.rvalid | m1_axi.rvalid | m2_axi.rvalid;
    wire [31:0] comb_rdata = m0_axi.rvalid ? m0_axi.rdata : (m1_axi.rvalid ? m1_axi.rdata : m2_axi.rdata);
    wire [1:0] comb_bresp = m0_axi.bvalid ? m0_axi.bresp : (m1_axi.bvalid ? m1_axi.bresp : m2_axi.bresp);
    wire [1:0] comb_rresp = m0_axi.rvalid ? m0_axi.rresp : (m1_axi.rvalid ? m1_axi.rresp : m2_axi.rresp);

    generate
        if (REGISTER_RESPONSES) begin : gen_reg_resp
            reg r_bvalid, r_rvalid;
            reg [31:0] r_rdata;
            reg [1:0] r_bresp, r_rresp;
            
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    r_bvalid <= 1'b0;
                    r_rvalid <= 1'b0;
                    r_rdata <= 32'd0;
                    r_bresp <= 2'b00;
                    r_rresp <= 2'b00;
                end else begin
                    // Simplified 1-cycle delay for zero-wait-state slaves
                    r_bvalid <= (s_axi.awvalid && s_axi.wvalid) && (sel_0 || sel_1 || sel_2);
                    r_rvalid <= s_axi.arvalid && (sel_0 || sel_1 || sel_2);
                    
                    // Capture data combinatorially from slaves
                    r_rdata <= m0_axi.arvalid ? m0_axi.rdata : (m1_axi.arvalid ? m1_axi.rdata : (m2_axi.arvalid ? m2_axi.rdata : 32'd0));
                    r_bresp <= 2'b00; // Assume OKAY for simplicity
                    r_rresp <= 2'b00; // Assume OKAY for simplicity
                end
            end
            assign s_axi.bvalid = r_bvalid;
            assign s_axi.rvalid = r_rvalid;
            assign s_axi.rdata = r_rdata;
            assign s_axi.bresp = r_bresp;
            assign s_axi.rresp = r_rresp;
        end else begin : gen_comb_resp
            assign s_axi.bvalid = comb_bvalid;
            assign s_axi.rvalid = comb_rvalid;
            assign s_axi.rdata = comb_rdata;
            assign s_axi.bresp = comb_bresp;
            assign s_axi.rresp = comb_rresp;
        end
    endgenerate

endmodule

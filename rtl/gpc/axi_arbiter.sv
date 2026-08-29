`timescale 1ns / 1ps
// AXI4-Full 2-to-1 Arbiter
// Multiplexes Memory Requests from 2 SMs to the Global Crossbar.
// Simple Round-Robin/Priority Arbitration.

module axi_arbiter (
    input wire clk,
    input wire rst_n,

    // SM 0 Interface
    axi4_if.slave s0_axi,
    // SM 1 Interface
    axi4_if.slave s1_axi,

    // Global Memory Interface
    axi4_if.master m_axi
);

    // Write Address (AW) Channel Arbitration
    reg aw_grant_s1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_grant_s1 <= 1'b0;
        end else if (m_axi.awvalid && m_axi.awready) begin
            // Toggle priority after a successful transaction
            aw_grant_s1 <= ~aw_grant_s1; 
        end
    end

    wire sel_aw_s1 = aw_grant_s1 ? (s1_axi.awvalid ? 1'b1 : 1'b0) : (s0_axi.awvalid ? 1'b0 : (s1_axi.awvalid ? 1'b1 : 1'b0));

    assign m_axi.awvalid = sel_aw_s1 ? s1_axi.awvalid : s0_axi.awvalid;
    assign m_axi.awaddr = sel_aw_s1 ? s1_axi.awaddr : s0_axi.awaddr;
    assign m_axi.awlen = sel_aw_s1 ? s1_axi.awlen : s0_axi.awlen;
    assign m_axi.awsize = sel_aw_s1 ? s1_axi.awsize : s0_axi.awsize;
    assign m_axi.awburst = sel_aw_s1 ? s1_axi.awburst : s0_axi.awburst;
    assign m_axi.awid = sel_aw_s1 ? {1'b1, s1_axi.awid[0]} : {1'b0, s0_axi.awid[0]};

    assign s0_axi.awready = (!sel_aw_s1) ? m_axi.awready : 1'b0;
    assign s1_axi.awready = ( sel_aw_s1) ? m_axi.awready : 1'b0;

    // Write Data (W) Channel Arbitration
    // To properly support AXI, W channel must follow AW channel.
    // For simplicity in this dummy version, we tie them together if WVALID is always asserted with AWVALID.
    // In a real AXI design, you need a FIFO to track which ID won the AW channel to route the W channel.
    // For now, we assume strict in-order and tie W channel to the same sel_aw_s1.
    
    assign m_axi.wvalid = sel_aw_s1 ? s1_axi.wvalid : s0_axi.wvalid;
    assign m_axi.wdata = sel_aw_s1 ? s1_axi.wdata : s0_axi.wdata;
    assign m_axi.wstrb = sel_aw_s1 ? s1_axi.wstrb : s0_axi.wstrb;
    assign m_axi.wlast = sel_aw_s1 ? s1_axi.wlast : s0_axi.wlast;

    assign s0_axi.wready = (!sel_aw_s1) ? m_axi.wready : 1'b0;
    assign s1_axi.wready = ( sel_aw_s1) ? m_axi.wready : 1'b0;

    // Write Response (B) Channel Routing
    // Route back based on ID bit 1
    assign s0_axi.bvalid = (m_axi.bvalid && m_axi.bid[1] == 1'b0) ? 1'b1 : 1'b0;
    assign s1_axi.bvalid = (m_axi.bvalid && m_axi.bid[1] == 1'b1) ? 1'b1 : 1'b0;
    
    assign s0_axi.bresp = m_axi.bresp;
    assign s1_axi.bresp = m_axi.bresp;
    
    // The master bid is truncated back
    assign s0_axi.bid = m_axi.bid[0:0];
    assign s1_axi.bid = m_axi.bid[0:0];

    assign m_axi.bready = (m_axi.bid[1] == 1'b1) ? s1_axi.bready : s0_axi.bready;

    // Read Address (AR) and Read Data (R) - Tied off for now
    assign m_axi.arvalid = 1'b0;
    assign m_axi.araddr = 32'd0;
    assign m_axi.arlen = 8'd0;
    assign m_axi.arsize = 3'd0;
    assign m_axi.arburst = 2'd0;
    assign m_axi.arid = 2'd0;
    
    assign s0_axi.arready = 1'b0;
    assign s1_axi.arready = 1'b0;

    assign m_axi.rready = 1'b1;
    assign s0_axi.rvalid = 1'b0;
    assign s1_axi.rvalid = 1'b0;

endmodule

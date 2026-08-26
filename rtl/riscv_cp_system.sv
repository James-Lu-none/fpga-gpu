// =========================================================================
// RISC-V Command Processor (CP) System Top Module
// Direct Host-to-CP Mailbox Architecture & Hardware IRQ-Driven SoC
// =========================================================================

`timescale 1ns / 1ps

module riscv_cp_system (
    input  wire        clk,
    input  wire        rst_n,

    // ---------------------------------------------------------------------
    // Host PCIe XDMA AXI-Lite Slave Interface (Direct BAR0 BRAM & Mailbox)
    // ---------------------------------------------------------------------
    axi_lite_if.slave s_axi,

    // ---------------------------------------------------------------------
    // Work Queue BRAM Interface for Hardware Engine
    // ---------------------------------------------------------------------
    input  wire [13:0] wq_bram_addr,
    input  wire        wq_bram_en,
    output wire [31:0] wq_bram_dout,
    output reg         hw_trigger,

    output wire        trap_out
);

    // ---------------------------------------------------------------------
    // Hardware Doorbell IRQ Generator (Triggers IRQ on Host Mailbox Write)
    // ---------------------------------------------------------------------
    reg doorbell_irq_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            doorbell_irq_reg <= 1'b0;
        end else begin
            // Trigger IRQ pulse when Host writes to Mailbox Doorbell Address 0x3F00
            doorbell_irq_reg <= s_axi.awvalid && s_axi.wvalid && s_axi.awready && (s_axi.awaddr[13:0] == 14'h3F00);
        end
    end

    // ---------------------------------------------------------------------
    // RISC-V AXI4-Lite Master Signals
    // ---------------------------------------------------------------------
    wire        rv_awvalid, rv_awready;
    wire [31:0] rv_awaddr;
    wire [ 2:0] rv_awprot;
    wire        rv_wvalid, rv_wready;
    wire [31:0] rv_wdata;
    wire [ 3:0] rv_wstrb;
    wire        rv_bvalid, rv_bready;
    wire        rv_arvalid, rv_arready;
    wire [31:0] rv_araddr;
    wire [ 2:0] rv_arprot;
    wire        rv_rvalid, rv_rready;
    wire [31:0] rv_rdata;

    // Instantiate PicoRV32 AXI Core with Hardware IRQ Enabled
    picorv32_axi #(
        .ENABLE_IRQ(1),
        .ENABLE_IRQ_QREGS(1),
        .PROGADDR_RESET(32'h0000_0000),
        .PROGADDR_IRQ(32'h0000_0010),
        .STACKADDR(32'h0000_3E00)
    ) u_picorv32 (
        .clk(clk),
        .resetn(rst_n),
        .trap(trap_out),

        .mem_axi_awvalid(rv_awvalid),
        .mem_axi_awready(rv_awready),
        .mem_axi_awaddr(rv_awaddr),
        .mem_axi_awprot(rv_awprot),

        .mem_axi_wvalid(rv_wvalid),
        .mem_axi_wready(rv_wready),
        .mem_axi_wdata(rv_wdata),
        .mem_axi_wstrb(rv_wstrb),

        .mem_axi_bvalid(rv_bvalid),
        .mem_axi_bready(rv_bready),

        .mem_axi_arvalid(rv_arvalid),
        .mem_axi_arready(rv_arready),
        .mem_axi_araddr(rv_araddr),
        .mem_axi_arprot(rv_arprot),

        .mem_axi_rvalid(rv_rvalid),
        .mem_axi_rready(rv_rready),
        .mem_axi_rdata(rv_rdata),

        .pcpi_valid(),
        .pcpi_insn(),
        .pcpi_rs1(),
        .pcpi_rs2(),
        .pcpi_wr(1'b0),
        .pcpi_rd(32'd0),
        .pcpi_wait(1'b0),
        .pcpi_ready(1'b0),
        
        .irq({31'd0, doorbell_irq_reg}),
        .eoi()
    );

    // ---------------------------------------------------------------------
    // RISC-V Memory Decoder
    // 0x0000_xxxx : Mailbox BRAM (16KB)
    // 0x1000_xxxx : Work Queue BRAM (1KB)
    // 0x2000_xxxx : Hardware Engine Trigger Doorbell
    // ---------------------------------------------------------------------
    wire sel_bram     = (rv_araddr[31:16] == 16'h0000) || (rv_awaddr[31:16] == 16'h0000);
    wire sel_wq       = (rv_araddr[31:16] == 16'h1000) || (rv_awaddr[31:16] == 16'h1000);
    wire sel_doorbell = (rv_awaddr[31:16] == 16'h2000);

    wire [31:0] bram_dout_a;
    wire [31:0] wq_dout_a;
    reg         bram_rvalid_a;
    reg         bram_bvalid_a;
    reg         wq_rvalid_a;
    reg         wq_bvalid_a;
    reg         doorbell_bvalid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bram_rvalid_a   <= 1'b0;
            bram_bvalid_a   <= 1'b0;
            wq_rvalid_a     <= 1'b0;
            wq_bvalid_a     <= 1'b0;
            doorbell_bvalid <= 1'b0;
            hw_trigger      <= 1'b0;
        end else begin
            bram_rvalid_a   <= rv_arvalid && sel_bram;
            bram_bvalid_a   <= rv_wvalid && sel_bram;
            wq_rvalid_a     <= rv_arvalid && sel_wq;
            wq_bvalid_a     <= rv_wvalid && sel_wq;
            doorbell_bvalid <= rv_wvalid && sel_doorbell;
            
            // Generate 1-cycle pulse when writing to doorbell
            hw_trigger      <= rv_wvalid && sel_doorbell;
        end
    end

    // ---------------------------------------------------------------------
    // Host PCIe AXI-Lite Slave Interface (Port B: Direct BRAM & Mailbox)
    // ---------------------------------------------------------------------
    reg host_bvalid;
    reg host_rvalid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            host_bvalid <= 1'b0;
            host_rvalid <= 1'b0;
        end else begin
            // Write Response Handshake
            if (s_axi.awvalid && s_axi.wvalid && !host_bvalid) begin
                host_bvalid <= 1'b1;
            end else if (s_axi.bready && host_bvalid) begin
                host_bvalid <= 1'b0;
            end

            // Read Response Handshake
            if (s_axi.arvalid && !host_rvalid) begin
                host_rvalid <= 1'b1;
            end else if (s_axi.rready && host_rvalid) begin
                host_rvalid <= 1'b0;
            end
        end
    end

    assign s_axi.arready = ~host_rvalid;
    assign s_axi.awready = ~host_bvalid;
    assign s_axi.wready  = ~host_bvalid;
    assign s_axi.rvalid  = host_rvalid;
    assign s_axi.bvalid  = host_bvalid;
    assign s_axi.bresp   = 2'b00; // OKAY response
    assign s_axi.rresp   = 2'b00; // OKAY response

    wire [31:0] bram_dout_b;
    assign s_axi.rdata   = bram_dout_b;

    // ---------------------------------------------------------------------
    // Instantiate 16KB Dual-Port BRAM (Port A: RISC-V, Port B: Host PCIe)
    // ---------------------------------------------------------------------
    riscv_bram #(
        .MEM_SIZE_BYTES(16384)
    ) u_bram (
        .clk(clk),
        .rst_n(rst_n),

        // Port A: RISC-V CPU
        .en_a(sel_bram && (rv_arvalid || rv_wvalid)),
        .we_a(sel_bram ? rv_wstrb : 4'b0000),
        .addr_a(rv_arvalid ? rv_araddr[13:0] : rv_awaddr[13:0]),
        .din_a(rv_wdata),
        .dout_a(bram_dout_a),

        // Port B: Host PCIe (XDMA Direct BRAM Mailbox)
        .en_b((s_axi.arvalid && s_axi.arready) || (s_axi.awvalid && s_axi.wvalid && s_axi.awready)),
        .we_b((s_axi.awvalid && s_axi.wvalid && s_axi.awready) ? s_axi.wstrb : 4'b0000),
        .addr_b(s_axi.arvalid ? s_axi.araddr[13:0] : s_axi.awaddr[13:0]),
        .din_b(s_axi.wdata),
        .dout_b(bram_dout_b)
    );

    // ---------------------------------------------------------------------
    // Instantiate 1KB Dual-Port BRAM (Port A: RISC-V, Port B: HW Engine)
    // ---------------------------------------------------------------------
    riscv_bram #(
        .MEM_SIZE_BYTES(1024)
    ) u_work_queue_bram (
        .clk(clk),
        .rst_n(rst_n),

        // Port A: RISC-V CPU
        .en_a(sel_wq && (rv_arvalid || rv_wvalid)),
        .we_a(sel_wq ? rv_wstrb : 4'b0000),
        .addr_a(rv_arvalid ? rv_araddr[13:0] : rv_awaddr[13:0]),
        .din_a(rv_wdata),
        .dout_a(wq_dout_a),

        // Port B: Hardware Engine (Read Only)
        .en_b(wq_bram_en),
        .we_b(4'b0000),
        .addr_b(wq_bram_addr),
        .din_b(32'd0),
        .dout_b(wq_bram_dout)
    );

    // Bus to RISC-V Core
    assign rv_awready = 1'b1;
    assign rv_wready  = 1'b1;
    assign rv_bvalid  = bram_bvalid_a | wq_bvalid_a | doorbell_bvalid;

    assign rv_arready = 1'b1;
    assign rv_rvalid  = bram_rvalid_a | wq_rvalid_a;
    assign rv_rdata   = wq_rvalid_a ? wq_dout_a : bram_dout_a;

endmodule

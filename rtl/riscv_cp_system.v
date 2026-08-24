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
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    input  wire [31:0] s_axi_wdata,
    input  wire [ 3:0] s_axi_wstrb,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    input  wire [31:0] s_axi_araddr,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,
    output wire [31:0] s_axi_rdata,

    // ---------------------------------------------------------------------
    // Interface to GPU Compute Core Registers (0x4000_0000)
    // ---------------------------------------------------------------------
    output wire        gpu_axi_awvalid,
    input  wire        gpu_axi_awready,
    output wire [31:0] gpu_axi_awaddr,
    output wire        gpu_axi_wvalid,
    input  wire        gpu_axi_wready,
    output wire [31:0] gpu_axi_wdata,
    output wire [ 3:0] gpu_axi_wstrb,
    input  wire        gpu_axi_bvalid,
    output wire        gpu_axi_bready,

    output wire        gpu_axi_arvalid,
    input  wire        gpu_axi_arready,
    output wire [31:0] gpu_axi_araddr,
    input  wire        gpu_axi_rvalid,
    output wire        gpu_axi_rready,
    input  wire [31:0] gpu_axi_rdata,

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
            doorbell_irq_reg <= s_axi_wvalid && s_axi_wready && (s_axi_awaddr[13:0] == 14'h3F00);
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
    // RISC-V Memory Decoder (Port A: 0x0000_xxxx BRAM, 0x4000_xxxx GPU Regs)
    // ---------------------------------------------------------------------
    wire sel_bram = (rv_araddr[31:16] == 16'h0000) || (rv_awaddr[31:16] == 16'h0000);
    wire sel_gpu  = (rv_araddr[31:16] == 16'h4000) || (rv_awaddr[31:16] == 16'h4000);

    wire [31:0] bram_dout_a;
    reg         bram_rvalid_a;
    reg         bram_bvalid_a;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bram_rvalid_a <= 1'b0;
            bram_bvalid_a <= 1'b0;
        end else begin
            bram_rvalid_a <= rv_arvalid && sel_bram;
            bram_bvalid_a <= rv_wvalid && sel_bram;
        end
    end

    // ---------------------------------------------------------------------
    // Host PCIe AXI-Lite Slave Interface (Port B: Direct BRAM & Mailbox)
    // ---------------------------------------------------------------------
    reg host_rvalid;
    reg host_bvalid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            host_rvalid <= 1'b0;
            host_bvalid <= 1'b0;
        end else begin
            host_rvalid <= s_axi_arvalid;
            host_bvalid <= s_axi_wvalid;
        end
    end

    assign s_axi_arready = 1'b1;
    assign s_axi_awready = 1'b1;
    assign s_axi_wready  = 1'b1;
    assign s_axi_rvalid  = host_rvalid;
    assign s_axi_bvalid  = host_bvalid;

    wire [31:0] bram_dout_b;
    assign s_axi_rdata   = bram_dout_b;

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
        .en_b(s_axi_arvalid || s_axi_wvalid),
        .we_b(s_axi_wvalid ? s_axi_wstrb : 4'b0000),
        .addr_b(s_axi_arvalid ? s_axi_araddr[13:0] : s_axi_awaddr[13:0]),
        .din_b(s_axi_wdata),
        .dout_b(bram_dout_b)
    );

    // Connect GPU AXI Slave Ports
    assign gpu_axi_awvalid = sel_gpu ? rv_awvalid : 1'b0;
    assign gpu_axi_awaddr  = rv_awaddr;
    assign gpu_axi_wvalid  = sel_gpu ? rv_wvalid : 1'b0;
    assign gpu_axi_wdata   = rv_wdata;
    assign gpu_axi_wstrb   = rv_wstrb;
    assign gpu_axi_bready  = sel_gpu ? rv_bready : 1'b0;

    assign gpu_axi_arvalid = sel_gpu ? rv_arvalid : 1'b0;
    assign gpu_axi_araddr  = rv_araddr;
    assign gpu_axi_rready  = sel_gpu ? rv_rready : 1'b0;

    // Bus Multiplexer to RISC-V Core
    assign rv_awready = sel_gpu ? gpu_axi_awready : 1'b1;
    assign rv_wready  = sel_gpu ? gpu_axi_wready  : 1'b1;
    assign rv_bvalid  = sel_gpu ? gpu_axi_bvalid  : bram_bvalid_a;

    assign rv_arready = sel_gpu ? gpu_axi_arready : 1'b1;
    assign rv_rvalid  = sel_gpu ? gpu_axi_rvalid  : bram_rvalid_a;
    assign rv_rdata   = sel_gpu ? gpu_axi_rdata   : bram_dout_a;

endmodule

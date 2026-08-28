// =========================================================================
// RISC-V Command Processor (CP) System Top Module
// Direct Host-to-CP Mailbox Architecture & Hardware IRQ-Driven SoC
// =========================================================================

`timescale 1ns / 1ps

`include "gpu_memory_map.vh"

module riscv_cp_system (
    input  wire        clk,
    input  wire        rst_n,

    axi_lite_if.slave  s_axi, // PCIe Host Interface
    axi_lite_if.master m_axi_lite, // To GPU SM register

    output wire        trap_out
);
    axi_lite_if rv_axi(); // From RISC-V mem master
    axi_lite_if bram_axi(); // To block ram that store RV firmware and mailbox messages

    // ---------------------------------------------------------------------
    // Instantiate PicoRV32 AXI Core with Hardware IRQ Enabled
    // ---------------------------------------------------------------------
    reg doorbell_irq_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            doorbell_irq_reg <= 1'b0;
        end else begin
            // Trigger IRQ pulse when Host writes to Mailbox Doorbell Address
            doorbell_irq_reg <= s_axi.awvalid && s_axi.wvalid && s_axi.awready && (s_axi.awaddr[13:0] == `BRAM_MAILBOX_BASE[13:0]);
        end
    end
    
    picorv32_axi #(
        .ENABLE_IRQ(1),
        .ENABLE_IRQ_QREGS(1),
        .PROGADDR_RESET(`BRAM_PROGADDR_RESET),
        .PROGADDR_IRQ(`BRAM_PROGADDR_IRQ),
        .STACKADDR(`BRAM_STACKADDR)
    ) u_picorv32 (
        .clk(clk),
        .resetn(rst_n),
        .trap(trap_out),

        .mem_axi_awvalid(rv_axi.awvalid),
        .mem_axi_awready(rv_axi.awready),
        .mem_axi_awaddr(rv_axi.awaddr),
        .mem_axi_awprot(rv_axi.awprot),

        .mem_axi_wvalid(rv_axi.wvalid),
        .mem_axi_wready(rv_axi.wready),
        .mem_axi_wdata(rv_axi.wdata),
        .mem_axi_wstrb(rv_axi.wstrb),

        .mem_axi_bvalid(rv_axi.bvalid),
        .mem_axi_bready(rv_axi.bready),

        .mem_axi_arvalid(rv_axi.arvalid),
        .mem_axi_arready(rv_axi.arready),
        .mem_axi_araddr(rv_axi.araddr),
        .mem_axi_arprot(rv_axi.arprot),

        .mem_axi_rvalid(rv_axi.rvalid),
        .mem_axi_rready(rv_axi.rready),
        .mem_axi_rdata(rv_axi.rdata),

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
    // AXI-Lite 1-to-2 Decoder (0x0000: BRAM, 0x1000: GPU Engine)
    // ---------------------------------------------------------------------

    axi_lite_1to2_decoder #(
        .ADDR_BASE_0(`ADDR_BASE_BRAM),
        .ADDR_BASE_1(`ADDR_BASE_GPC),
        .REGISTER_RESPONSES(1)
    ) u_decoder (
        .clk(clk),
        .rst_n(rst_n),
        .s_axi(rv_axi), // From RISC-V mem master
        .m0_axi(bram_axi), // To BRAM for CPU mem access
        .m1_axi(m_axi_lite) // To GPU SM register
    );

    // BRAM Interface Adapter (0-cycle pseudo slave)
    assign bram_axi.awready = 1'b1;
    assign bram_axi.wready  = 1'b1;
    assign bram_axi.arready = 1'b1;
    
    // BRAM outputs valid immediately in our simple wrapper, the decoder registers it
    assign bram_axi.bvalid  = bram_axi.awvalid && bram_axi.wvalid; 
    assign bram_axi.rvalid  = bram_axi.arvalid;
    assign bram_axi.bresp   = 2'b00;
    assign bram_axi.rresp   = 2'b00;
    
    wire [31:0] bram_dout_a;
    assign bram_axi.rdata   = bram_dout_a;

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
            if (s_axi.awvalid && s_axi.wvalid && !host_bvalid) begin
                host_bvalid <= 1'b1;
            end else if (s_axi.bready && host_bvalid) begin
                host_bvalid <= 1'b0;
            end

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
    assign s_axi.bresp   = 2'b00; 
    assign s_axi.rresp   = 2'b00; 

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
        .en_a(bram_axi.arvalid || (bram_axi.awvalid && bram_axi.wvalid)),
        .we_a((bram_axi.awvalid && bram_axi.wvalid) ? bram_axi.wstrb : 4'b0000),
        .addr_a(bram_axi.arvalid ? bram_axi.araddr[13:0] : bram_axi.awaddr[13:0]),
        .din_a(bram_axi.wdata),
        .dout_a(bram_dout_a),

        // Port B: Host PCIe (XDMA Direct BRAM Mailbox)
        .en_b((s_axi.arvalid && s_axi.arready) || (s_axi.awvalid && s_axi.wvalid && s_axi.awready)),
        .we_b((s_axi.awvalid && s_axi.wvalid && s_axi.awready) ? s_axi.wstrb : 4'b0000),
        .addr_b(s_axi.arvalid ? s_axi.araddr[13:0] : s_axi.awaddr[13:0]),
        .din_b(s_axi.wdata),
        .dout_b(bram_dout_b)
    );

endmodule

`timescale 1ns / 1ps
// GPU Top Module
// Encapsulates the RISC-V Command Processor (CP) and the Graphics Processing Cluster

`include "../common/address.vh"

import gpu_pkg::*;

module gpu_top (
    input wire clk,
    input wire rst_n,

    // PCIe XDMA BAR0 AXI-Lite Slave Interface (Host Control)
    axi_lite_if.slave s_axi_lite,

    // 256-bit AXI4-Full Master Interface (To Global Memory Crossbar)
    axi4_if.master m_axi_gmem,

    // PCIe Host Interrupts
    output wire usr_irq_req,
    input wire usr_irq_ack,
    
    // UART Physical Interface
    input wire uart_rxd,
    output wire uart_txd
);

    // Reset Synchronizer to resolve high fanout / recovery time violations
    (* ASYNC_REG = "TRUE" *) reg [2:0] rst_sync_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_sync_reg <= 3'b000;
        end else begin
            rst_sync_reg <= {rst_sync_reg[1:0], 1'b1};
        end
    end
    wire sys_rst_n = rst_sync_reg[2];

    // Internal Interconnect
    // AXI-Lite connection between RISC-V CP and GPC
    axi_lite_if #(.ADDR_W(32), .DATA_W(32)) rv_gpu_axil();
    
    // RISC-V Memory interfaces
    axi_lite_if rv_axi(); // From RISC-V mem master
    axi_lite_if bram_axi(); // To block ram that store RV firmware and mailbox messages
    axi_lite_if rv_uart_axil(); // To UART

    // 1. RISC-V Command Processor SoC (Control Plane)
    
    // Host Control Registers (Sniffed from AXI Lite Write Channel)
    reg doorbell_irq_reg;
    reg cpu_soft_rst_n; // CPU Soft Reset Control Register

    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            doorbell_irq_reg <= 1'b0;
            cpu_soft_rst_n <= 1'b0; // Default to Reset=0 so CPU waits for firmware load on boot
        end else begin
            // Mailbox Doorbell
            doorbell_irq_reg <= s_axi_lite.awvalid && s_axi_lite.wvalid && s_axi_lite.awready && (s_axi_lite.awaddr == `BRAM_MAILBOX_BASE);
            
            // CPU Soft Reset
            if (s_axi_lite.awvalid && s_axi_lite.wvalid && s_axi_lite.awready && (s_axi_lite.awaddr == `BRAM_CPU_RESET_BASE)) begin
                cpu_soft_rst_n <= s_axi_lite.wdata[0];
            end
        end
    end
    
    wire internal_cp_trap;
    
    picorv32_axi #(
        .ENABLE_IRQ(1),
        .ENABLE_IRQ_QREGS(1),
        .PROGADDR_RESET(`BRAM_PROGADDR_RESET),
        .PROGADDR_IRQ(`BRAM_PROGADDR_IRQ),
        .STACKADDR(`BRAM_STACKADDR)
    ) u_picorv32 (
        .clk(clk),
        .resetn(sys_rst_n & cpu_soft_rst_n),
        .trap(internal_cp_trap),

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

    // AXI Crossbar (RISC-V -> BRAM, GPU, UART)
    axi_crossbar_1to3_0 u_crossbar (
        .aclk(clk),
        .aresetn(sys_rst_n),
        
        // Slave 0 (From RISC-V)
        .s_axi_awaddr  (rv_axi.awaddr),
        .s_axi_awprot  (rv_axi.awprot),
        .s_axi_awvalid (rv_axi.awvalid),
        .s_axi_awready (rv_axi.awready),
        .s_axi_wdata   (rv_axi.wdata),
        .s_axi_wstrb   (rv_axi.wstrb),
        .s_axi_wvalid  (rv_axi.wvalid),
        .s_axi_wready  (rv_axi.wready),
        .s_axi_bresp   (rv_axi.bresp),
        .s_axi_bvalid  (rv_axi.bvalid),
        .s_axi_bready  (rv_axi.bready),
        .s_axi_araddr  (rv_axi.araddr),
        .s_axi_arprot  (rv_axi.arprot),
        .s_axi_arvalid (rv_axi.arvalid),
        .s_axi_arready (rv_axi.arready),
        .s_axi_rdata   (rv_axi.rdata),
        .s_axi_rresp   (rv_axi.rresp),
        .s_axi_rvalid  (rv_axi.rvalid),
        .s_axi_rready  (rv_axi.rready),
        
        // Master Ports (M02: UART, M01: GPU, M00: BRAM)
        .m_axi_awaddr  ({rv_uart_axil.awaddr, rv_gpu_axil.awaddr, bram_axi.awaddr}),
        .m_axi_awprot  ({rv_uart_axil.awprot, rv_gpu_axil.awprot, bram_axi.awprot}),
        .m_axi_awvalid ({rv_uart_axil.awvalid, rv_gpu_axil.awvalid, bram_axi.awvalid}),
        .m_axi_awready ({rv_uart_axil.awready, rv_gpu_axil.awready, bram_axi.awready}),
        .m_axi_wdata   ({rv_uart_axil.wdata,   rv_gpu_axil.wdata,   bram_axi.wdata}),
        .m_axi_wstrb   ({rv_uart_axil.wstrb,   rv_gpu_axil.wstrb,   bram_axi.wstrb}),
        .m_axi_wvalid  ({rv_uart_axil.wvalid,  rv_gpu_axil.wvalid,  bram_axi.wvalid}),
        .m_axi_wready  ({rv_uart_axil.wready,  rv_gpu_axil.wready,  bram_axi.wready}),
        .m_axi_bresp   ({rv_uart_axil.bresp,   rv_gpu_axil.bresp,   bram_axi.bresp}),
        .m_axi_bvalid  ({rv_uart_axil.bvalid,  rv_gpu_axil.bvalid,  bram_axi.bvalid}),
        .m_axi_bready  ({rv_uart_axil.bready,  rv_gpu_axil.bready,  bram_axi.bready}),
        .m_axi_araddr  ({rv_uart_axil.araddr,  rv_gpu_axil.araddr,  bram_axi.araddr}),
        .m_axi_arprot  ({rv_uart_axil.arprot,  rv_gpu_axil.arprot,  bram_axi.arprot}),
        .m_axi_arvalid ({rv_uart_axil.arvalid, rv_gpu_axil.arvalid, bram_axi.arvalid}),
        .m_axi_arready ({rv_uart_axil.arready, rv_gpu_axil.arready, bram_axi.arready}),
        .m_axi_rdata   ({rv_uart_axil.rdata,   rv_gpu_axil.rdata,   bram_axi.rdata}),
        .m_axi_rresp   ({rv_uart_axil.rresp,   rv_gpu_axil.rresp,   bram_axi.rresp}),
        .m_axi_rvalid  ({rv_uart_axil.rvalid,  rv_gpu_axil.rvalid,  bram_axi.rvalid}),
        .m_axi_rready  ({rv_uart_axil.rready,  rv_gpu_axil.rready,  bram_axi.rready})
    );

    // AXI UART Lite
    axi_uartlite_0 u_uart (
        .s_axi_aclk    (clk),
        .s_axi_aresetn (sys_rst_n),
        .interrupt     (), // Unused
        .s_axi_awaddr  (rv_uart_axil.awaddr[3:0]), // UARTLite uses 4-bit address
        .s_axi_awvalid (rv_uart_axil.awvalid),
        .s_axi_awready (rv_uart_axil.awready),
        .s_axi_wdata   (rv_uart_axil.wdata),
        .s_axi_wstrb   (rv_uart_axil.wstrb),
        .s_axi_wvalid  (rv_uart_axil.wvalid),
        .s_axi_wready  (rv_uart_axil.wready),
        .s_axi_bresp   (rv_uart_axil.bresp),
        .s_axi_bvalid  (rv_uart_axil.bvalid),
        .s_axi_bready  (rv_uart_axil.bready),
        .s_axi_araddr  (rv_uart_axil.araddr[3:0]), // UARTLite uses 4-bit address
        .s_axi_arvalid (rv_uart_axil.arvalid),
        .s_axi_arready (rv_uart_axil.arready),
        .s_axi_rdata   (rv_uart_axil.rdata),
        .s_axi_rresp   (rv_uart_axil.rresp),
        .s_axi_rvalid  (rv_uart_axil.rvalid),
        .s_axi_rready  (rv_uart_axil.rready),
        .rx            (uart_rxd),
        .tx            (uart_txd)
    );

    wire [16:0] brama_addr;
    wire brama_clk, brama_en;
    wire [3:0] brama_we;
    wire [31:0] brama_din, brama_dout;
    wire brama_rst;

    wire [16:0] bramb_addr;
    wire bramb_clk, bramb_en;
    wire [3:0] bramb_we;
    wire [31:0] bramb_din, bramb_dout;
    wire bramb_rst;

    // AXI BRAM Controller (Port A: RISC-V)
    axi_bram_ctrl_0 u_bram_ctrl_rv (
        .s_axi_aclk(clk),
        .s_axi_aresetn(sys_rst_n),
        .s_axi_awaddr(bram_axi.awaddr[16:0]),
        .s_axi_awprot(bram_axi.awprot),
        .s_axi_awvalid(bram_axi.awvalid),
        .s_axi_awready(bram_axi.awready),
        .s_axi_wdata(bram_axi.wdata),
        .s_axi_wstrb(bram_axi.wstrb),
        .s_axi_wvalid(bram_axi.wvalid),
        .s_axi_wready(bram_axi.wready),
        .s_axi_bresp(bram_axi.bresp),
        .s_axi_bvalid(bram_axi.bvalid),
        .s_axi_bready(bram_axi.bready),
        .s_axi_araddr(bram_axi.araddr[16:0]),
        .s_axi_arprot(bram_axi.arprot),
        .s_axi_arvalid(bram_axi.arvalid),
        .s_axi_arready(bram_axi.arready),
        .s_axi_rdata(bram_axi.rdata),
        .s_axi_rresp(bram_axi.rresp),
        .s_axi_rvalid(bram_axi.rvalid),
        .s_axi_rready(bram_axi.rready),
        
        .bram_rst_a(brama_rst),
        .bram_clk_a(brama_clk),
        .bram_en_a(brama_en),
        .bram_we_a(brama_we),
        .bram_addr_a(brama_addr),
        .bram_wrdata_a(brama_din),
        .bram_rddata_a(brama_dout)
    );

    // AXI BRAM Controller (Port B: Host PCIe)
    axi_bram_ctrl_0 u_bram_ctrl_host (
        .s_axi_aclk(clk),
        .s_axi_aresetn(sys_rst_n),
        .s_axi_awaddr(s_axi_lite.awaddr[16:0]),
        .s_axi_awprot(s_axi_lite.awprot),
        .s_axi_awvalid(s_axi_lite.awvalid),
        .s_axi_awready(s_axi_lite.awready),
        .s_axi_wdata(s_axi_lite.wdata),
        .s_axi_wstrb(s_axi_lite.wstrb),
        .s_axi_wvalid(s_axi_lite.wvalid),
        .s_axi_wready(s_axi_lite.wready),
        .s_axi_bresp(s_axi_lite.bresp),
        .s_axi_bvalid(s_axi_lite.bvalid),
        .s_axi_bready(s_axi_lite.bready),
        .s_axi_araddr(s_axi_lite.araddr[16:0]),
        .s_axi_arprot(s_axi_lite.arprot),
        .s_axi_arvalid(s_axi_lite.arvalid),
        .s_axi_arready(s_axi_lite.arready),
        .s_axi_rdata(s_axi_lite.rdata),
        .s_axi_rresp(s_axi_lite.rresp),
        .s_axi_rvalid(s_axi_lite.rvalid),
        .s_axi_rready(s_axi_lite.rready),

        .bram_rst_a(bramb_rst),
        .bram_clk_a(bramb_clk),
        .bram_en_a(bramb_en),
        .bram_we_a(bramb_we),
        .bram_addr_a(bramb_addr),
        .bram_wrdata_a(bramb_din),
        .bram_rddata_a(bramb_dout)
    );

    // 128KB True Dual-Port Block Memory Generator
    blk_mem_gen_0 u_bram (
        .clka(brama_clk),
        .rsta(brama_rst),
        .ena(brama_en),
        .wea(brama_we),
        .addra(brama_addr), // since byte write is enabled so we dont need to do 2 bit shift
        .dina(brama_din),
        .douta(brama_dout),
        .rsta_busy(),

        .clkb(bramb_clk),
        .rstb(bramb_rst),
        .enb(bramb_en),
        .web(bramb_we),
        .addrb(bramb_addr), // since byte write is enabled so we dont need to do 2 bit shift
        .dinb(bramb_din),
        .doutb(bramb_dout),
        .rstb_busy()
    );

    // Interrupt Handshake Logic for PCIe XDMA
    reg cp_trap_d;
    reg irq_req_reg;
    
    wire trap_edge = internal_cp_trap & ~cp_trap_d;

    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            cp_trap_d <= 1'b0;
            irq_req_reg <= 1'b0;
        end else begin
            cp_trap_d <= internal_cp_trap;
            
            if (trap_edge) begin
                irq_req_reg <= 1'b1;
            end else if (usr_irq_ack) begin
                irq_req_reg <= 1'b0;
            end
        end
    end

    assign usr_irq_req = irq_req_reg;

    // 2. Graphics Processing Cluster (Compute Plane)
    processing_cluster u_gpc (
        .clk (clk),
        .rst_n (sys_rst_n),
        .s_axi_lite (rv_gpu_axil),
        .m_axi_gmem (m_axi_gmem)
    );

endmodule

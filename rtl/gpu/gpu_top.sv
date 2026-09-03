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
    
    // Trigger IRQ pulse when Host writes to Mailbox Doorbell Address
    reg doorbell_irq_reg;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            doorbell_irq_reg <= 1'b0;
        end else begin
            doorbell_irq_reg <= s_axi_lite.awvalid && s_axi_lite.wvalid && s_axi_lite.awready && (s_axi_lite.awaddr == `BRAM_MAILBOX_BASE);
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
        .resetn(sys_rst_n),
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

    // RISC-V Memory Decoder
    // 0x0000_xxxx : Mailbox BRAM (16KB)
    // 0x1000_xxxx : GPU Engine
    axi_lite_decoder #(
        .ADDR_BASE_0(`ADDR_BASE_BRAM),
        .ADDR_BASE_1(`ADDR_BASE_GPC),
        .ADDR_BASE_2(16'h2000),
        .REGISTER_RESPONSES(1)
    ) u_decoder (
        .clk(clk),
        .rst_n(sys_rst_n),
        .s_axi(rv_axi), // From RISC-V mem master
        .m0_axi(bram_axi), // To BRAM for CPU mem access
        .m1_axi(rv_gpu_axil), // To GPU SM register
        .m2_axi(rv_uart_axil) // To UART
    );

    // UART Module
    uart #(
        .CLK_FREQ(125000000),
        .BAUD_RATE(115200)
    ) u_uart (
        .clk(clk),
        .rst_n(sys_rst_n),
        .s_axi(rv_uart_axil),
        .rx(uart_rxd),
        .tx(uart_txd)
    );

    // BRAM Interface Adapter (0-cycle pseudo slave)
    assign bram_axi.awready = 1'b1;
    assign bram_axi.wready = 1'b1;
    assign bram_axi.arready = 1'b1;
    
    assign bram_axi.bvalid = bram_axi.awvalid && bram_axi.wvalid; 
    assign bram_axi.rvalid = bram_axi.arvalid;
    assign bram_axi.bresp = 2'b00;
    assign bram_axi.rresp = 2'b00;
    
    wire [31:0] bram_dout_a;
    assign bram_axi.rdata = bram_dout_a;

    // Host PCIe AXI-Lite Slave Interface (Port B: Direct BRAM & Mailbox)
    reg host_bvalid;
    reg host_rvalid;

    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            host_bvalid <= 1'b0;
            host_rvalid <= 1'b0;
        end else begin
            if (s_axi_lite.awvalid && s_axi_lite.wvalid && !host_bvalid) begin
                host_bvalid <= 1'b1;
            end else if (s_axi_lite.bready && host_bvalid) begin
                host_bvalid <= 1'b0;
            end

            if (s_axi_lite.arvalid && !host_rvalid) begin
                host_rvalid <= 1'b1;
            end else if (s_axi_lite.rready && host_rvalid) begin
                host_rvalid <= 1'b0;
            end
        end
    end

    assign s_axi_lite.arready = ~host_rvalid;
    assign s_axi_lite.awready = ~host_bvalid;
    assign s_axi_lite.wready = ~host_bvalid;
    assign s_axi_lite.rvalid = host_rvalid;
    assign s_axi_lite.bvalid = host_bvalid;
    assign s_axi_lite.bresp = 2'b00; 
    assign s_axi_lite.rresp = 2'b00; 

    wire [31:0] bram_dout_b;
    assign s_axi_lite.rdata = bram_dout_b;

    // 16KB Dual-Port BRAM (Port A: RISC-V, Port B: Host PCIe)
    boot_ram #(
        .MEM_SIZE_BYTES(16384)
    ) u_bram (
        .clk(clk),
        .rst_n(sys_rst_n),

        // Port A: RISC-V CPU
        .en_a(bram_axi.arvalid || (bram_axi.awvalid && bram_axi.wvalid)),
        .we_a((bram_axi.awvalid && bram_axi.wvalid) ? bram_axi.wstrb : 4'b0000),
        .addr_a(bram_axi.arvalid ? bram_axi.araddr[13:0] : bram_axi.awaddr[13:0]),
        .din_a(bram_axi.wdata),
        .dout_a(bram_dout_a),

        // Port B: Host PCIe (XDMA Direct BRAM Mailbox)
        .en_b((s_axi_lite.arvalid && s_axi_lite.arready) || (s_axi_lite.awvalid && s_axi_lite.wvalid && s_axi_lite.awready)),
        .we_b((s_axi_lite.awvalid && s_axi_lite.wvalid && s_axi_lite.awready) ? s_axi_lite.wstrb : 4'b0000),
        .addr_b(s_axi_lite.arvalid ? s_axi_lite.araddr[13:0] : s_axi_lite.awaddr[13:0]),
        .din_b(s_axi_lite.wdata),
        .dout_b(bram_dout_b)
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

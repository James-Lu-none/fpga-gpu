`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/20
// Design Name: vGPU Core
// Module Name: vgpu_axi_lite_regs
// Project Name: fpga-gpu
// Target Devices: Xilinx Artix-7 (XC7A200T-2FBG484)
// Tool Versions: Vivado 2026+
// Description: 
//   AXI-Lite Slave Register Interface for vGPU MMIO Control (BAR0)
//   Registers:
//     0x00: Doorbell (Write 1 to trigger hardware FSM)
//     0x04: Interrupt Status (Bit 0: 1 = Task Completed)
//     0x08: Interrupt Acknowledge (Write 1 to clear interrupt)
//     0x0C: Ring Buffer DMA Base Address [31:0]
//     0x10: Ring Buffer DMA Base Address [63:32]
//     0x14: Page Table Base Address [31:0]
//     0x18: Page Table Base Address [63:32]
//     0x20: UVM Mode (0 = Contiguous IOVA, 1 = Scatter-Gather Page Table)
//////////////////////////////////////////////////////////////////////////////////

module vgpu_axi_lite_regs #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 6
)(
    input  wire                          s_axi_aclk,
    input  wire                          s_axi_aresetn,

    // AXI-Lite Write Address Channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire                          s_axi_awvalid,
    output wire                          s_axi_awready,

    // AXI-Lite Write Data Channel
    input  wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input  wire [3:0]                    s_axi_wstrb,
    input  wire                          s_axi_wvalid,
    output wire                          s_axi_wready,

    // AXI-Lite Write Response Channel
    output wire [1:0]                    s_axi_bresp,
    output wire                          s_axi_bvalid,
    input  wire                          s_axi_bready,

    // AXI-Lite Read Address Channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire                          s_axi_arvalid,
    output wire                          s_axi_arready,

    // AXI-Lite Read Data Channel
    output wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output wire [1:0]                    s_axi_rresp,
    output wire                          s_axi_rvalid,
    input  wire                          s_axi_rready,

    // Internal Control Signals to GPU FSM
    output reg                           doorbell_pulse,
    output reg  [63:0]                   reg_ring_dma_addr,
    output reg  [63:0]                   reg_pagetable_dma_addr,
    output reg  [31:0]                   reg_uvm_mode,
    input  wire                          task_done_irq,
    output reg                           irq_ack_pulse
);

    // Register Address Offsets
    localparam [5:0] ADDR_DOORBELL      = 6'h00;
    localparam [5:0] ADDR_INT_STATUS    = 6'h04;
    localparam [5:0] ADDR_INT_ACK       = 6'h08;
    localparam [5:0] ADDR_RING_LOW      = 6'h0C;
    localparam [5:0] ADDR_RING_HIGH     = 6'h10;
    localparam [5:0] ADDR_PT_LOW        = 6'h14;
    localparam [5:0] ADDR_PT_HIGH       = 6'h18;
    localparam [5:0] ADDR_UVM_MODE      = 6'h20;

    reg [31:0] int_status_reg;
    reg        aw_en;
    reg        axi_awready_reg;
    reg        axi_wready_reg;
    reg [1:0]  axi_bresp_reg;
    reg        axi_bvalid_reg;
    reg        axi_arready_reg;
    reg [31:0] axi_rdata_reg;
    reg [1:0]  axi_rresp_reg;
    reg        axi_rvalid_reg;

    assign s_axi_awready = axi_awready_reg;
    assign s_axi_wready  = axi_wready_reg;
    assign s_axi_bresp   = axi_bresp_reg;
    assign s_axi_bvalid  = axi_bvalid_reg;
    assign s_axi_arready = axi_arready_reg;
    assign s_axi_rdata   = axi_rdata_reg;
    assign s_axi_rresp   = axi_rresp_reg;
    assign s_axi_rvalid  = axi_rvalid_reg;

    // AXI-Lite Write Handling
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            axi_awready_reg        <= 1'b0;
            axi_wready_reg         <= 1'b0;
            axi_bvalid_reg         <= 1'b0;
            axi_bresp_reg          <= 2'b00;
            aw_en                  <= 1'b1;
            doorbell_pulse         <= 1'b0;
            irq_ack_pulse          <= 1'b0;
            reg_ring_dma_addr      <= 64'd0;
            reg_pagetable_dma_addr <= 64'd0;
            reg_uvm_mode           <= 32'd0;
            int_status_reg         <= 32'd0;
        end else begin
            doorbell_pulse <= 1'b0;
            irq_ack_pulse  <= 1'b0;

            if (task_done_irq)
                int_status_reg[0] <= 1'b1;

            if (~axi_awready_reg && s_axi_awvalid && s_axi_wvalid && aw_en) begin
                axi_awready_reg <= 1'b1;
                axi_wready_reg  <= 1'b1;
                aw_en           <= 1'b0;
            end else begin
                axi_awready_reg <= 1'b0;
                axi_wready_reg  <= 1'b0;
            end

            if (s_axi_awvalid && s_axi_wvalid && axi_awready_reg && axi_wready_reg) begin
                case (s_axi_awaddr[5:0])
                    ADDR_DOORBELL:  doorbell_pulse            <= (s_axi_wdata != 0);
                    ADDR_INT_ACK:   begin
                        int_status_reg[0] <= 1'b0;
                        irq_ack_pulse     <= 1'b1;
                    end
                    ADDR_RING_LOW:  reg_ring_dma_addr[31:0]   <= s_axi_wdata;
                    ADDR_RING_HIGH: reg_ring_dma_addr[63:32]  <= s_axi_wdata;
                    ADDR_PT_LOW:    reg_pagetable_dma_addr[31:0]  <= s_axi_wdata;
                    ADDR_PT_HIGH:   reg_pagetable_dma_addr[63:32] <= s_axi_wdata;
                    ADDR_UVM_MODE:  reg_uvm_mode              <= s_axi_wdata;
                    default: ;
                endcase
            end

            if (~axi_bvalid_reg && axi_awready_reg && s_axi_awvalid && axi_wready_reg && s_axi_wvalid) begin
                axi_bvalid_reg <= 1'b1;
                axi_bresp_reg  <= 2'b00; // OKAY
            end else if (s_axi_bready && axi_bvalid_reg) begin
                axi_bvalid_reg <= 1'b0;
                aw_en          <= 1'b1;
            end
        end
    end

    // AXI-Lite Read Handling
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            axi_arready_reg <= 1'b0;
            axi_rvalid_reg  <= 1'b0;
            axi_rresp_reg   <= 2'b00;
            axi_rdata_reg   <= 32'd0;
        end else begin
            if (~axi_arready_reg && s_axi_arvalid) begin
                axi_arready_reg <= 1'b1;
            end else begin
                axi_arready_reg <= 1'b0;
            end

            if (axi_arready_reg && s_axi_arvalid && ~axi_rvalid_reg) begin
                axi_rvalid_reg <= 1'b1;
                axi_rresp_reg  <= 2'b00; // OKAY
                case (s_axi_araddr[5:0])
                    ADDR_INT_STATUS: axi_rdata_reg <= int_status_reg;
                    ADDR_RING_LOW:   axi_rdata_reg <= reg_ring_dma_addr[31:0];
                    ADDR_RING_HIGH:  axi_rdata_reg <= reg_ring_dma_addr[63:32];
                    ADDR_PT_LOW:     axi_rdata_reg <= reg_pagetable_dma_addr[31:0];
                    ADDR_PT_HIGH:    axi_rdata_reg <= reg_pagetable_dma_addr[63:32];
                    ADDR_UVM_MODE:   axi_rdata_reg <= reg_uvm_mode;
                    default:         axi_rdata_reg <= 32'hDEADBEEF;
                endcase
            end else if (axi_rvalid_reg && s_axi_rready) begin
                axi_rvalid_reg <= 1'b0;
            end
        end
    end

endmodule

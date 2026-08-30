`timescale 1ns / 1ps
// GPC L2 Shared Cache & AXI4 Master
// Services L1 misses from multiple SMs and interfaces with DDR3 via AXI4.
// Capacity: 16KB (512 lines x 32 Bytes) Direct Mapped, Write-Through

module l2_cache (
    input wire clk,
    input wire rst_n,

    // L1 Cache Interfaces (From 2 SMs)
    input wire sm0_req_valid,
    input wire [31:0] sm0_req_addr,
    input wire [255:0]sm0_req_wdata,
    input wire [31:0] sm0_req_wstrb,
    input wire sm0_req_we,
    output wire sm0_req_ready,
    output reg sm0_rsp_valid,
    output reg [255:0]sm0_rsp_rdata,

    input wire sm1_req_valid,
    input wire [31:0] sm1_req_addr,
    input wire [255:0]sm1_req_wdata,
    input wire [31:0] sm1_req_wstrb,
    input wire sm1_req_we,
    output wire sm1_req_ready,
    output reg sm1_rsp_valid,
    output reg [255:0]sm1_rsp_rdata,

    // AXI4-Full Master Interface (To DDR3)
    output reg m_axi_awvalid,
    output reg [31:0] m_axi_awaddr,
    output reg [7:0] m_axi_awlen,
    output reg [2:0] m_axi_awsize,
    output reg [1:0] m_axi_awburst,
    input wire m_axi_awready,

    output reg m_axi_wvalid,
    output reg [255:0]m_axi_wdata,
    output reg [31:0] m_axi_wstrb,
    output reg m_axi_wlast,
    input wire m_axi_wready,

    input wire m_axi_bvalid,
    output reg m_axi_bready,

    output reg m_axi_arvalid,
    output reg [31:0] m_axi_araddr,
    output reg [7:0] m_axi_arlen,
    output reg [2:0] m_axi_arsize,
    output reg [1:0] m_axi_arburst,
    input wire m_axi_arready,

    input wire m_axi_rvalid,
    input wire [255:0]m_axi_rdata,
    input wire m_axi_rlast,
    output reg m_axi_rready
);

    // Round-Robin Arbiter for L1 Requests
    reg current_sm; // 0 = SM0, 1 = SM1
    
    wire req_valid = (current_sm == 0) ? sm0_req_valid : sm1_req_valid;
    wire [31:0] req_addr = (current_sm == 0) ? sm0_req_addr : sm1_req_addr;
    wire [255:0]req_wdata = (current_sm == 0) ? sm0_req_wdata : sm1_req_wdata;
    wire [31:0] req_wstrb = (current_sm == 0) ? sm0_req_wstrb : sm1_req_wstrb;
    wire req_we = (current_sm == 0) ? sm0_req_we : sm1_req_we;
    
    reg req_ready_internal;
    assign sm0_req_ready = (current_sm == 0) ? req_ready_internal : 1'b0;
    assign sm1_req_ready = (current_sm == 1) ? req_ready_internal : 1'b0;

    // Cache Parameters & Storage
    // 32-bit Address = [31:14] Tag (18 bits) | [13:5] Index (9 bits) | [4:0] Offset (5 bits)
    // 512 lines * 32 Bytes = 16KB
    localparam NUM_LINES = 512;
    wire [17:0] req_tag = req_addr[31:14];
    wire [8:0] req_index = req_addr[13:5];
    
    (* ram_style = "distributed" *) reg [17:0] tag_ram [0:NUM_LINES-1];
    (* ram_style = "distributed" *) reg valid_ram [0:NUM_LINES-1];

    integer i;
    initial begin
        for (i=0; i<NUM_LINES; i=i+1) begin
            valid_ram[i] = 1'b0;
        end
    end

    // Strict BRAM Template for Data RAM (Vivado Inference)
    (* ram_style = "block" *) reg [255:0] data_ram [0:NUM_LINES-1];
    reg [255:0] data_ram_dout;
    reg data_ram_we;
    reg [255:0] data_ram_wdata;
    
    // Latched request for pipeline
    reg [31:0] latched_req_addr;
    reg [255:0] latched_req_wdata;
    reg [31:0] latched_req_wstrb;
    reg latched_req_we;
    reg [17:0] latched_req_tag;
    reg [8:0] latched_req_index;

    wire [8:0] data_ram_addr = (state == STATE_IDLE) ? req_index : latched_req_index;

    always @(posedge clk) begin
        if (data_ram_we) begin
            data_ram[data_ram_addr] <= data_ram_wdata;
        end
        // Synchronous Read
        data_ram_dout <= data_ram[data_ram_addr];
    end

    // FSM
    localparam STATE_IDLE = 3'd0;
    localparam STATE_HIT_RETURN = 3'd1;
    localparam STATE_AXI_AR = 3'd2;
    localparam STATE_AXI_R = 3'd3;
    localparam STATE_AXI_AW = 3'd4;
    localparam STATE_AXI_W = 3'd5;
    localparam STATE_AXI_B = 3'd6;
    localparam STATE_COMPARE = 3'd7;
    
    reg [2:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            current_sm <= 1'b0;
            req_ready_internal <= 1'b1;
            sm0_rsp_valid <= 1'b0;
            sm1_rsp_valid <= 1'b0;
            
            m_axi_awvalid <= 1'b0;
            m_axi_wvalid <= 1'b0;
            m_axi_bready <= 1'b1; // Always ready for B
            m_axi_arvalid <= 1'b0;
            m_axi_rready <= 1'b0;
        end else begin
            data_ram_we <= 1'b0;
            sm0_rsp_valid <= 1'b0;
            sm1_rsp_valid <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    if (req_valid && req_ready_internal) begin
                        req_ready_internal <= 1'b0;
                        
                        // Latch request to break timing path from arbiter (current_sm)
                        latched_req_addr <= req_addr;
                        latched_req_wdata <= req_wdata;
                        latched_req_wstrb <= req_wstrb;
                        latched_req_we <= req_we;
                        latched_req_tag <= req_tag;
                        latched_req_index <= req_index;
                        
                        state <= STATE_COMPARE;
                    end else begin
                        // Toggle arbiter if current has no request, but the other might
                        if (!req_valid) begin
                            current_sm <= ~current_sm;
                        end
                    end
                end

                STATE_COMPARE: begin
                    // Check Hit
                    if (valid_ram[latched_req_index] && (tag_ram[latched_req_index] == latched_req_tag)) begin
                        // L2 HIT
                        if (latched_req_we) begin
                            // Write-Through to DDR3
                            // Also invalidate L2 on write for simplicity
                            valid_ram[latched_req_index] <= 1'b0;
                            
                            m_axi_awvalid <= 1'b1;
                            m_axi_awaddr <= latched_req_addr; // Address is 32-byte aligned from L1
                            m_axi_awlen <= 8'd0; // 1 beat of 256-bit
                            m_axi_awsize <= 3'b101; // 2^5 = 32 bytes
                            m_axi_awburst <= 2'b01; // INCR
                            state <= STATE_AXI_AW;
                        end else begin
                            // Read Hit
                            // The BRAM read address was presented in STATE_COMPARE.
                            // In the next cycle (STATE_HIT_RETURN), data_ram_dout will be valid.
                            state <= STATE_HIT_RETURN;
                        end
                    end else begin
                        // L2 MISS
                        if (latched_req_we) begin
                            // Write-Miss: Send directly to DDR3
                            m_axi_awvalid <= 1'b1;
                            m_axi_awaddr <= latched_req_addr;
                            m_axi_awlen <= 8'd0;
                            m_axi_awsize <= 3'b101;
                            m_axi_awburst <= 2'b01;
                            state <= STATE_AXI_AW;
                        end else begin
                            // Read-Miss: Fetch from DDR3
                            m_axi_arvalid <= 1'b1;
                            m_axi_araddr <= latched_req_addr;
                            m_axi_arlen <= 8'd0; // 1 beat of 256-bit
                            m_axi_arsize <= 3'b101; // 32 bytes
                            m_axi_arburst <= 2'b01; // INCR
                            state <= STATE_AXI_AR;
                        end
                    end
                end

                STATE_HIT_RETURN: begin
                    if (current_sm == 0) begin
                        sm0_rsp_valid <= 1'b1;
                        sm0_rsp_rdata <= data_ram_dout;
                    end else begin
                        sm1_rsp_valid <= 1'b1;
                        sm1_rsp_rdata <= data_ram_dout;
                    end
                    req_ready_internal <= 1'b1;
                    current_sm <= ~current_sm;
                    state <= STATE_IDLE;
                end

                // --- READ PATH ---
                STATE_AXI_AR: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready <= 1'b1;
                        state <= STATE_AXI_R;
                    end
                end
                STATE_AXI_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        m_axi_rready <= 1'b0;
                        // Refill L2 Cache
                        valid_ram[latched_req_index] <= 1'b1;
                        tag_ram[latched_req_index] <= latched_req_tag;
                        
                        data_ram_we <= 1'b1;
                        data_ram_wdata <= m_axi_rdata;
                        
                        // Return to L1
                        if (current_sm == 0) begin
                            sm0_rsp_valid <= 1'b1;
                            sm0_rsp_rdata <= m_axi_rdata;
                        end else begin
                            sm1_rsp_valid <= 1'b1;
                            sm1_rsp_rdata <= m_axi_rdata;
                        end
                        
                        req_ready_internal <= 1'b1;
                        current_sm <= ~current_sm;
                        state <= STATE_IDLE;
                    end
                end

                // --- WRITE PATH ---
                STATE_AXI_AW: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                        m_axi_wvalid <= 1'b1;
                        m_axi_wdata <= latched_req_wdata;
                        m_axi_wstrb <= latched_req_wstrb;
                        m_axi_wlast <= 1'b1;
                        state <= STATE_AXI_W;
                    end
                end
                STATE_AXI_W: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        m_axi_wvalid <= 1'b0;
                        m_axi_wlast <= 1'b0;
                        state <= STATE_AXI_B;
                    end
                end
                STATE_AXI_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        // Write complete
                        if (current_sm == 0) begin
                            sm0_rsp_valid <= 1'b1; // ACK
                        end else begin
                            sm1_rsp_valid <= 1'b1;
                        end
                        req_ready_internal <= 1'b1;
                        current_sm <= ~current_sm;
                        state <= STATE_IDLE;
                    end
                end
            endcase
        end
    end

endmodule

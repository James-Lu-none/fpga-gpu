`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////--
// Hardware Engine (AXI-Lite Slave + Command Dispatch)
// SIMT Refactor Phase 4
////////////////////////////////////////////////////////////////////////////////--

module gpu_streaming_multiprocessor (
    input  wire                              clk,
    input  wire                              rst_n,

    // AXI4-Lite Slave Interface (From RISC-V)
    axi_lite_if.slave                        s_axi_lite,

    // 256-bit AXI4-Full Master Interface
    axi4_if.master                           m_axi_gmem,

    // Framebuffer Parallel Render Output Interface (from SM Core)
    output wire                              fb_we,
    output wire [18:0]                       fb_addr,
    output wire [23:0]                       fb_rgb
);
    // ---------------------------------------------------------------------
    // Hardware Engine Master FSM
    // ---------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_gmem.araddr  <= 32'd0;
            m_axi_gmem.arlen   <= 8'd0;
            m_axi_gmem.arvalid <= 1'b0;
            m_axi_gmem.rready  <= 1'b1;
            m_axi_gmem.awaddr  <= 32'd0;
            m_axi_gmem.awlen   <= 8'd0;
            m_axi_gmem.awvalid <= 1'b0;
            m_axi_gmem.wdata   <= 256'd0;
            m_axi_gmem.wstrb   <= 32'hFFFFFFFF;
            m_axi_gmem.wvalid  <= 1'b0;
            m_axi_gmem.bready  <= 1'b1;
            state              <= ST_IDLE;
            tile_cnt           <= 8'd0;
            dma_smem_we        <= 1'b0;
            dma_smem_waddr     <= 8'd0;
            dma_smem_wdata     <= 64'd0;
        end else begin
            dma_smem_we   <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (hw_trigger) begin
                        state <= ST_WARP_SCHED;
                    end
                end

                ST_WARP_SCHED: begin
                    if (sched_grid_done) begin
                        // Grid issued, proceed to store (simplified)
                        m_axi_gmem.awaddr  <= dst_addr;
                        m_axi_gmem.awlen   <= 8'd255;
                        m_axi_gmem.awvalid <= 1'b1;
                        tile_cnt           <= 8'd0;
                        state              <= ST_TILE_STORE;
                    end
                end

                ST_TILE_STORE: begin
                    if (m_axi_gmem.awvalid && m_axi_gmem.awready) begin
                        m_axi_gmem.awvalid <= 1'b0;
                    end

                    m_axi_gmem.wdata  <= {192'd0, smem_ram[tile_cnt]};
                    m_axi_gmem.wstrb  <= 32'hFFFFFFFF;
                    m_axi_gmem.wvalid <= 1'b1;

                    if (m_axi_gmem.wvalid && m_axi_gmem.wready) begin
                        if (tile_cnt == 8'd255) begin
                            m_axi_gmem.wvalid <= 1'b0;
                            state             <= ST_DONE;
                        end else begin
                            tile_cnt <= tile_cnt + 8'd1;
                        end
                    end
                end

                ST_DONE: begin
                    // Wait for grid_done_reg to be cleared by software INT_ACK
                    if (!grid_done_reg) begin
                        state <= ST_IDLE;
                    end
                end
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // AXI-Lite Register Map & I-RAM Loader
    // 0x0000 ~ 0x00FF : Control Registers
    //   0x00: REG_DOORBELL (Write 1 to start)
    //   0x04: REG_INT_STATUS (Bit 0: Grid Done)
    //   0x08: REG_INT_ACK (Write 1 to clear INT_STATUS)
    //   0x0C: REG_GRID_DIM_X
    //   0x10: REG_GRID_DIM_Y
    //   0x14: REG_BLOCK_DIM_X
    //   0x18: REG_BLOCK_DIM_Y
    //   0x20: REG_SRC_ADDR
    //   0x24: REG_DST_ADDR
    // 0x1000 ~ 0x1FFF : I-RAM (4KB)
    // ---------------------------------------------------------------------
    // these register map replaces the orignal 1KB bram shared between hardware engine and risc-v cpu
    // and the raw wire interrupt signal

    reg [31:0] src_addr;
    reg [31:0] dst_addr;
    reg [15:0] grid_dim_x, grid_dim_y;
    reg [15:0] block_dim_x, block_dim_y;
    reg        hw_trigger;
    reg        grid_done_reg;

    // AXI-Lite Write Channels
    assign s_axi_lite.awready = 1'b1;
    assign s_axi_lite.wready  = 1'b1;
    assign s_axi_lite.bvalid  = s_axi_lite.wvalid && s_axi_lite.awvalid;
    assign s_axi_lite.bresp   = 2'b00;

    // AXI-Lite Read Channels
    assign s_axi_lite.arready = 1'b1;
    assign s_axi_lite.rvalid  = s_axi_lite.arvalid;
    assign s_axi_lite.rresp   = 2'b00;

    reg iram_we_reg;
    reg [11:0] iram_waddr_reg;
    reg [31:0] iram_wdata_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hw_trigger <= 1'b0;
            grid_done_reg <= 1'b0;
            grid_dim_x <= 16'd1;
            grid_dim_y <= 16'd1;
            block_dim_x <= 16'd1;
            block_dim_y <= 16'd1;
            src_addr <= 32'd0;
            dst_addr <= 32'd0;
            
            iram_we_reg <= 1'b0;
            iram_waddr_reg <= 12'd0;
            iram_wdata_reg <= 32'd0;
        end else begin
            iram_we_reg <= 1'b0;
            hw_trigger  <= 1'b0; // Auto-clear pulse

            // Write Logic
            if (s_axi_lite.awvalid && s_axi_lite.wvalid) begin
                if (s_axi_lite.awaddr[12]) begin
                    // 0x1000 ~ 0x1FFF : I-RAM Word Write (Convert byte addr to word addr)
                    iram_we_reg    <= 1'b1;
                    iram_waddr_reg <= {2'b00, s_axi_lite.awaddr[11:2]};
                    iram_wdata_reg <= s_axi_lite.wdata;
                end else begin
                    // 0x0000 ~ 0x0FFF : Control Registers
                    case (s_axi_lite.awaddr[7:0])
                        8'h00: hw_trigger <= s_axi_lite.wdata[0];
                        8'h08: grid_done_reg <= 1'b0; // INT_ACK clears done flag
                        8'h0C: grid_dim_x <= s_axi_lite.wdata[15:0];
                        8'h10: grid_dim_y <= s_axi_lite.wdata[15:0];
                        8'h14: block_dim_x <= s_axi_lite.wdata[15:0];
                        8'h18: block_dim_y <= s_axi_lite.wdata[15:0];
                        8'h20: src_addr <= s_axi_lite.wdata;
                        8'h24: dst_addr <= s_axi_lite.wdata;
                    endcase
                end
            end
            
            // Set done flag when grid finishes
            if (state == ST_DONE) begin
                grid_done_reg <= 1'b1;
            end
        end
    end

    // Read Logic
    reg [31:0] rdata_reg;
    always @(*) begin
        rdata_reg = 32'd0;
        if (!s_axi_lite.araddr[12]) begin
            case (s_axi_lite.araddr[7:0])
                8'h04: rdata_reg = {31'd0, grid_done_reg};
                8'h0C: rdata_reg = {16'd0, grid_dim_x};
                8'h10: rdata_reg = {16'd0, grid_dim_y};
                8'h14: rdata_reg = {16'd0, block_dim_x};
                8'h18: rdata_reg = {16'd0, block_dim_y};
                8'h20: rdata_reg = src_addr;
                8'h24: rdata_reg = dst_addr;
            endcase
        end
    end
    assign s_axi_lite.rdata = rdata_reg;


    // ---------------------------------------------------------------------
    // CUDA Shared Memory (Legacy Support for Load/Store Pipeline)
    // ---------------------------------------------------------------------
    (* ram_style = "distributed" *)
    reg [63:0] smem_ram [0:255];

    wire        sm_smem_we;
    wire [7:0]  sm_smem_waddr;
    wire [63:0] sm_smem_wdata;
    wire [7:0]  sm_smem_raddr;
    reg  [63:0] smem_rdata;

    reg         dma_smem_we;
    reg  [7:0]  dma_smem_waddr;
    reg  [63:0] dma_smem_wdata;

    wire        smem_we_final    = dma_smem_we | sm_smem_we;
    wire [7:0]  smem_waddr_final = dma_smem_we ? dma_smem_waddr : sm_smem_waddr;
    wire [63:0] smem_wdata_final = dma_smem_we ? dma_smem_wdata : sm_smem_wdata;

    always @(posedge clk) begin
        if (smem_we_final) begin
            smem_ram[smem_waddr_final] <= smem_wdata_final;
        end
        smem_rdata <= smem_ram[sm_smem_raddr];
    end

    // ---------------------------------------------------------------------
    // FSM State and Registers
    // ---------------------------------------------------------------------
    localparam ST_IDLE       = 3'd0,
               ST_WARP_SCHED = 3'd1,
               ST_TILE_STORE = 3'd2,
               ST_DONE       = 3'd3;

    reg [2:0] state;
    reg [7:0] tile_cnt;

    // ---------------------------------------------------------------------
    // Sub-Core (Processing Block) and Warp Allocator Instances
    // ---------------------------------------------------------------------
    wire        warp_valid;
    wire        warp_ready = 1'b1; // Auto accept
    wire [15:0] current_warp_id;
    wire [15:0] current_block_id;
    wire [31:0] active_mask;
    wire [15:0] thread_id_start;
    wire        sched_grid_done;

    sm_warp_allocator u_warp_sched (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .launch_en              (state == ST_WARP_SCHED),
        .grid_dim_x             (grid_dim_x),
        .grid_dim_y             (grid_dim_y),
        .block_dim_x            (block_dim_x),
        .block_dim_y            (block_dim_y),
        .warp_valid             (warp_valid),
        .warp_ready             (warp_ready),
        .current_warp_id        (current_warp_id),
        .current_block_id       (current_block_id),
        .active_mask            (active_mask),
        .thread_id_start        (thread_id_start),
        .grid_done              (sched_grid_done)
    );

    sm_processing_block u_sm_core (
        .clk                    (clk),
        .rst_n                  (rst_n),
        
        // I-RAM DMA Load Interface (From AXI-Lite)
        .iram_we                (iram_we_reg),
        .iram_waddr             (iram_waddr_reg),
        .iram_wdata             (iram_wdata_reg),

        // Warp Allocation / Launch Interface (From Scheduler)
        .alloc_valid            (warp_valid),
        .alloc_ready            (warp_ready), // Note: ignoring internal sm_core ready for this simplified integration
        .alloc_block_id         (current_block_id),
        .alloc_active_mask      (active_mask),

        // Legacy Interfaces
        .smem_raddr             (sm_smem_raddr),
        .smem_rdata             (smem_rdata),
        .smem_we                (sm_smem_we),
        .smem_waddr             (sm_smem_waddr),
        .smem_wdata             (sm_smem_wdata),
        .fb_we                  (fb_we),
        .fb_addr                (fb_addr),
        .fb_rgb                 (fb_rgb)
    );

    // ---------------------------------------------------------------------
    // AXI4-Full Static Assignments
    // ---------------------------------------------------------------------
    assign m_axi_gmem.awid    = 1'b0;
    assign m_axi_gmem.awsize  = 3'd5; // 32 bytes (256-bit)
    assign m_axi_gmem.awburst = 2'b01; // INCR
    assign m_axi_gmem.awlock  = 1'b0;
    assign m_axi_gmem.awcache = 4'b0011;
    assign m_axi_gmem.awprot  = 3'b000;
    assign m_axi_gmem.awqos   = 4'd0;
    
    assign m_axi_gmem.arid    = 1'b0;
    assign m_axi_gmem.arsize  = 3'd5; // 32 bytes (256-bit)
    assign m_axi_gmem.arburst = 2'b01; // INCR
    assign m_axi_gmem.arlock  = 1'b0;
    assign m_axi_gmem.arcache = 4'b0011;
    assign m_axi_gmem.arprot  = 3'b000;
    assign m_axi_gmem.arqos   = 4'd0;
    
    assign m_axi_gmem.wlast   = (tile_cnt == 8'd255);

endmodule

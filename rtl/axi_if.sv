`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////--
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/26
// Design Name: Standard AMBA AXI4 SystemVerilog Interface Package
// Module Name: axi_if
// Project Name: fpga-gpu (Accelerated Computing with Linux Kernel vGPU-Core)
// Target Devices: Xilinx Artix-7 (XC7A200T-2FBG484)
// Tool Versions: Vivado 2026+
// Description: 
//   Standard SystemVerilog AXI4 Bus Interface Bundle to simplify inter-module
//   AXI bus connections (XDMA, Crossbar, MIG DDR3, GPGPU SM Compute Engine).
////////////////////////////////////////////////////////////////////////////////--

interface axi4_if #(
    parameter integer ADDR_W = 32,
    parameter integer DATA_W = 256,
    parameter integer ID_W   = 1
);
    // Write Address Channel
    logic [ID_W-1:0]     awid;
    logic [ADDR_W-1:0]   awaddr;
    logic [7:0]          awlen;
    logic [2:0]          awsize;
    logic [1:0]          awburst;
    logic                awlock;
    logic [3:0]          awcache;
    logic [2:0]          awprot;
    logic [3:0]          awqos;
    logic                awvalid;
    logic                awready;

    // Write Data Channel
    logic [DATA_W-1:0]   wdata;
    logic [(DATA_W/8)-1:0] wstrb;
    logic                wlast;
    logic                wvalid;
    logic                wready;

    // Write Response Channel
    logic [ID_W-1:0]     bid;
    logic [1:0]          bresp;
    logic                bvalid;
    logic                bready;

    // Read Address Channel
    logic [ID_W-1:0]     arid;
    logic [ADDR_W-1:0]   araddr;
    logic [7:0]          arlen;
    logic [2:0]          arsize;
    logic [1:0]          arburst;
    logic                arlock;
    logic [3:0]          arcache;
    logic [2:0]          arprot;
    logic [3:0]          arqos;
    logic                arvalid;
    logic                arready;

    // Read Data Channel
    logic [ID_W-1:0]     rid;
    logic [DATA_W-1:0]   rdata;
    logic [1:0]          rresp;
    logic                rlast;
    logic                rvalid;
    logic                rready;

    // Master Modport (For Drivers / Masters like XDMA & GPGPU Core)
    modport master (
        output awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awvalid,
        input  awready,
        output wdata, wstrb, wlast, wvalid,
        input  wready,
        input  bid, bresp, bvalid,
        output bready,
        output arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arvalid,
        input  arready,
        input  rid, rdata, rresp, rlast, rvalid,
        output rready
    );

    // Slave Modport (For Receivers / Slaves like Crossbar & MIG DDR3)
    modport slave (
        input  awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awvalid,
        output awready,
        input  wdata, wstrb, wlast, wvalid,
        output wready,
        output bid, bresp, bvalid,
        input  bready,
        input  arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arvalid,
        output arready,
        output rid, rdata, rresp, rlast, rvalid,
        input  rready
    );

endinterface

interface axi_lite_if #(
    parameter integer ADDR_W = 32,
    parameter integer DATA_W = 32
);
    // Write Address Channel
    logic [ADDR_W-1:0]   awaddr;
    logic [2:0]          awprot;
    logic                awvalid;
    logic                awready;

    // Write Data Channel
    logic [DATA_W-1:0]   wdata;
    logic [(DATA_W/8)-1:0] wstrb;
    logic                wvalid;
    logic                wready;

    // Write Response Channel
    logic [1:0]          bresp;
    logic                bvalid;
    logic                bready;

    // Read Address Channel
    logic [ADDR_W-1:0]   araddr;
    logic [2:0]          arprot;
    logic                arvalid;
    logic                arready;

    // Read Data Channel
    logic [DATA_W-1:0]   rdata;
    logic [1:0]          rresp;
    logic                rvalid;
    logic                rready;

    // Master Modport
    modport master (
        output awaddr, awprot, awvalid,
        input  awready,
        output wdata, wstrb, wvalid,
        input  wready,
        input  bresp, bvalid,
        output bready,
        output araddr, arprot, arvalid,
        input  arready,
        input  rdata, rresp, rvalid,
        output rready
    );

    // Slave Modport
    modport slave (
        input  awaddr, awprot, awvalid,
        output awready,
        input  wdata, wstrb, wvalid,
        output wready,
        output bresp, bvalid,
        input  bready,
        input  araddr, arprot, arvalid,
        output arready,
        output rdata, rresp, rvalid,
        input  rready
    );

endinterface

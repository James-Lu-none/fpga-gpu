`timescale 1ns / 1ps

package gpu_pkg;
    // Architecture Parameters
    parameter NUM_SMS = 1;
    parameter MAX_WARPS = 8;
    parameter NUM_REGS = 32;
    parameter NUM_LANES = 2;
    parameter DATA_W = 32 * NUM_LANES;
    parameter IRAM_DEPTH = 1024;
    parameter WARP_SIZE = 32;
endpackage

`ifndef GPU_MEMORY_MAP_VH
`define GPU_MEMORY_MAP_VH

// Global GPU SoC Memory Map Definitions

// 1. RISC-V Local BRAM (Instruction/Data/Mailbox) 
// Base Address Region: 0x0000_XXXX
`define ADDR_BASE_BRAM 16'h0000

// PicoRV32 Configuration Addresses
`define BRAM_PROGADDR_RESET 32'h0000_0000
`define BRAM_PROGADDR_IRQ   32'h0000_0010
`define BRAM_STACKADDR      32'h0001_0000 // Stack grows downwards from 64KB

// Shared BRAM regions at the top of 128KB
`define BRAM_RING_BUFFER_BASE 32'h0001_8000 // GPU Command Queue
`define BRAM_IRQ_BASE         32'h0001_FFE0 // IRQ register (1FFE0 to 1FFEF)
`define BRAM_CPU_RESET_BASE   32'h0001_FFF0 // CPU Soft Reset Control Register (1FFF0 to 1FFFF)


// 2. Graphics Processing Cluster (GPC / SM)
// Base Address Region: 0x1000_XXXX
`define ADDR_BASE_GPC 16'h1000

// Hardware Engine / SM Registers Offset (from 0x1000_0000)
`define GPU_REGS_OFFSET 32'h0000_0000 

// Instruction RAM Offset for Fetch/Decode Unit (from 0x1000_1000)
`define GPU_IRAM_OFFSET 32'h0000_1000

// 3. HDMI I2C Controller
// Base Address Region: 0x5000_XXXX
`define ADDR_BASE_HDMI 16'h5000

`endif // GPU_MEMORY_MAP_VH

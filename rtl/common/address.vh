`ifndef GPU_MEMORY_MAP_VH
`define GPU_MEMORY_MAP_VH

// Global GPU SoC Memory Map Definitions

// 1. RISC-V Local BRAM (Instruction/Data/Mailbox) 
// Base Address Region: 0x0000_XXXX
`define ADDR_BASE_BRAM 16'h0000

// PicoRV32 Configuration Addresses
`define BRAM_PROGADDR_RESET 32'h0000_0000
`define BRAM_PROGADDR_IRQ 32'h0000_0010
`define BRAM_STACKADDR 32'h0000_3E00

// PCIe to RISC-V Direct Mailbox Window (256 bytes)
`define BRAM_MAILBOX_BASE 32'h0000_3F00

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

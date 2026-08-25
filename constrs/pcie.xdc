# =========================================================================
# ALINX AX7A200B (XC7A200T-2FBG484) PCIe Constraints (PCIe 2.0 x2)
# =========================================================================

# -------------------------------------------------------------------------
# PCIe 100MHz Reference Clock (Bank 216 MGTREFCLK0: F10/E10)
# Matches ALINX AX7A200B Manual: PCIE_CLK_P -> F10
# -------------------------------------------------------------------------
set_property PACKAGE_PIN F10 [get_ports sys_clk_clk_p]
set_property PACKAGE_PIN E10 [get_ports sys_clk_clk_n]
create_clock -period 10.000 -name sys_clk [get_ports sys_clk_clk_p]

# -------------------------------------------------------------------------
# PCIe System Reset (PCIE_PERST - Temporarily assigned to dummy GPIO M13 to avoid T18 HDMI_HS collision)
# -------------------------------------------------------------------------
set_property PACKAGE_PIN M13 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]
set_property PULLUP true [get_ports sys_rst_n]

# -------------------------------------------------------------------------
# Prevent Vivado opt_design from trimming XDMA PCIe Hard Macro reset cells (Opt 31-67)
# -------------------------------------------------------------------------
set_property DONT_TOUCH true [get_cells -hierarchical -filter {NAME =~ *u_xdma*}]


# -------------------------------------------------------------------------
# Configuration Voltage & SPI Flash Bitstream Options
# -------------------------------------------------------------------------
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]

# =========================================================================
# ALINX AX7A200B (XC7A200T-2FBG484) PCIe Constraints (PCIe 2.0 x2)
# =========================================================================

# -------------------------------------------------------------------------
# PCIe 100MHz Reference Clock (Bank 216 MGTREFCLK0: F10/E10)
# Matches ALINX AX7A200B Manual: PCIE_CLK_P -> F10, PCIE_CLK_N -> E10
# -------------------------------------------------------------------------
set_property PACKAGE_PIN F10 [get_ports sys_clk]
create_clock -period 10.000 -name sys_clk [get_ports sys_clk]

# -------------------------------------------------------------------------
# PCIe System Reset (PCIE_PERST from PCIe Edge Connector)
# -------------------------------------------------------------------------
set_property PACKAGE_PIN T18 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]
set_property PULLUP true [get_ports sys_rst_n]

# -------------------------------------------------------------------------
# Transceiver Note:
# Artix-7 uses GTP (Gigabit Transceiver with low Power) Transceivers (Bank 216: D9/C9, B10/A10, D7/C7, B6/A6).
# Since sys_clk is locked to F10/E10 (MGTREFCLK0 of Quad 216), Vivado
# automatically binds PCIe x2 lanes (Lane 0 & Lane 1) to the dedicated
# hard GTP transceiver pins, so we don't have to set the LOC constraints for them.
# -------------------------------------------------------------------------

# -------------------------------------------------------------------------
# Configuration Voltage & SPI Flash Bitstream Options
# -------------------------------------------------------------------------
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]

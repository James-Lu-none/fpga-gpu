# =========================================================================
# ALINX AX7A200B (XC7A200T-2FBG484) SiI9134 HDMI Output Pin Constraints
# =========================================================================

# -------------------------------------------------------------------------
# HDMI Control & Clock Signals
# -------------------------------------------------------------------------
set_property PACKAGE_PIN Y17 [get_ports hdmi_nreset]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_nreset]

set_property PACKAGE_PIN Y22 [get_ports hdmi_clk]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_clk]

set_property PACKAGE_PIN T18 [get_ports hdmi_hs]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_hs]

set_property PACKAGE_PIN R18 [get_ports hdmi_vs]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_vs]

set_property PACKAGE_PIN U22 [get_ports hdmi_de]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_de]

# -------------------------------------------------------------------------
# HDMI 24-bit RGB Video Data Bus (D[23:0])
# -------------------------------------------------------------------------
set_property PACKAGE_PIN V22 [get_ports {hdmi_d[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[0]}]

set_property PACKAGE_PIN Y18 [get_ports {hdmi_d[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[1]}]

set_property PACKAGE_PIN Y19 [get_ports {hdmi_d[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[2]}]

set_property PACKAGE_PIN W19 [get_ports {hdmi_d[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[3]}]

set_property PACKAGE_PIN W20 [get_ports {hdmi_d[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[4]}]

set_property PACKAGE_PIN Y21 [get_ports {hdmi_d[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[5]}]

set_property PACKAGE_PIN U21 [get_ports {hdmi_d[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[6]}]

set_property PACKAGE_PIN T21 [get_ports {hdmi_d[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[7]}]

set_property PACKAGE_PIN W21 [get_ports {hdmi_d[8]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[8]}]

set_property PACKAGE_PIN W22 [get_ports {hdmi_d[9]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[9]}]

set_property PACKAGE_PIN T20 [get_ports {hdmi_d[10]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[10]}]

set_property PACKAGE_PIN AB18 [get_ports {hdmi_d[11]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[11]}]

set_property PACKAGE_PIN AA18 [get_ports {hdmi_d[12]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[12]}]

set_property PACKAGE_PIN AA19 [get_ports {hdmi_d[13]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[13]}]

set_property PACKAGE_PIN AB20 [get_ports {hdmi_d[14]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[14]}]

set_property PACKAGE_PIN AA20 [get_ports {hdmi_d[15]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[15]}]

set_property PACKAGE_PIN AA21 [get_ports {hdmi_d[16]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[16]}]

set_property PACKAGE_PIN AB22 [get_ports {hdmi_d[17]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[17]}]

set_property PACKAGE_PIN AB21 [get_ports {hdmi_d[18]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[18]}]

set_property PACKAGE_PIN W17 [get_ports {hdmi_d[19]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[19]}]

set_property PACKAGE_PIN V17 [get_ports {hdmi_d[20]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[20]}]

set_property PACKAGE_PIN V20 [get_ports {hdmi_d[21]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[21]}]

set_property PACKAGE_PIN U20 [get_ports {hdmi_d[22]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[22]}]

set_property PACKAGE_PIN V19 [get_ports {hdmi_d[23]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hdmi_d[23]}]

# -------------------------------------------------------------------------
# HDMI I2C Configuration Pins
# -------------------------------------------------------------------------
set_property PACKAGE_PIN H13 [get_ports hdmi_scl]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_scl]

set_property PACKAGE_PIN G13 [get_ports hdmi_sda]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_sda]

# -------------------------------------------------------------------------
# Asynchronous Clock Domain Crossing (CDC) Timing Constraints
# -------------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks -of_objects [get_ports -quiet sys_clk_clk_p]] \
    -group [get_clocks -include_generated_clocks -of_objects [get_ports -quiet hdmi_clk]]

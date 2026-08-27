# -------------------------------------------------------------------------
# Primary Clocks
# -------------------------------------------------------------------------
# we need to tell vivado that sys_clk_p is a clock
# otherwise we will get critical warning like:
# [Timing 38-472] The REFCLK pin of IDELAYCTRL u_mig_ddr3/u_mig_7series_0_mig/u_iodelay_ctrl/u_idelayctrl_200 is not reached by any clock but IDELAYE2 u_mig_ddr3/u_mig_7series_0_mig/u_memc_ui_top_axi/mem_intfc0/ddr_phy_top0/u_ddr_mc_phy_wrapper/u_ddr_mc_phy/ddr_phy_4lanes_0.u_ddr_phy_4lanes/ddr_byte_lane_A.ddr_byte_lane_A/ddr_byte_group_io/input_[0].iserdes_dq_.idelay_dq.idelaye2 has REFCLK_FREQUENCY of 200.000 Mhz (period 5.000 ns). The IDELAYCTRL REFCLK pin frequency must match the IDELAYE2 REFCLK_FREQUENCY property value.

create_clock -period 5.000 -name ddr3_sys_clk [get_ports sys_clk_p]

# -------------------------------------------------------------------------
# Asynchronous Clock Domain Crossing (CDC) Timing Constraints
# -------------------------------------------------------------------------
# Note: AXI CDC IPs handle their own synchronization internally.


# Ignore recovery/removal timing on the HDMI asynchronous reset synchronizer
set_false_path -to [get_pins -quiet u_hdmi/clk_pix_rst_sync_reg[*]/CLR]

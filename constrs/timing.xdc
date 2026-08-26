# -------------------------------------------------------------------------
# Asynchronous Clock Domain Crossing (CDC) Timing Constraints
# -------------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks -quiet -include_generated_clocks sys_clk] \
    -group [get_clocks -quiet -include_generated_clocks -of_objects [get_ports -quiet hdmi_clk]]


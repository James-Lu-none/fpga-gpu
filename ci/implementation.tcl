# Run from the superproject root; the original hardware/build.tcl is unchanged.
set output $::env(CI_OUTPUT_DIR)
set jobs 4
if {[info exists ::env(VIVADO_JOBS)]} { set jobs $::env(VIVADO_JOBS) }
if {![string is integer -strict $jobs] || $jobs < 1} { error "Invalid VIVADO_JOBS" }
cd fpga-gpu-hardware
open_project fpga-gpu.xpr
# The checked-in XPR still references the package's former location.
if {![file exists rtl/common/gpu_pkg.sv] && [file exists rtl/gpu_pkg.sv]} {
    set old_package [get_files -quiet */common/gpu_pkg.sv]
    if {[llength $old_package]} { remove_files $old_package }
}
add_files -quiet [glob -nocomplain rtl/*.sv rtl/*/*.sv rtl/*/*/*.sv rtl/*/*/*/*.sv]
add_files -quiet [glob -nocomplain constrs/*.xdc constrs/*.ucf]
update_compile_order -fileset sources_1
reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "Synthesis failed" }
reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs $jobs
wait_on_run impl_1
if {![string match "*route_design Complete*" [get_property STATUS [get_runs impl_1]]]} {
    error "Routing did not complete"
}
open_run impl_1
write_checkpoint -force $output/routed.dcp
report_utilization -hierarchical -file $output/utilization.rpt
report_timing_summary -delay_type min_max -report_unconstrained -file $output/timing.rpt
report_route_status -file $output/route.rpt
report_drc -file $output/drc.rpt
check_timing -verbose -file $output/check_timing.rpt
foreach delay_type {max min} {
    set paths [get_timing_paths -delay_type $delay_type -max_paths 1]
    if {[llength $paths] == 0} { error "No $delay_type timing paths found" }
    if {[get_property SLACK [lindex $paths 0]] < 0} { error "$delay_type timing failed" }
}
if {[llength [get_drc_violations -filter {SEVERITY == Error}]] > 0} { error "DRC errors found" }
close_project
puts "PASS: implementation, setup/hold timing and error-level DRC checks."
exit

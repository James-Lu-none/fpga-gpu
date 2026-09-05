# vivado -mode batch -source build.tcl

open_project fpga-gpu.xpr

# open project will load all files loaded in the ui, but we can still add files
add_files [glob rtl/*.sv]
add_files [glob constrs/*.xdc]
add_files [glob constrs/*.ucf]

# reset runs
reset_run synth_1
reset_run impl_1

launch_runs synth_1 -jobs 20
wait_on_run synth_1

launch_runs impl_1 -jobs 20
wait_on_run impl_1

launch_runs impl_1 -to_step write_bitstream -jobs 20
wait_on_run impl_1

open_run impl_1 -name impl_1

report_utilization -hierarchical -format xml -file ./reports/utilization.xml
report_timing -delay_type max -max_paths 50 -sort_by group -nworst 2 -file ./reports/timing.txt

puts "Build and Report Generation Completed!"
exit


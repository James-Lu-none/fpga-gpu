set output $::env(CI_OUTPUT_DIR)
open_checkpoint $output/routed.dcp
report_drc -file $output/bitstream-drc.rpt
if {[llength [get_drc_violations -filter {SEVERITY == Error}]] > 0} { error "DRC errors found" }
write_bitstream -force -bin_file $output/top.bit
puts "PASS: bitstream generated from routed checkpoint."
exit

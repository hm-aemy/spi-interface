# Copyright 2026 University of Applied Sciences Munich
# Christopher Hinz <christopher.hinz@hm.edu>
#
# Non-project batch synthesis/implementation/bitstream flow for top_model,
# same pattern as the hatch repo's fpga/vivado/build.tcl (no .xpr project
# written to disk; only model.bit and the reports below persist). Invoked by
# the Makefile as `vivado -mode batch -source build.tcl`.

source [file join [file dirname [info script]] model_files.tcl]

read_verilog -sv $MODEL_SRCS
read_xdc     $MODEL_XDC

synth_design -top $MODEL_TOP_MODULE -part $MODEL_PART

write_checkpoint -force post_synth.dcp
report_utilization -file utilization_synth.rpt

opt_design
place_design
route_design

write_checkpoint -force post_route.dcp
report_timing_summary -file timing_summary.rpt -max_paths 10 -no_header
report_utilization    -file utilization.rpt
report_drc            -file drc.rpt

write_bitstream -force model.bit

puts "==== model.bit written ===="

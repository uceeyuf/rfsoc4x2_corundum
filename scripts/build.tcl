# SPDX-License-Identifier: BSD-2-Clause-Views
# Copyright (c) 2026 Yijie Yu
#
# Full build: project -> synthesis -> implementation -> bitstream -> XSA.
# Usage (from anywhere):  vivado -mode batch -source scripts/build.tcl -tclargs [jobs]
# Outputs in build/: fpga.bit, rfsoc4x2_mqnic.xsa, timing_summary.rpt

set jobs 8
if {$argc > 0} { set jobs [lindex $argv 0] }

set repo [file normalize [file join [file dirname [info script]] ..]]
file mkdir $repo/build
cd $repo/build

source $repo/scripts/create_project.tcl

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "synthesis failed: [get_property STATUS [get_runs synth_1]]"
}

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "implementation failed: [get_property STATUS [get_runs impl_1]]"
}

open_run impl_1
report_timing_summary -file timing_summary.rpt
file copy -force fpga.runs/impl_1/fpga.bit fpga.bit
write_hw_platform -fixed -force -include_bit rfsoc4x2_mqnic.xsa

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "BUILD_DONE: build/fpga.bit build/rfsoc4x2_mqnic.xsa  WNS=$wns WHS=$whs"

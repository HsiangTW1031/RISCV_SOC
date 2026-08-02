# Multi-corner setup/hold STA for the synthesized aes_core netlist.
#
# sta.tcl (existing, unchanged by this script) reports max-delay/setup
# timing at the single typical-corner library used for synthesis. This
# script re-times the SAME netlist across the Nangate45 slow/fast process
# corners: worst-case setup (slow corner, max delay) and worst-case hold
# (fast corner, min delay) -- see blocks/soc_top/sta/sta_mcmm.tcl for the
# full rationale (identical methodology, applied here to the standalone
# AES core).
#
# Requires NANGATE45_SLOW_LIB / NANGATE45_FAST_LIB set (see TOOLCHAIN.md).
#
# Run from blocks/aes/sta/:
#   sta sta_mcmm.tcl
foreach v {NANGATE45_SLOW_LIB NANGATE45_FAST_LIB} {
    if {![info exists ::env($v)]} {
        puts stderr "ERROR: $v is not set. See TOOLCHAIN.md."
        exit 1
    }
}
read_liberty -max $::env(NANGATE45_SLOW_LIB)
read_liberty -min $::env(NANGATE45_FAST_LIB)
read_verilog ../syn/aes_core_out.v
link_design aes_core

read_sdc ../constraints/aes_core.sdc

puts "=== Setup (max delay, slow corner) ==="
report_checks -path_delay max -fields {slew cap input_pins} -digits 3
puts ""
report_wns -max
report_tns -max
puts ""
puts "=== Hold (min delay, fast corner) ==="
report_checks -path_delay min -fields {slew cap input_pins} -digits 3
puts ""
report_wns -min
report_tns -min

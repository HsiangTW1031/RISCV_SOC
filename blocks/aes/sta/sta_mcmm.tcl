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
# Run from blocks/aes/sta/:
#   sta sta_mcmm.tcl
read_liberty -max /Users/shunghsiangwu/eda/src/OpenSTA/test/nangate45/Nangate45_slow.lib
read_liberty -min /Users/shunghsiangwu/eda/src/OpenSTA/test/nangate45/Nangate45_fast.lib
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

# OpenSTA timing analysis for the synthesized aes_core netlist.
# Run from blocks/aes/sta/:
#   sta sta.tcl
read_liberty /Users/shunghsiangwu/eda/nangate45/lib/NangateOpenCellLibrary_typical.lib
read_verilog ../syn/aes_core_out.v
link_design aes_core

read_sdc ../constraints/aes_core.sdc

report_checks -path_delay max -fields {slew cap input_pins} -digits 3
puts ""
report_wns
report_tns
puts ""
report_checks -path_delay max -group_path_count 3 -digits 3

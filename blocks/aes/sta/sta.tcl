# OpenSTA timing analysis for the synthesized aes_core netlist.
# Requires NANGATE45_LIB set (see TOOLCHAIN.md) -- OpenSTA's Tcl
# interpreter can read env vars natively, no templating needed.
#
# Run from blocks/aes/sta/:
#   sta sta.tcl
if {![info exists ::env(NANGATE45_LIB)]} {
    puts stderr "ERROR: NANGATE45_LIB is not set. See TOOLCHAIN.md."
    exit 1
}
read_liberty $::env(NANGATE45_LIB)
read_verilog ../syn/aes_core_out.v
link_design aes_core

read_sdc ../constraints/aes_core.sdc

report_checks -path_delay max -fields {slew cap input_pins} -digits 3
puts ""
report_wns
report_tns
puts ""
report_checks -path_delay max -group_path_count 3 -digits 3

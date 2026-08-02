# OpenSTA timing analysis for the synthesized whole-SoC netlist.
# The three blackboxed memories (boot_rom/sram/dma_ram, see
# ../syn/mem_blackboxes.v) have no internal cells, so paths terminate at
# their input ports and originate at their output ports -- consistent
# with treating them as hardened SRAM macros outside this logic-only
# timing view (see docs/performance.md for the rationale).
#
# Requires NANGATE45_LIB set (see TOOLCHAIN.md) -- OpenSTA's Tcl
# interpreter can read env vars natively, no templating needed.
#
# Run from blocks/soc_top/sta/:
#   sta sta.tcl
if {![info exists ::env(NANGATE45_LIB)]} {
    puts stderr "ERROR: NANGATE45_LIB is not set. See TOOLCHAIN.md."
    exit 1
}
read_liberty $::env(NANGATE45_LIB)
read_verilog ../syn/mem_blackboxes.v
read_verilog ../syn/soc_top_out.v
link_design soc_top

read_sdc ../constraints/soc_top.sdc

report_checks -path_delay max -fields {slew cap input_pins} -digits 3
puts ""
report_wns
report_tns
puts ""
report_checks -path_delay max -group_path_count 5 -digits 3

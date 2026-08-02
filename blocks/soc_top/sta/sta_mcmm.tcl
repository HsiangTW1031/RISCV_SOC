# Multi-corner setup/hold STA for the synthesized whole-SoC netlist.
#
# sta.tcl (existing, unchanged by this script) reports max-delay/setup
# timing at the single typical-corner library used for synthesis -- that
# is the number cited as Fmax in docs/performance.md. This script re-times
# the SAME netlist across the Nangate45 slow/fast process corners to add
# what a real signoff always checks and the typical-only run above cannot:
# worst-case setup (slow corner, max delay) and worst-case hold (fast
# corner, min delay). See docs/coverage_waiver_report.md's sibling doc
# docs/project_retrospective.md for why this was added.
#
# Corner libs: OpenSTA's own bundled Nangate45 fast/slow corner libraries.
# Verified compatible with the NangateOpenCellLibrary_typical.lib used for
# synthesis -- 239/241 cells match; the only cell missing from fast/slow is
# TAPCELL_X1, a physical-only tap cell never inferred by logic synthesis,
# so it has no effect on this netlist.
#
# Run from blocks/soc_top/sta/:
#   sta sta_mcmm.tcl
read_liberty -max /Users/shunghsiangwu/eda/src/OpenSTA/test/nangate45/Nangate45_slow.lib
read_liberty -min /Users/shunghsiangwu/eda/src/OpenSTA/test/nangate45/Nangate45_fast.lib
read_verilog ../syn/mem_blackboxes.v
read_verilog ../syn/soc_top_out.v
link_design soc_top

read_sdc ../constraints/soc_top.sdc

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

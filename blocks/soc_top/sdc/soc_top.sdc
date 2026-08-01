# Timing constraints for the whole-SoC synthesis/STA run (Phase 7
# sign-off). Same convention as blocks/aes/sdc/aes_core.sdc: a single
# clock domain, zero I/O delay budget on every port (every AXI/JTAG
# input and output in this design is already registered right at the
# module boundary, so the reported critical path is the SoC's genuine
# internal logic path, not an arbitrary I/O budget assumption).
#
# The period here (2.0ns = 500MHz) is deliberately tighter than the
# design will actually close at -- the point of this run is to read the
# worst-case data arrival time off report_checks and derive Fmax from
# that directly (Fmax = 1 / critical_path_delay), not to hit a specific
# target frequency.
create_clock -name clk -period 2.0 [get_ports clk]
set_input_delay  0.0 -clock clk [all_inputs]
set_output_delay 0.0 -clock clk [all_outputs]

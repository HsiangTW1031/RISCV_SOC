# Timing constraints for the standalone aes_core.v synthesis/STA run.
# A single clock domain, no I/O delay budget assumed (this block is meant
# to sit behind the AXI-Lite register interface, which registers every
# input/output already) -- so inputs/outputs are constrained to the full
# clock period, keeping the reported critical path focused on the
# internal round datapath itself.
create_clock -name clk -period 2.0 [get_ports clk]
set_input_delay  0.0 -clock clk [all_inputs]
set_output_delay 0.0 -clock clk [all_outputs]
# NB: set_input_delay on the clk port itself is a harmless no-op (OpenSTA
# warns since a clock port doesn't need a data input delay); every other
# input still gets the constraint.

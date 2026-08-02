# Timing constraints for the whole-SoC synthesis/STA run (Phase 7
# sign-off). Same convention as blocks/aes/constraints/aes_core.sdc: zero
# I/O delay budget on every port (every AXI/JTAG input and output in this
# design is already registered right at the module boundary, so the
# reported critical path is the SoC's genuine internal logic path, not an
# arbitrary I/O budget assumption).
#
# The clk period here (2.0ns = 500MHz) is deliberately tighter than the
# design will actually close at -- the point of this run is to read the
# worst-case data arrival time off report_checks and derive Fmax from
# that directly (Fmax = 1 / critical_path_delay), not to hit a specific
# target frequency.
create_clock -name clk -period 2.0 [get_ports clk]
set_input_delay  0.0 -clock clk [all_inputs]
set_output_delay 0.0 -clock clk [all_outputs]

# `tck` is a genuinely separate, asynchronous clock domain -- driven
# externally by whatever JTAG debug probe is attached, with no defined
# phase or frequency relationship to `clk` (see blocks/jtag/rtl/
# jtag_axi_bridge.v's CDC header comment). It's declared as a real clock,
# not left as a plain data signal, because it directly drives the clock
# pin of real flip-flops in jtag_tap.v/jtag_dtm.v -- without a
# create_clock here, STA would have no defined clock for those registers
# and would silently skip timing analysis on that entire domain, not just
# the cross-domain paths.
#
# 20ns (50MHz) is a conservative upper bound on real JTAG probe TCK rates
# (most debug adapters run well under this) -- since jtag_tap.v/
# jtag_dtm.v's per-domain logic is a handful of small FSM/compare/shift
# operations (no AXI crossbar, no arithmetic), it will meet timing here
# with enormous margin regardless of the exact value chosen; the number
# only matters for giving OpenSTA *a* defined clock to check the domain
# against; the real point of interest is the cross-domain declaration
# below, not this period.
create_clock -name tck -period 20.0 [get_ports tck]
set_input_delay  0.0 -clock tck [get_ports tms]
set_input_delay  0.0 -clock tck [get_ports tdi]
set_output_delay 0.0 -clock tck [get_ports tdo]

# clk and tck have no defined phase relationship -- treating them as
# related clocks would make OpenSTA compute a meaningless "worst-case
# skew" across an undefined relationship, either spuriously flagging the
# synchronizer paths in jtag_axi_bridge.v as setup/hold violations or
# (just as wrong) reporting them as passing for reasons that don't apply.
# Declaring the two clock groups asynchronous is what correctly exempts
# every path crossing this boundary from setup/hold checking -- this does
# NOT verify the synchronizers themselves are structurally sound (STA
# can't do that); see docs/cdc_report.md for the structural review that
# actually checks synchronizer depth and topology.
set_clock_groups -asynchronous -group {clk} -group {tck}

# `rst` itself is the async input to the two reset synchronizers in
# soc_top.v (rst_clk_meta/rst_clk_sync, rst_tck_meta/rst_tck_sync) -- by
# design, both flops in each synchronizer have their asynchronous set
# driven directly by this raw, genuinely-async port (see soc_top.v's
# header comment), which is exactly what lets reset assert immediately
# rather than waiting on a clock edge. That same property means STA's
# recovery/removal check against `rst` (confirmed: reported as "removal
# check against rising-edge clock clk", -0.08ns at the fast corner) is
# inherent to any reset synchronizer's first stage, not a real timing
# bug -- there is no way to guarantee a genuinely-asynchronous signal
# never transitions within a clock period's removal window, and that's
# precisely the metastability risk the synchronizer's second stage
# exists to absorb. `rst` fans out to nothing else in this design
# (verified: its only remaining reader anywhere is these two always
# blocks), so exempting every path starting at this port is precise, not
# a broad workaround.
set_false_path -from [get_ports rst]

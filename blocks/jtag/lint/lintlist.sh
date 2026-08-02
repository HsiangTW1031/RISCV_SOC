# jtag_dtm nests jtag_tap; jtag_axi_bridge is a separate top (the two
# communicate via toggle-sync signals, not Verilog hierarchy)
lint_target jtag jtag_dtm jtag_dtm \
  -I"$ROOT/rtl/include" "$ROOT/blocks/jtag/rtl/jtag_tap.v" "$ROOT/blocks/jtag/rtl/jtag_dtm.v"

lint_target jtag jtag_axi_bridge jtag_axi_bridge \
  -I"$ROOT/rtl/include" "$ROOT/blocks/jtag/rtl/jtag_axi_bridge.v"

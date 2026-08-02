run_target jtag_tap "$ROOT/blocks/jtag/dv" jtag_tap tap_sim obj_dir_tap \
  -I"$ROOT/rtl/include" "$ROOT/blocks/jtag/rtl/jtag_tap.v" tap_sim_main.cpp

run_target jtag_chain "$ROOT/blocks/jtag/dv" jtag_chain_testtop chain_sim obj_dir_chain \
  -I"$ROOT/rtl/include" "$ROOT/tb/common/fake_axi_lite_slave.v" \
  "$ROOT/blocks/jtag/rtl/jtag_tap.v" "$ROOT/blocks/jtag/rtl/jtag_dtm.v" "$ROOT/blocks/jtag/rtl/jtag_axi_bridge.v" \
  "$ROOT/blocks/jtag/dv/jtag_chain_testtop.v" jtag_chain_sim_main.cpp

# CDC stress test at the opposite ratio corner (tck faster than clk, see
# docs/cdc_report.md) -- same scan sequence/checks, only the clock
# relationship differs. Regression-only (not part of coverage collection).
if [ -z "${COVERAGE_MODE:-}" ]; then
  run_target jtag_chain_fast_tck "$ROOT/blocks/jtag/dv" jtag_chain_testtop fast_tck_sim obj_dir_fast_tck \
    -I"$ROOT/rtl/include" "$ROOT/tb/common/fake_axi_lite_slave.v" \
    "$ROOT/blocks/jtag/rtl/jtag_tap.v" "$ROOT/blocks/jtag/rtl/jtag_dtm.v" "$ROOT/blocks/jtag/rtl/jtag_axi_bridge.v" \
    "$ROOT/blocks/jtag/dv/jtag_chain_testtop.v" jtag_chain_fast_tck_sim_main.cpp
fi

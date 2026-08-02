run_target axi_lite_xbar "$ROOT/blocks/axi_lite_xbar/dv" xbar_testtop sim obj_dir \
  -I"$ROOT/rtl/include" "$ROOT/blocks/axi_lite_xbar/rtl/axi_lite_xbar.v" "$ROOT/tb/common/fake_axi_lite_slave.v" \
  "$ROOT/blocks/axi_lite_xbar/dv/xbar_testtop.v" sim_main.cpp

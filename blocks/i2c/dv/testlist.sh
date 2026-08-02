run_target i2c "$ROOT/blocks/i2c/dv" i2c_testtop sim obj_dir \
  -I"$ROOT/rtl/include" -I"$ROOT/blocks/i2c/rtl" \
  "$ROOT/blocks/i2c/rtl/i2c_master.v" "$ROOT/tb/common/fake_i2c_slave.v" \
  "$ROOT/blocks/i2c/dv/i2c_testtop.v" sim_main.cpp

run_target sram "$ROOT/blocks/sram/dv" sram sim obj_dir \
  -I"$ROOT/rtl/include" "$ROOT/blocks/sram/rtl/sram.v" sim_main.cpp

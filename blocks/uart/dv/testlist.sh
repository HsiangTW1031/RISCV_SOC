run_target uart "$ROOT/blocks/uart/dv" uart sim obj_dir \
  -I"$ROOT/rtl/include" "$ROOT/blocks/uart/rtl/uart.v" sim_main.cpp

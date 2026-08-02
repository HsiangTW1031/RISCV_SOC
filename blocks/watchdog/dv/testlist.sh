run_target watchdog "$ROOT/blocks/watchdog/dv" watchdog sim obj_dir \
  -I"$ROOT/rtl/include" "$ROOT/blocks/watchdog/rtl/watchdog.v" sim_main.cpp

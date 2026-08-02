run_target boot_rom "$ROOT/blocks/boot_rom/dv" boot_rom sim obj_dir \
  -I"$ROOT/rtl/include" '-GHEXFILE="test.hex"' "$ROOT/blocks/boot_rom/rtl/boot_rom.v" sim_main.cpp

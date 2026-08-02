run_target spi "$ROOT/blocks/spi/dv" spi_testtop sim obj_dir \
  -I"$ROOT/rtl/include" -I"$ROOT/blocks/spi/rtl" \
  "$ROOT/blocks/spi/rtl/spi_master.v" "$ROOT/tb/common/fake_spi_slave.v" \
  "$ROOT/blocks/spi/dv/spi_testtop.v" sim_main.cpp

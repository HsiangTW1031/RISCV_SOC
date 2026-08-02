# the whole SoC's hierarchy, including the vendored PicoRV32 core
lint_target soc_top soc_top soc_top \
  -I"$ROOT/rtl/include" -I"$ROOT/blocks/soc_top/rtl" \
  "$ROOT/blocks/soc_top/rtl/picorv32.v" "$ROOT/blocks/soc_top/rtl/axi_lite_xbar.v" \
  "$ROOT/blocks/soc_top/rtl/boot_rom.v" "$ROOT/blocks/soc_top/rtl/sram.v" \
  "$ROOT/blocks/soc_top/rtl/timer.v" "$ROOT/blocks/soc_top/rtl/watchdog.v" \
  "$ROOT/blocks/soc_top/rtl/uart.v" "$ROOT/blocks/soc_top/rtl/i2c_master.v" \
  "$ROOT/blocks/soc_top/rtl/spi_master.v" "$ROOT/blocks/soc_top/rtl/aes_key_expand.v" \
  "$ROOT/blocks/soc_top/rtl/aes_core.v" "$ROOT/blocks/soc_top/rtl/aes_chain.v" \
  "$ROOT/blocks/soc_top/rtl/aes.v" "$ROOT/blocks/soc_top/rtl/dma_ram.v" \
  "$ROOT/blocks/soc_top/rtl/dma_engine.v" "$ROOT/blocks/soc_top/rtl/jtag_tap.v" \
  "$ROOT/blocks/soc_top/rtl/jtag_dtm.v" "$ROOT/blocks/soc_top/rtl/jtag_axi_bridge.v" \
  "$ROOT/blocks/soc_top/rtl/soc_top.v"

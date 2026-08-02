# soc_top's rtl/ is a set of symlinks into every other block's canonical
# source (see docs/phase_plan.md) -- but for the *file paths passed to
# Verilator*, canonical paths matter, not just file content: coverage
# collection (scripts/run_coverage.sh) dedupes toggle points by (file,
# line, signal), and a symlink resolves to identical content but a
# DIFFERENT path string, so referencing files through the soc_top/rtl
# symlink farm here would silently double-count every shared module's
# toggle points against its owning block's own coverage. Always reference
# the canonical blocks/<owner>/rtl/ path, never blocks/soc_top/rtl/<x>.v,
# except for soc_top.v itself (which has no other owner) and picorv32.v
# (vendored, only reachable via this symlink).
run_target soc_top "$ROOT/blocks/soc_top/dv" soc_top sim obj_dir \
  --trace -I"$ROOT/rtl/include" -I"$ROOT/blocks/aes/rtl" -I"$ROOT/blocks/soc_top/rtl" \
  "$ROOT/blocks/soc_top/rtl/picorv32.v" "$ROOT/blocks/axi_lite_xbar/rtl/axi_lite_xbar.v" \
  "$ROOT/blocks/boot_rom/rtl/boot_rom.v" "$ROOT/blocks/sram/rtl/sram.v" \
  "$ROOT/blocks/timer/rtl/timer.v" "$ROOT/blocks/watchdog/rtl/watchdog.v" \
  "$ROOT/blocks/uart/rtl/uart.v" "$ROOT/blocks/i2c/rtl/i2c_master.v" \
  "$ROOT/blocks/spi/rtl/spi_master.v" "$ROOT/blocks/aes/rtl/aes_key_expand.v" \
  "$ROOT/blocks/aes/rtl/aes_core.v" "$ROOT/blocks/aes/rtl/aes_chain.v" \
  "$ROOT/blocks/aes/rtl/aes.v" "$ROOT/blocks/dma/rtl/dma_ram.v" \
  "$ROOT/blocks/dma/rtl/dma_engine.v" "$ROOT/blocks/jtag/rtl/jtag_tap.v" \
  "$ROOT/blocks/jtag/rtl/jtag_dtm.v" "$ROOT/blocks/jtag/rtl/jtag_axi_bridge.v" \
  "$ROOT/blocks/soc_top/rtl/soc_top.v" sim_main.cpp

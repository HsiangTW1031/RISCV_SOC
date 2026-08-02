#!/usr/bin/env bash
# Rebuilds and runs every block's Verilator testbench in one pass, then
# prints a PASS/FAIL summary table (Phase 7 exit criterion). Run from
# anywhere; paths below are resolved relative to this script's location.
#
#   ./scripts/run_regression.sh
#
# Each test is built fresh (no incremental caching assumptions) with the
# same Verilator flag set used throughout this project (see README.md's
# "Running things" section) and run once; its PASS/FAIL line is captured
# into the final summary table. A non-zero exit from this script means at
# least one test failed or a build broke.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VFLAGS="-Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-PINCONNECTEMPTY"
BFM_INC="-CFLAGS -I${ROOT}/tb/common"

declare -a NAMES=()
declare -a RESULTS=()
declare -a DETAILS=()

run_one() {
  local name="$1" workdir="$2" top="$3" outbin="$4" mdir="$5"
  shift 5
  local files=("$@")

  NAMES+=("$name")
  pushd "$workdir" > /dev/null

  if ! verilator $VFLAGS --cc --exe --build --top-module "$top" $BFM_INC \
        "${files[@]}" -o "$outbin" --Mdir "$mdir" > "${mdir}_build.log" 2>&1; then
    RESULTS+=("BUILD-FAIL")
    DETAILS+=("build failed, see ${workdir}/${mdir}_build.log")
    popd > /dev/null
    return
  fi

  local out
  out="$(./"$mdir"/"$outbin" 2>&1)"
  local rc=$?
  local last_line
  last_line="$(echo "$out" | grep -E '^(PASS|FAIL):' | tail -1)"

  if [ $rc -eq 0 ] && [[ "$last_line" == PASS:* ]]; then
    RESULTS+=("PASS")
  else
    RESULTS+=("FAIL")
  fi
  DETAILS+=("$last_line")
  popd > /dev/null
}

echo "=== RISCV_SOC regression: rebuilding + running every block's testbench ==="
echo

# ---- Timer / Watchdog / UART / SRAM (single-file, no testtop needed) ----
run_one "timer" "$ROOT/blocks/timer/dv" timer timer_sim obj_dir_regr \
  -I"$ROOT/rtl/include" ../rtl/timer.v sim_main.cpp

run_one "watchdog" "$ROOT/blocks/watchdog/dv" watchdog watchdog_sim obj_dir_regr \
  -I"$ROOT/rtl/include" ../rtl/watchdog.v sim_main.cpp

run_one "uart" "$ROOT/blocks/uart/dv" uart uart_sim obj_dir_regr \
  -I"$ROOT/rtl/include" ../rtl/uart.v sim_main.cpp

run_one "sram" "$ROOT/blocks/sram/dv" sram sram_sim obj_dir_regr \
  -I"$ROOT/rtl/include" ../rtl/sram.v sim_main.cpp

run_one "boot_rom" "$ROOT/blocks/boot_rom/dv" boot_rom boot_rom_sim obj_dir_regr \
  -I"$ROOT/rtl/include" '-GHEXFILE="test.hex"' ../rtl/boot_rom.v sim_main.cpp

# ---- I2C / SPI (their own testtop + fake pins/reference model) ----
run_one "i2c" "$ROOT/blocks/i2c/dv" i2c_testtop i2c_sim obj_dir_regr \
  -I"$ROOT/rtl/include" -I../rtl ../rtl/i2c_master.v "$ROOT/tb/common/fake_i2c_slave.v" i2c_testtop.v sim_main.cpp

run_one "spi" "$ROOT/blocks/spi/dv" spi_testtop spi_sim obj_dir_regr \
  -I"$ROOT/rtl/include" -I../rtl ../rtl/spi_master.v "$ROOT/tb/common/fake_spi_slave.v" spi_testtop.v sim_main.cpp

# ---- JTAG: TAP FSM standalone, then the full chain (tap+dtm+bridge) ----
run_one "jtag_tap" "$ROOT/blocks/jtag/dv" jtag_tap jtag_tap_sim obj_dir_tap_regr \
  -I"$ROOT/rtl/include" ../rtl/jtag_tap.v tap_sim_main.cpp

run_one "jtag_chain" "$ROOT/blocks/jtag/dv" jtag_chain_testtop jtag_chain_sim obj_dir_chain_regr \
  -I"$ROOT/rtl/include" "$ROOT/tb/common/fake_axi_lite_slave.v" \
  ../rtl/jtag_tap.v ../rtl/jtag_dtm.v ../rtl/jtag_axi_bridge.v \
  jtag_chain_testtop.v jtag_chain_sim_main.cpp

# ---- AES: key expansion, core, chain (CBC/CTR), AXI-Lite wrapper, diff ----
run_one "aes_key_expand" "$ROOT/blocks/aes/dv" aes_key_expand keyexp_sim obj_dir_keyexp_regr \
  -I../rtl ../rtl/aes_key_expand.v key_expand_sim_main.cpp

run_one "aes_core" "$ROOT/blocks/aes/dv" aes_core core_sim obj_dir_core_regr \
  -I../rtl ../rtl/aes_key_expand.v ../rtl/aes_core.v core_sim_main.cpp

run_one "aes_chain" "$ROOT/blocks/aes/dv" aes_chain chain_sim obj_dir_chain_regr \
  -I../rtl ../rtl/aes_key_expand.v ../rtl/aes_core.v ../rtl/aes_chain.v chain_sim_main.cpp

run_one "aes_axi_wrapper" "$ROOT/blocks/aes/dv" aes aes_sim obj_dir_regr \
  -I"$ROOT/rtl/include" -I../rtl ../rtl/aes_key_expand.v ../rtl/aes_core.v ../rtl/aes_chain.v ../rtl/aes.v sim_main.cpp

run_one "aes_diff" "$ROOT/blocks/aes/dv" aes diff_sim obj_dir_diff_regr \
  -I"$ROOT/rtl/include" -I../rtl ../rtl/aes_key_expand.v ../rtl/aes_core.v ../rtl/aes_chain.v ../rtl/aes.v diff_sim_main.cpp

# ---- axi_lite_xbar: crossbar decode/routing/arbitration ----
run_one "axi_lite_xbar" "$ROOT/blocks/axi_lite_xbar/dv" xbar_testtop xbar_sim obj_dir_regr \
  -I"$ROOT/rtl/include" ../rtl/axi_lite_xbar.v "$ROOT/tb/common/fake_axi_lite_slave.v" \
  xbar_testtop.v sim_main.cpp

# ---- DMA: burst RAM, then the full engine (burst master + aes_chain) ----
run_one "dma_ram" "$ROOT/blocks/dma/dv" dma_ram dma_ram_sim obj_dir_ram_regr \
  -I"$ROOT/rtl/include" ../rtl/dma_ram.v dma_ram_sim_main.cpp

run_one "dma_engine" "$ROOT/blocks/dma/dv" dma_engine_testtop dma_engine_sim obj_dir_engine_regr \
  -I"$ROOT/rtl/include" -I"$ROOT/blocks/aes/rtl" -I../rtl \
  ../rtl/dma_ram.v ../rtl/dma_engine.v "$ROOT/blocks/aes/rtl/aes_key_expand.v" \
  "$ROOT/blocks/aes/rtl/aes_core.v" "$ROOT/blocks/aes/rtl/aes_chain.v" \
  dma_engine_testtop.v dma_engine_sim_main.cpp

# ---- soc_top: whole-SoC smoke test (firmware boot + timer IRQs + JTAG) ----
run_one "soc_top" "$ROOT/blocks/soc_top/dv" soc_top soc_sim obj_dir_regr \
  --trace -I"$ROOT/rtl/include" -I../rtl \
  ../rtl/picorv32.v ../rtl/axi_lite_xbar.v ../rtl/boot_rom.v ../rtl/sram.v \
  ../rtl/timer.v ../rtl/watchdog.v ../rtl/uart.v ../rtl/i2c_master.v ../rtl/spi_master.v \
  ../rtl/aes_key_expand.v ../rtl/aes_core.v ../rtl/aes_chain.v ../rtl/aes.v \
  ../rtl/dma_ram.v ../rtl/dma_engine.v \
  ../rtl/jtag_tap.v ../rtl/jtag_dtm.v ../rtl/jtag_axi_bridge.v \
  ../rtl/soc_top.v sim_main.cpp

# ---- summary table ----
echo
printf "%-18s %-12s %s\n" "BLOCK" "RESULT" "DETAIL"
printf "%-18s %-12s %s\n" "------------------" "------------" "------"
fail_count=0
for i in "${!NAMES[@]}"; do
  printf "%-18s %-12s %s\n" "${NAMES[$i]}" "${RESULTS[$i]}" "${DETAILS[$i]}"
  if [ "${RESULTS[$i]}" != "PASS" ]; then
    fail_count=$((fail_count + 1))
  fi
done

echo
if [ $fail_count -eq 0 ]; then
  echo "ALL ${#NAMES[@]} regression targets PASS"
  exit 0
else
  echo "$fail_count / ${#NAMES[@]} regression targets FAILED"
  exit 1
fi

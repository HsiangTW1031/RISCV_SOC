#!/usr/bin/env bash
# Rebuilds every regression testbench with Verilator's --coverage-line and
# --coverage-toggle instrumentation, runs them, and merges the results into
# reports/soc_top/coverage/merged.dat (+ an lcov .info for tooling that
# wants it). Each testbench's main() writes "coverage.dat" in its own cwd
# via the VM_COVERAGE-guarded hook added to every sim_main.cpp -- a
# complete no-op in the normal (non-coverage) build used by
# scripts/run_regression.sh.
#
#   ./scripts/run_coverage.sh
#
# Line coverage on `case` arms doubles as FSM state coverage here (see
# docs/project_retrospective.md): plain Verilog-2001 case-based FSMs don't
# get picked up by Verilator's --coverage-fsm heuristic, but each case arm
# already gets its own line-coverage hit count, which is exactly "was this
# state ever entered" -- scripts/analyze_coverage.py cross-references those
# hit counts against each FSM's known state-to-line mapping.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VFLAGS="-Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-PINCONNECTEMPTY --coverage-line --coverage-toggle"
BFM_INC="-CFLAGS -I${ROOT}/tb/common"

COV_DIR="$ROOT/reports/soc_top/coverage"
DAT_DIR="$COV_DIR/dat"
rm -rf "$DAT_DIR"
mkdir -p "$DAT_DIR"

declare -a NAMES=()
declare -a RESULTS=()

run_one_cov() {
  local name="$1" workdir="$2" top="$3" outbin="$4" mdir="$5"
  shift 5
  local files=("$@")

  NAMES+=("$name")
  pushd "$workdir" > /dev/null
  rm -f coverage.dat

  if ! verilator $VFLAGS --cc --exe --build --top-module "$top" $BFM_INC \
        "${files[@]}" -o "$outbin" --Mdir "$mdir" > "${mdir}_build.log" 2>&1; then
    RESULTS+=("BUILD-FAIL")
    popd > /dev/null
    return
  fi

  if ./"$mdir"/"$outbin" > /dev/null 2>&1 && [ -f coverage.dat ]; then
    cp coverage.dat "$DAT_DIR/$name.dat"
    RESULTS+=("OK")
  else
    RESULTS+=("RUN-FAIL")
  fi
  popd > /dev/null
}

echo "=== Coverage collection: rebuilding + running every block's testbench with --coverage ==="
echo

run_one_cov "timer" "$ROOT/blocks/timer/sim" timer timer_cov obj_dir_cov \
  -I"$ROOT/rtl/include" "$ROOT/blocks/timer/rtl/timer.v" sim_main.cpp

run_one_cov "watchdog" "$ROOT/blocks/watchdog/sim" watchdog watchdog_cov obj_dir_cov \
  -I"$ROOT/rtl/include" "$ROOT/blocks/watchdog/rtl/watchdog.v" sim_main.cpp

run_one_cov "uart" "$ROOT/blocks/uart/sim" uart uart_cov obj_dir_cov \
  -I"$ROOT/rtl/include" "$ROOT/blocks/uart/rtl/uart.v" sim_main.cpp

run_one_cov "sram" "$ROOT/blocks/sram/sim" sram sram_cov obj_dir_cov \
  -I"$ROOT/rtl/include" "$ROOT/blocks/sram/rtl/sram.v" sim_main.cpp

run_one_cov "boot_rom" "$ROOT/blocks/boot_rom/sim" boot_rom boot_rom_cov obj_dir_cov \
  -I"$ROOT/rtl/include" '-GHEXFILE="test.hex"' "$ROOT/blocks/boot_rom/rtl/boot_rom.v" sim_main.cpp

run_one_cov "i2c" "$ROOT/blocks/i2c/sim" i2c_testtop i2c_cov obj_dir_cov \
  -I"$ROOT/rtl/include" -I../rtl "$ROOT/blocks/i2c/rtl/i2c_master.v" "$ROOT/tb/common/fake_i2c_slave.v" "$ROOT/blocks/i2c/sim/i2c_testtop.v" sim_main.cpp

run_one_cov "spi" "$ROOT/blocks/spi/sim" spi_testtop spi_cov obj_dir_cov \
  -I"$ROOT/rtl/include" -I../rtl "$ROOT/blocks/spi/rtl/spi_master.v" "$ROOT/tb/common/fake_spi_slave.v" "$ROOT/blocks/spi/sim/spi_testtop.v" sim_main.cpp

run_one_cov "jtag_tap" "$ROOT/blocks/jtag/sim" jtag_tap jtag_tap_cov obj_dir_tap_cov \
  -I"$ROOT/rtl/include" "$ROOT/blocks/jtag/rtl/jtag_tap.v" tap_sim_main.cpp

run_one_cov "jtag_chain" "$ROOT/blocks/jtag/sim" jtag_chain_testtop jtag_chain_cov obj_dir_chain_cov \
  -I"$ROOT/rtl/include" "$ROOT/tb/common/fake_axi_lite_slave.v" \
  "$ROOT/blocks/jtag/rtl/jtag_tap.v" "$ROOT/blocks/jtag/rtl/jtag_dtm.v" "$ROOT/blocks/jtag/rtl/jtag_axi_bridge.v" \
  "$ROOT/blocks/jtag/sim/jtag_chain_testtop.v" jtag_chain_sim_main.cpp

run_one_cov "aes_key_expand" "$ROOT/blocks/aes/sim" aes_key_expand keyexp_cov obj_dir_keyexp_cov \
  -I"$ROOT/blocks/aes/rtl" "$ROOT/blocks/aes/rtl/aes_key_expand.v" key_expand_sim_main.cpp

run_one_cov "aes_core" "$ROOT/blocks/aes/sim" aes_core core_cov obj_dir_core_cov \
  -I"$ROOT/blocks/aes/rtl" "$ROOT/blocks/aes/rtl/aes_key_expand.v" "$ROOT/blocks/aes/rtl/aes_core.v" core_sim_main.cpp

run_one_cov "aes_chain" "$ROOT/blocks/aes/sim" aes_chain chain_cov obj_dir_chain_cov \
  -I"$ROOT/blocks/aes/rtl" "$ROOT/blocks/aes/rtl/aes_key_expand.v" "$ROOT/blocks/aes/rtl/aes_core.v" "$ROOT/blocks/aes/rtl/aes_chain.v" chain_sim_main.cpp

run_one_cov "aes_axi_wrapper" "$ROOT/blocks/aes/sim" aes aes_cov obj_dir_cov \
  -I"$ROOT/rtl/include" -I"$ROOT/blocks/aes/rtl" "$ROOT/blocks/aes/rtl/aes_key_expand.v" "$ROOT/blocks/aes/rtl/aes_core.v" "$ROOT/blocks/aes/rtl/aes_chain.v" "$ROOT/blocks/aes/rtl/aes.v" sim_main.cpp

run_one_cov "aes_diff" "$ROOT/blocks/aes/sim" aes diff_cov obj_dir_diff_cov \
  -I"$ROOT/rtl/include" -I"$ROOT/blocks/aes/rtl" "$ROOT/blocks/aes/rtl/aes_key_expand.v" "$ROOT/blocks/aes/rtl/aes_core.v" "$ROOT/blocks/aes/rtl/aes_chain.v" "$ROOT/blocks/aes/rtl/aes.v" diff_sim_main.cpp

run_one_cov "axi_lite_xbar" "$ROOT/blocks/axi_lite_xbar/sim" xbar_testtop xbar_cov obj_dir_cov \
  -I"$ROOT/rtl/include" "$ROOT/blocks/axi_lite_xbar/rtl/axi_lite_xbar.v" "$ROOT/tb/common/fake_axi_lite_slave.v" \
  "$ROOT/blocks/axi_lite_xbar/sim/xbar_testtop.v" sim_main.cpp

run_one_cov "dma_ram" "$ROOT/blocks/dma/sim" dma_ram dma_ram_cov obj_dir_ram_cov \
  -I"$ROOT/rtl/include" "$ROOT/blocks/dma/rtl/dma_ram.v" dma_ram_sim_main.cpp

run_one_cov "dma_engine" "$ROOT/blocks/dma/sim" dma_engine_testtop dma_engine_cov obj_dir_engine_cov \
  -I"$ROOT/rtl/include" -I"$ROOT/blocks/aes/rtl" -I../rtl \
  "$ROOT/blocks/dma/rtl/dma_ram.v" "$ROOT/blocks/dma/rtl/dma_engine.v" "$ROOT/blocks/aes/rtl/aes_key_expand.v" \
  "$ROOT/blocks/aes/rtl/aes_core.v" "$ROOT/blocks/aes/rtl/aes_chain.v" \
  "$ROOT/blocks/dma/sim/dma_engine_testtop.v" dma_engine_sim_main.cpp

run_one_cov "soc_top" "$ROOT/blocks/soc_top/sim" soc_top soc_top_cov obj_dir_cov \
  --trace -I"$ROOT/rtl/include" -I"$ROOT/blocks/aes/rtl" -I../rtl \
  "$ROOT/blocks/soc_top/rtl/picorv32.v" "$ROOT/blocks/axi_lite_xbar/rtl/axi_lite_xbar.v" "$ROOT/blocks/boot_rom/rtl/boot_rom.v" "$ROOT/blocks/sram/rtl/sram.v" \
  "$ROOT/blocks/timer/rtl/timer.v" "$ROOT/blocks/watchdog/rtl/watchdog.v" "$ROOT/blocks/uart/rtl/uart.v" "$ROOT/blocks/i2c/rtl/i2c_master.v" "$ROOT/blocks/spi/rtl/spi_master.v" \
  "$ROOT/blocks/aes/rtl/aes_key_expand.v" "$ROOT/blocks/aes/rtl/aes_core.v" "$ROOT/blocks/aes/rtl/aes_chain.v" "$ROOT/blocks/aes/rtl/aes.v" \
  "$ROOT/blocks/dma/rtl/dma_ram.v" "$ROOT/blocks/dma/rtl/dma_engine.v" \
  "$ROOT/blocks/jtag/rtl/jtag_tap.v" "$ROOT/blocks/jtag/rtl/jtag_dtm.v" "$ROOT/blocks/jtag/rtl/jtag_axi_bridge.v" \
  "$ROOT/blocks/soc_top/rtl/soc_top.v" sim_main.cpp

echo
printf "%-18s %s\n" "TEST" "STATUS"
for i in "${!NAMES[@]}"; do
  printf "%-18s %s\n" "${NAMES[$i]}" "${RESULTS[$i]}"
done

echo
echo "=== Merging coverage data ==="
verilator_coverage --write "$COV_DIR/merged.dat" "$DAT_DIR"/*.dat
verilator_coverage --write-info "$COV_DIR/coverage.info" "$COV_DIR/merged.dat"
verilator_coverage --annotate "$COV_DIR/annotated" --annotate-all "$COV_DIR/merged.dat"

echo "Merged coverage data: $COV_DIR/merged.dat"
echo "LCOV info:            $COV_DIR/coverage.info"
echo "Annotated source:      $COV_DIR/annotated/"

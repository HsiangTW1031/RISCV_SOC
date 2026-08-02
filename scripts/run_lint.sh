#!/usr/bin/env bash
# Runs a dedicated `verilator --lint-only` pass (independent of any
# simulation build) against each block's real deliverable RTL, and saves
# the result to blocks/<name>/lint/lint_report.txt. Unlike the lint that
# happens incidentally as part of every `--cc --exe --build` in
# scripts/run_regression.sh, this is lint-only -- no C++ testbench, no
# simulation binary -- so it's independent of whatever warning flags a
# given test build happens to suppress.
#
#   ./scripts/run_lint.sh
#
# A block whose RTL is fully covered by another block's hierarchy (e.g.
# jtag_tap.v is instantiated by jtag_dtm.v) still gets its own top-level
# lint entry where it's the outermost module that doesn't nest into
# anything else, so every real RTL file in the project is checked as a
# lint top at least once.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VFLAGS="-Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-PINCONNECTEMPTY"

declare -a NAMES=()
declare -a RESULTS=()
declare -a COUNTS=()

lint_one() {
  local block="$1" report_name="$2" top="$3"
  shift 3
  local files=("$@")

  mkdir -p "$ROOT/blocks/$block/lint"
  local report="$ROOT/blocks/$block/lint/lint_report.txt"
  local scratch
  scratch="$(mktemp)"

  verilator $VFLAGS --lint-only --top-module "$top" "${files[@]}" > "$scratch" 2>&1

  local warn_count
  warn_count=$(grep -c "^%Warning" "$scratch" || true)

  {
    echo "=== verilator --lint-only --top-module $top ==="
    echo "Files: ${files[*]}"
    echo
    cat "$scratch"
    if [ "$warn_count" -eq 0 ]; then echo "(clean)"; fi
  } >> "$report.tmp"
  rm -f "$scratch"

  NAMES+=("$block/$report_name")
  COUNTS+=("$warn_count")
  if [ "$warn_count" -eq 0 ]; then
    RESULTS+=("CLEAN")
  else
    RESULTS+=("$warn_count warning(s)")
  fi
}

finish_report() {
  local block="$1"
  local report="$ROOT/blocks/$block/lint/lint_report.txt"
  if [ -f "$report.tmp" ]; then
    mv "$report.tmp" "$report"
  fi
}

echo "=== RISCV_SOC per-block lint-only pass ==="
echo

# clear any stale .tmp left over from an interrupted previous run, so
# multi-entry blocks (jtag, dma) don't silently accumulate old content
rm -f "$ROOT"/blocks/*/lint/lint_report.txt.tmp

lint_one timer timer timer \
  -I"$ROOT/rtl/include" "$ROOT/blocks/timer/rtl/timer.v"
finish_report timer

lint_one watchdog watchdog watchdog \
  -I"$ROOT/rtl/include" "$ROOT/blocks/watchdog/rtl/watchdog.v"
finish_report watchdog

lint_one uart uart uart \
  -I"$ROOT/rtl/include" "$ROOT/blocks/uart/rtl/uart.v"
finish_report uart

lint_one sram sram sram \
  -I"$ROOT/rtl/include" "$ROOT/blocks/sram/rtl/sram.v"
finish_report sram

lint_one boot_rom boot_rom boot_rom \
  -I"$ROOT/rtl/include" "$ROOT/blocks/boot_rom/rtl/boot_rom.v"
finish_report boot_rom

lint_one i2c i2c_master i2c_master \
  -I"$ROOT/rtl/include" "$ROOT/blocks/i2c/rtl/i2c_master.v"
finish_report i2c

lint_one spi spi_master spi_master \
  -I"$ROOT/rtl/include" "$ROOT/blocks/spi/rtl/spi_master.v"
finish_report spi

# jtag: jtag_dtm nests jtag_tap; jtag_axi_bridge is a separate top (the two
# communicate via toggle-sync signals, not Verilog hierarchy)
lint_one jtag jtag_dtm jtag_dtm \
  -I"$ROOT/rtl/include" "$ROOT/blocks/jtag/rtl/jtag_tap.v" "$ROOT/blocks/jtag/rtl/jtag_dtm.v"
lint_one jtag jtag_axi_bridge jtag_axi_bridge \
  -I"$ROOT/rtl/include" "$ROOT/blocks/jtag/rtl/jtag_axi_bridge.v"
finish_report jtag

# aes: full nested hierarchy (aes -> aes_chain -> aes_core -> aes_key_expand)
lint_one aes aes aes \
  -I"$ROOT/rtl/include" -I"$ROOT/blocks/aes/rtl" \
  "$ROOT/blocks/aes/rtl/aes_key_expand.v" "$ROOT/blocks/aes/rtl/aes_core.v" \
  "$ROOT/blocks/aes/rtl/aes_chain.v" "$ROOT/blocks/aes/rtl/aes.v"
finish_report aes

lint_one axi_lite_xbar axi_lite_xbar axi_lite_xbar \
  -I"$ROOT/rtl/include" "$ROOT/blocks/axi_lite_xbar/rtl/axi_lite_xbar.v"
finish_report axi_lite_xbar

# dma: dma_engine nests aes_chain (and its own dependents); dma_ram is a
# separate top (a peer memory, not nested inside dma_engine)
lint_one dma dma_engine dma_engine \
  -I"$ROOT/rtl/include" -I"$ROOT/blocks/aes/rtl" \
  "$ROOT/blocks/aes/rtl/aes_key_expand.v" "$ROOT/blocks/aes/rtl/aes_core.v" \
  "$ROOT/blocks/aes/rtl/aes_chain.v" "$ROOT/blocks/dma/rtl/dma_engine.v"
lint_one dma dma_ram dma_ram \
  -I"$ROOT/rtl/include" "$ROOT/blocks/dma/rtl/dma_ram.v"
finish_report dma

# soc_top: the whole SoC's hierarchy, including the vendored PicoRV32 core
lint_one soc_top soc_top soc_top \
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
finish_report soc_top

echo
printf "%-24s %-16s\n" "BLOCK/TOP" "RESULT"
printf "%-24s %-16s\n" "------------------------" "----------------"
fail_count=0
for i in "${!NAMES[@]}"; do
  printf "%-24s %-16s\n" "${NAMES[$i]}" "${RESULTS[$i]}"
  if [ "${RESULTS[$i]}" != "CLEAN" ]; then
    fail_count=$((fail_count + 1))
  fi
done

echo
if [ $fail_count -eq 0 ]; then
  echo "ALL lint targets clean"
  exit 0
else
  echo "$fail_count lint target(s) have warnings -- see blocks/<name>/lint/lint_report.txt"
  exit 1
fi

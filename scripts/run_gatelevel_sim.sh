#!/usr/bin/env bash
# Runs the aes_core and soc_top regression testbenches against a
# synthesized gate-level netlist instead of the RTL source -- verifying
# that Yosys's logic synthesis/optimization pass didn't change behavior
# (a real synthesis-correctness question RTL-only regression can't answer).
# Complements the formal RTL-vs-netlist equivalence check (see
# docs/verification/lec_methodology.md); this one is simulation-based, that one is proof-based.
#
# Scope: aes_core + soc_top only, matching this project's existing
# per-block synthesis/STA scope (see docs/verification/performance.md) -- most blocks
# were never individually synthesized, only these two plus the whole-SoC
# run.
#
# Uses a *generic* (pre-technology-mapping) netlist, not the real
# Nangate45-mapped one used for STA/gate count: this machine only has
# functional Verilog models for a few Nangate45 cell classes (latch/
# clock-gate/adder), not the full basic-gate set, so the real tech-mapped
# netlist can't be simulated directly here. See blocks/soc_top/syn/
# synth_generic.ys for the full rationale.
#
#   ./scripts/run_gatelevel_sim.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VFLAGS="-Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT -Wno-CASEOVERLAP -Wno-CASEINCOMPLETE -Wno-PINMISSING"
# -Wno-PINMISSING: Yosys's `synth` optimizer removes ports it proves are
# dead (e.g. PicoRV32's unused PCPI coprocessor interface, and
# axi_lite_xbar's s0_bresp/s0_rresp -- PicoRV32's AXI master never checks
# BRESP/RRESP, a pre-existing documented limitation, not something this
# gate-level build introduced) but `write_verilog` doesn't always prune the
# module's own port list to match, so the parent instantiation ends up
# "missing" pins that were already functionally unconnected/ignored in the
# original RTL. Confirmed by inspecting exactly which pins are reported
# missing before adding this suppression -- all of them trace back to
# already-known-unused signals, not a real hookup bug.
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

echo "=== Gate-level simulation: generic (pre-techmap) netlist ==="
echo
echo "--- Yosys: generating generic netlists ---"

pushd "$ROOT/blocks/aes/syn" > /dev/null
if yosys synth_generic.ys > synth_generic_log.txt 2>&1; then
  echo "aes_core generic netlist: OK (blocks/aes/syn/aes_core_generic.v)"
else
  echo "aes_core generic netlist: YOSYS FAILED, see blocks/aes/syn/synth_generic_log.txt"
  exit 1
fi
popd > /dev/null

pushd "$ROOT/blocks/soc_top/syn" > /dev/null
if yosys synth_generic.ys > synth_generic_log.txt 2>&1; then
  echo "soc_top generic netlist: OK (blocks/soc_top/syn/soc_top_generic.v)"
else
  echo "soc_top generic netlist: YOSYS FAILED, see blocks/soc_top/syn/synth_generic_log.txt"
  exit 1
fi
popd > /dev/null

echo
echo "--- Verilator: building + running testbenches against the generic netlist ---"

# aes_core: no memories involved, the generic netlist alone is a complete
# design -- reuse the existing core_sim_main.cpp testbench unmodified.
run_one "aes_core_gatelevel" "$ROOT/blocks/aes/dv" aes_core core_gl_sim obj_dir_core_gl \
  "$ROOT/blocks/aes/syn/aes_core_generic.v" core_sim_main.cpp

# soc_top: the generic netlist has boot_rom/sram/dma_ram as empty
# blackboxes (same treatment as synth.ys, needed so Yosys doesn't try to
# flatten a 32K-word array into flip-flops) -- swap in the real,
# behavioral memory RTL here so the firmware-boot test has real memory
# contents to run against. Everything else in the design (PicoRV32,
# crossbar, every peripheral, AES, DMA, JTAG) comes from the synthesized
# generic netlist, not RTL.
run_one "soc_top_gatelevel" "$ROOT/blocks/soc_top/dv" soc_top soc_gl_sim obj_dir_gl \
  --trace -I"$ROOT/rtl/include" \
  "$ROOT/blocks/soc_top/syn/soc_top_generic.v" \
  ../rtl/boot_rom.v ../rtl/sram.v ../rtl/dma_ram.v \
  sim_main.cpp

echo
printf "%-22s %-12s %s\n" "TARGET" "RESULT" "DETAIL"
printf "%-22s %-12s %s\n" "----------------------" "------------" "------"
fail_count=0
for i in "${!NAMES[@]}"; do
  printf "%-22s %-12s %s\n" "${NAMES[$i]}" "${RESULTS[$i]}" "${DETAILS[$i]}"
  if [ "${RESULTS[$i]}" != "PASS" ]; then
    fail_count=$((fail_count + 1))
  fi
done

echo
if [ $fail_count -eq 0 ]; then
  echo "ALL ${#NAMES[@]} gate-level targets PASS"
  exit 0
else
  echo "$fail_count / ${#NAMES[@]} gate-level targets FAILED"
  exit 1
fi

#!/usr/bin/env bash
# Rebuilds every regression testbench with Verilator's --coverage-line and
# --coverage-toggle instrumentation, runs them, and merges the results into
# reports/sign_off/coverage/merged.dat (+ an lcov .info for tooling that
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
# hit counts against each FSM's known state-to-line mapping (configured in
# scripts/coverage_config.py).
#
# Uses the exact same blocks/*/dv/testlist.sh manifests as
# scripts/run_regression.sh (see scripts/lib_verilator_targets.sh) --
# COVERAGE_MODE=1 tells run_target to add coverage flags and use a
# separate build directory instead of checking PASS/FAIL.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib_verilator_targets.sh"

VFLAGS="-Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-PINCONNECTEMPTY"
BFM_INC="-CFLAGS -I${ROOT}/tb/common"
COVERAGE_MODE=1

COV_DIR="$ROOT/reports/sign_off/coverage"
COV_DAT_DIR="$COV_DIR/dat"
rm -rf "$COV_DAT_DIR"
mkdir -p "$COV_DAT_DIR"

if [ -x "$ROOT/scripts/build_firmware.sh" ]; then
  "$ROOT/scripts/build_firmware.sh" || exit 1
fi

echo "=== Coverage collection: rebuilding + running every block's testbench with --coverage ==="
echo

run_targets_for_all_blocks "blocks/*/dv/testlist.sh"
print_coverage_summary

echo
echo "=== Merging coverage data ==="
verilator_coverage --write "$COV_DIR/merged.dat" "$COV_DAT_DIR"/*.dat
verilator_coverage --write-info "$COV_DIR/coverage.info" "$COV_DIR/merged.dat"
verilator_coverage --annotate "$COV_DIR/annotated" --annotate-all "$COV_DIR/merged.dat"

echo "Merged coverage data: $COV_DIR/merged.dat"
echo "LCOV info:            $COV_DIR/coverage.info"
echo "Annotated source:      $COV_DIR/annotated/"

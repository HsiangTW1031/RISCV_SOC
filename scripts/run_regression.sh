#!/usr/bin/env bash
# Rebuilds and runs every block's Verilator testbench in one pass, then
# prints a PASS/FAIL summary table (Phase 7 exit criterion). Run from
# anywhere; paths below are resolved relative to this script's location.
#
#   ./scripts/run_regression.sh
#
# This script itself knows nothing about which blocks exist -- it just
# sources every blocks/*/dv/testlist.sh it finds (see
# scripts/lib_verilator_targets.sh) and lets each one register its own
# targets via `run_target`. Adding a new block means adding its
# testlist.sh, not editing this file.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib_verilator_targets.sh"

VFLAGS="-Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-PINCONNECTEMPTY"
BFM_INC="-CFLAGS -I${ROOT}/tb/common"

# Optional per-project hook (e.g. building firmware for an embedded CPU
# block) -- only runs if the project actually has one.
if [ -x "$ROOT/scripts/build_firmware.sh" ]; then
  "$ROOT/scripts/build_firmware.sh" || exit 1
fi

echo "=== Regression: rebuilding + running every block's testbench ==="
echo

run_targets_for_all_blocks "blocks/*/dv/testlist.sh"

print_regression_summary
exit $?

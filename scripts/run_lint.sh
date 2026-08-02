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
# Sources every blocks/*/lint/lintlist.sh it finds (see
# scripts/lib_lint_targets.sh) -- adding a new block means adding its
# lintlist.sh, not editing this file. A block whose RTL is fully covered
# by another block's hierarchy (e.g. jtag_tap.v is instantiated by
# jtag_dtm.v) should still register its own top-level lint entry where
# it's the outermost module that doesn't nest into anything else, so
# every real RTL file in the project is checked as a lint top at least
# once -- that's a convention for each lintlist.sh to follow, not
# something this driver enforces.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib_lint_targets.sh"

VFLAGS="-Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-PINCONNECTEMPTY"

echo "=== Per-block lint-only pass ==="
echo

lint_targets_for_all_blocks "blocks/*/lint/lintlist.sh"

print_lint_summary
exit $?

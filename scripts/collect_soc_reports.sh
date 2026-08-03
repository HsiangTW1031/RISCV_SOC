#!/usr/bin/env bash
# Runs the whole-chip sign-off checks (simulation regression, lint,
# synthesis, STA) and collects the results into reports/sign_off/ as a
# single, committed snapshot -- so the final numbers (Fmax, area, which
# tests pass, lint findings) are readable straight from the repo without
# needing Verilator/Yosys/OpenSTA installed to regenerate them.
#
#   ./scripts/collect_soc_reports.sh
#
# Unlike the per-block logs under blocks/*/syn, blocks/*/sta, blocks/*/lint
# (gitignored -- regenerable scratch output), the files this script writes
# into reports/ ARE meant to be committed: they're the sign-off snapshot,
# not a build artifact.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/project_config.sh"
export PROJECT_NAME PROJECT_REPO_URL PROJECT_TAGLINE
OUT="$ROOT/reports/sign_off"
mkdir -p "$OUT"

# Synthesis + STA need Nangate45 liberty files, which can't be vendored
# into this repo (licensing) -- see TOOLCHAIN.md. Without them set, skip
# those two steps gracefully instead of failing the whole run;
# regression/lint/coverage/dashboard don't need a PDK at all.
# NANGATE45_SLOW_LIB is required here too (not just for sta_mcmm.tcl) --
# blocks/soc_top/syn/synth.ys's abc -constr gate-sizing pass maps against
# the slow corner (see docs/performance.md section 7).
if [ -n "${NANGATE45_LIB:-}" ] && [ -f "${NANGATE45_LIB}" ] \
   && [ -n "${NANGATE45_SLOW_LIB:-}" ] && [ -f "${NANGATE45_SLOW_LIB}" ]; then
  HAVE_PDK=1
else
  HAVE_PDK=0
  echo "NOTE: NANGATE45_LIB and/or NANGATE45_SLOW_LIB not set (or file" >&2
  echo "      missing) -- synthesis and STA will be SKIPPED. See" >&2
  echo "      TOOLCHAIN.md to set up the Nangate45 PDK." >&2
fi

echo "=== 1/6: full regression (scripts/run_regression.sh) ==="
"$ROOT/scripts/run_regression.sh" > "$OUT/simulation_regression.txt" 2>&1
regr_rc=$?
tail -25 "$OUT/simulation_regression.txt"
# Each row is "<target-name>  <PASS|FAIL|BUILD-FAIL>  <detail...>" (see
# scripts/lib_verilator_targets.sh) -- the result is the 2nd
# whitespace-separated column, not a line prefix.
n_targets=$(awk '$2 == "PASS" || $2 == "FAIL" || $2 == "BUILD-FAIL"' "$OUT/simulation_regression.txt" | wc -l | tr -d ' ')

echo
echo "=== 2/6: lint (scripts/run_lint.sh) ==="
"$ROOT/scripts/run_lint.sh" > "$OUT/lint_summary.txt" 2>&1
lint_rc=$?
# lintlist.sh entries use absolute paths (needed so multi-directory file
# lists resolve regardless of cwd) -- strip the machine-local prefix
# before this lands in a committed report.
sed "s#$ROOT/##g" "$ROOT/blocks/$TOP_BLOCK/lint/lint_report.txt" > "$OUT/${TOP_BLOCK}_lint_full.txt"
tail -20 "$OUT/lint_summary.txt"

echo
echo "=== 3/6: synthesis (blocks/$TOP_BLOCK/syn/synth.ys) ==="
SYNTH_FULL_LOG="$ROOT/blocks/$TOP_BLOCK/syn/synth_log.txt"
if [ "$HAVE_PDK" -eq 1 ]; then
  ( cd "$ROOT/blocks/$TOP_BLOCK/syn" && ./run_synth.sh > "$SYNTH_FULL_LOG" 2>&1 )
  synth_rc=$?
  # The full Yosys log runs into the tens of MB (every intermediate opt/
  # techmap pass over the whole chip's hierarchy) -- not worth committing.
  # Keep just the final `stat` report (area/cell-count breakdown) here;
  # the full log stays local (gitignored).
  {
    echo "# Whole-chip synthesis area report (Yosys, Nangate45)"
    echo "# Full verbose log (all optimization passes) kept locally at"
    echo "# blocks/$TOP_BLOCK/syn/synth_log.txt -- not committed (tens of MB)."
    echo
    tail -80 "$SYNTH_FULL_LOG"
  } > "$OUT/synthesis_area.txt"
else
  synth_rc=2
  echo "SKIPPED (no NANGATE45_LIB)" > "$OUT/synthesis_area.txt"
fi
tail -15 "$OUT/synthesis_area.txt"

# OpenSTA's simplified Verilog reader can't parse a few things Yosys's
# write_verilog emits (a `signed` keyword on post-synthesis nets, `(* ... *)`
# attribute lines, and a string parameter override on the boot_rom
# instance) -- none of it affects the netlist's actual function, so strip
# it before STA reads the file. See docs/performance.md's methodology note.
NETLIST="$ROOT/blocks/$TOP_BLOCK/syn/${TOP_BLOCK}_out.v"
if [ -f "$NETLIST" ]; then
  sed -i.bak 's/wire signed/wire/g' "$NETLIST"
  sed -i.bak2 -E '/^[[:space:]]*\(\*.*\*\)[[:space:]]*$/d' "$NETLIST"
  python3 - "$NETLIST" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
pattern = re.compile(r'boot_rom #\(\s*\.HEXFILE\("firmware\.hex"\)\s*\)\s*u_rom \(')
content, _ = pattern.subn('boot_rom u_rom (', content)
with open(path, "w") as f:
    f.write(content)
PYEOF
  rm -f "$NETLIST.bak" "$NETLIST.bak2"
fi

echo
echo "=== 4/6: STA (blocks/$TOP_BLOCK/sta/sta.tcl) ==="
if [ "$HAVE_PDK" -eq 1 ]; then
  ( cd "$ROOT/blocks/$TOP_BLOCK/sta" && sta sta.tcl > "$OUT/timing_sta.txt" 2>&1 )
  sta_rc=$?
else
  sta_rc=2
  echo "SKIPPED (no NANGATE45_LIB)" > "$OUT/timing_sta.txt"
fi
tail -20 "$OUT/timing_sta.txt"

echo
echo "=== 5/6: coverage (scripts/run_coverage.sh + analyze_coverage.py) ==="
"$ROOT/scripts/run_coverage.sh" > "$OUT/coverage_run.txt" 2>&1
cov_rc=$?
tail -15 "$OUT/coverage_run.txt"
python3 "$ROOT/scripts/analyze_coverage.py"
analyze_rc=$?

echo
echo "=== 6/6: building the HTML dashboard (scripts/build_dashboard.py) ==="
python3 "$ROOT/scripts/build_dashboard.py"
dashboard_rc=$?

{
  echo "# $PROJECT_NAME sign-off report snapshot"
  echo
  echo "Generated by scripts/collect_soc_reports.sh on $(date '+%Y-%m-%d %H:%M %Z')."
  echo
  echo "| Check | Result | File |"
  echo "|---|---|---|"
  echo "| Simulation regression ($n_targets targets) | $([ $regr_rc -eq 0 ] && echo PASS || echo FAIL) | \`simulation_regression.txt\` |"
  echo "| Lint (per-block, lint-only) | $([ $lint_rc -eq 0 ] && echo CLEAN || echo "warnings present") | \`lint_summary.txt\`, \`${TOP_BLOCK}_lint_full.txt\` |"
  echo "| Synthesis (Yosys, Nangate45) | $([ $synth_rc -eq 0 ] && echo OK || ([ $synth_rc -eq 2 ] && echo "SKIPPED (no PDK)" || echo FAIL)) | \`synthesis_area.txt\` |"
  echo "| STA (OpenSTA) | $([ $sta_rc -eq 0 ] && echo OK || ([ $sta_rc -eq 2 ] && echo "SKIPPED (no PDK)" || echo FAIL)) | \`timing_sta.txt\` |"
  echo "| Coverage (line/toggle/branch/FSM) | $([ $cov_rc -eq 0 ] && echo OK || echo FAIL) | \`coverage/merged.dat\`, \`dashboard_data.json\` |"
  echo "| HTML dashboard | $([ $dashboard_rc -eq 0 ] && echo OK || echo FAIL) | \`dashboard.html\` (open directly in a browser) |"
  echo
  echo "See \`docs/performance.md\` and \`docs/verification_summary.md\` for the narrative writeup of these numbers."
} > "$OUT/README.md"

echo
echo "=== Reports collected into $OUT ==="
ls -la "$OUT"

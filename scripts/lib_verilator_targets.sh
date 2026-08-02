#!/usr/bin/env bash
# Shared by scripts/run_regression.sh and scripts/run_coverage.sh. Each
# block's blocks/<name>/dv/testlist.sh calls `run_target` once per test
# scenario it defines (build+run one Verilator testbench); this file
# supplies that function plus the result-aggregation arrays and summary
# printer, so a target's file list/flags live in exactly one place
# regardless of which mode (regression vs coverage) is currently running.
#
# Callers must set before sourcing any testlist.sh:
#   ROOT           - repo root (absolute path)
#   VFLAGS         - base Verilator flags (coverage flags added automatically)
#   BFM_INC        - extra -CFLAGS for shared testbench headers (may be empty)
#   COVERAGE_MODE  - set (non-empty) for coverage mode; unset for regression
#   COV_DAT_DIR    - (coverage mode only) where to copy each coverage.dat
set -u

declare -a NAMES=()
declare -a RESULTS=()
declare -a DETAILS=()

# run_target <name> <workdir> <top-module> <outbin-base> <mdir-base> <verilator-args...>
#
# <outbin-base>/<mdir-base> are mode-agnostic base names (e.g. "sim"/
# "obj_dir") -- run_target appends "_cov" itself in coverage mode so a
# regression run and a coverage run never clobber each other's build
# output, without testlist.sh needing to know which mode is active.
run_target() {
  local name="$1" workdir="$2" top="$3" outbin="$4" mdir="$5"
  shift 5
  local files=("$@")

  local build_vflags="$VFLAGS"
  local real_outbin="$outbin"
  local real_mdir="$mdir"
  if [ -n "${COVERAGE_MODE:-}" ]; then
    build_vflags="$VFLAGS --coverage-line --coverage-toggle"
    real_outbin="${outbin}_cov"
    real_mdir="${mdir}_cov"
  fi

  NAMES+=("$name")
  pushd "$workdir" > /dev/null
  [ -n "${COVERAGE_MODE:-}" ] && rm -f coverage.dat

  if ! verilator $build_vflags --cc --exe --build --top-module "$top" $BFM_INC \
        "${files[@]}" -o "$real_outbin" --Mdir "$real_mdir" > "${real_mdir}_build.log" 2>&1; then
    RESULTS+=("BUILD-FAIL")
    DETAILS+=("build failed, see ${workdir}/${real_mdir}_build.log")
    popd > /dev/null
    return
  fi

  if [ -n "${COVERAGE_MODE:-}" ]; then
    if ./"$real_mdir"/"$real_outbin" > /dev/null 2>&1 && [ -f coverage.dat ]; then
      cp coverage.dat "$COV_DAT_DIR/$name.dat"
      RESULTS+=("OK")
    else
      RESULTS+=("RUN-FAIL")
    fi
    DETAILS+=("")
  else
    local out rc last_line
    out="$(./"$real_mdir"/"$real_outbin" 2>&1)"
    rc=$?
    last_line="$(echo "$out" | grep -E '^(PASS|FAIL):' | tail -1)"
    if [ $rc -eq 0 ] && [[ "$last_line" == PASS:* ]]; then
      RESULTS+=("PASS")
    else
      RESULTS+=("FAIL")
    fi
    DETAILS+=("$last_line")
  fi
  popd > /dev/null
}

# run_targets_for_all_blocks <glob-relative-to-ROOT>
# Sources every matching per-block manifest (e.g. blocks/*/dv/testlist.sh),
# in sorted order, so block discovery needs no central list anywhere.
run_targets_for_all_blocks() {
  local pattern="$1"
  local f
  for f in $ROOT/$pattern; do
    [ -f "$f" ] || continue
    # shellcheck disable=SC1090
    source "$f"
  done
}

print_regression_summary() {
  echo
  printf "%-24s %-12s %s\n" "TARGET" "RESULT" "DETAIL"
  printf "%-24s %-12s %s\n" "------------------------" "------------" "------"
  local fail_count=0
  local i
  for i in "${!NAMES[@]}"; do
    printf "%-24s %-12s %s\n" "${NAMES[$i]}" "${RESULTS[$i]}" "${DETAILS[$i]}"
    if [ "${RESULTS[$i]}" != "PASS" ]; then
      fail_count=$((fail_count + 1))
    fi
  done
  echo
  if [ "$fail_count" -eq 0 ]; then
    echo "ALL ${#NAMES[@]} regression targets PASS"
    return 0
  else
    echo "$fail_count / ${#NAMES[@]} regression targets FAILED"
    return 1
  fi
}

print_coverage_summary() {
  echo
  printf "%-18s %s\n" "TEST" "STATUS"
  local i
  for i in "${!NAMES[@]}"; do
    printf "%-18s %s\n" "${NAMES[$i]}" "${RESULTS[$i]}"
  done
}

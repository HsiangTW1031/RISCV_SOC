#!/usr/bin/env bash
# Shared by scripts/run_lint.sh. Each block's blocks/<name>/lint/lintlist.sh
# calls `lint_target` once per meaningful RTL-hierarchy top in that block
# (not necessarily one per regression test scenario -- e.g. a block whose
# testbenches cover 5 different top modules may only need 1 or 2 lint
# tops if most of those modules nest inside one real hierarchy).
#
# Callers must set before sourcing any lintlist.sh:
#   ROOT    - repo root (absolute path)
#   VFLAGS  - Verilator lint flags
set -u

declare -a NAMES=()
declare -a RESULTS=()
declare -a COUNTS=()

# lint_target <block> <report-name> <top-module> <files...>
lint_target() {
  local block="$1" report_name="$2" top="$3"
  shift 3
  local files=("$@")

  mkdir -p "$ROOT/blocks/$block/lint"
  local report="$ROOT/blocks/$block/lint/lint_report.txt"
  local scratch
  scratch="$(mktemp)"

  verilator $VFLAGS --lint-only --top-module "$top" "${files[@]}" > "$scratch" 2>&1

  local warn_count error_count
  warn_count=$(grep -c "^%Warning" "$scratch" || true)
  # A genuine parse/elaboration failure (syntax error, missing module,
  # etc.) prints "%Error: <message>" lines distinct from Verilator's own
  # closing tally line -- which is ALSO prefixed "%Error:" even when the
  # run's only problem was warnings ("%Error: Exiting due to N
  # warning(s)", since lint-only mode treats warnings as fatal by
  # default). Only counting "^%Warning" and ignoring "^%Error" entirely
  # means a real syntax error -- which produces zero %Warning lines --
  # silently reports CLEAN: Verilator never got far enough to lint
  # anything, but nothing here noticed. Exclude just the closing tally
  # line so a warnings-only run still reports its warning count as
  # before, while any *other* %Error line marks the target as failed.
  error_count=$(grep "^%Error" "$scratch" | grep -vc "Exiting due to" || true)

  {
    echo "=== verilator --lint-only --top-module $top ==="
    echo "Files: ${files[*]}"
    echo
    cat "$scratch"
    if [ "$warn_count" -eq 0 ] && [ "$error_count" -eq 0 ]; then echo "(clean)"; fi
  } >> "$report.tmp"
  rm -f "$scratch"

  NAMES+=("$block/$report_name")
  COUNTS+=("$warn_count")
  if [ "$error_count" -gt 0 ]; then
    RESULTS+=("$error_count error(s)")
  elif [ "$warn_count" -eq 0 ]; then
    RESULTS+=("CLEAN")
  else
    RESULTS+=("$warn_count warning(s)")
  fi
}

# finish_lint_report <block>
# A block whose lintlist.sh calls lint_target more than once (e.g. two
# independent tops that don't nest into each other) accumulates into one
# report.txt.tmp; call this once per block after its lintlist.sh finishes
# to atomically move it into place. Also clears any stale .tmp left by an
# interrupted previous run so multi-entry blocks don't accumulate old
# content across runs.
finish_lint_report() {
  local block="$1"
  local report="$ROOT/blocks/$block/lint/lint_report.txt"
  if [ -f "$report.tmp" ]; then
    mv "$report.tmp" "$report"
  fi
}

lint_targets_for_all_blocks() {
  local pattern="$1"
  local f block
  rm -f "$ROOT"/blocks/*/lint/lint_report.txt.tmp
  for f in $ROOT/$pattern; do
    [ -f "$f" ] || continue
    block="$(basename "$(dirname "$(dirname "$f")")")"
    # shellcheck disable=SC1090
    source "$f"
    finish_lint_report "$block"
  done
}

print_lint_summary() {
  echo
  printf "%-24s %-16s\n" "BLOCK/TOP" "RESULT"
  printf "%-24s %-16s\n" "------------------------" "----------------"
  local fail_count=0
  local i
  for i in "${!NAMES[@]}"; do
    printf "%-24s %-16s\n" "${NAMES[$i]}" "${RESULTS[$i]}"
    if [ "${RESULTS[$i]}" != "CLEAN" ]; then
      fail_count=$((fail_count + 1))
    fi
  done
  echo
  if [ "$fail_count" -eq 0 ]; then
    echo "ALL lint targets clean"
    return 0
  else
    echo "$fail_count lint target(s) have warnings -- see blocks/<name>/lint/lint_report.txt"
    return 1
  fi
}

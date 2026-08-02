#!/usr/bin/env bash
# One-command entry point for reproducing this project's sign-off flow on
# a fresh clone/machine: checks tooling, then runs the full pipeline
# (firmware build -> lint -> regression -> coverage -> synth+STA if a PDK
# is available -> HTML dashboard). See TOOLCHAIN.md for what to install
# first.
#
#   ./scripts/reproduce_all.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== Step 1/2: checking toolchain (scripts/bootstrap_check.sh) ==="
"$ROOT/scripts/bootstrap_check.sh"
bootstrap_rc=$?
echo
if [ $bootstrap_rc -ne 0 ]; then
  echo "Required tools are missing -- fix the [MISSING] entries above (see TOOLCHAIN.md) before continuing." >&2
  exit 1
fi

echo "=== Step 2/2: running the full sign-off flow (scripts/collect_soc_reports.sh) ==="
echo "(firmware build, lint, regression, coverage, and synth+STA if NANGATE45_LIB is set, are all handled by this script)"
echo
"$ROOT/scripts/collect_soc_reports.sh"
collect_rc=$?

echo
if [ $collect_rc -eq 0 ]; then
  echo "=== Done. Open reports/sign_off/dashboard.html in a browser for the results. ==="
else
  echo "=== collect_soc_reports.sh exited non-zero -- check reports/sign_off/README.md for which step failed. ===" >&2
fi
exit $collect_rc

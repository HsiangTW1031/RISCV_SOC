#!/usr/bin/env bash
# Checks that every tool this project's flow needs is on $PATH (and, for
# the PDK-gated steps, that the right env vars are set), and prints a
# version for each. Run this first on a fresh machine/clone -- see
# TOOLCHAIN.md for what to install if anything here is missing.
#
#   ./scripts/bootstrap_check.sh
#
# Exit code is 0 if everything needed for the PDK-free flow (lint,
# regression, coverage, dashboard) is present, even if the PDK/synth/STA
# tools are missing -- those are reported as warnings, not failures, since
# scripts/collect_soc_reports.sh and scripts/reproduce_all.sh already
# handle their absence gracefully.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAIN_PREFIX="${TOOLCHAIN_PREFIX:-riscv-none-elf-}"
missing_required=0
missing_optional=0

check_required() {
  local name="$1" cmd="$2" version_cmd="$3"
  if command -v "$cmd" > /dev/null 2>&1; then
    local ver
    ver="$(eval "$version_cmd" 2>&1 | head -1)"
    printf "  [OK]      %-22s %s\n" "$name" "$ver"
  else
    printf "  [MISSING] %-22s not found on \$PATH -- see TOOLCHAIN.md\n" "$name"
    missing_required=1
  fi
}

check_optional() {
  local name="$1" cmd="$2" version_cmd="$3"
  if command -v "$cmd" > /dev/null 2>&1; then
    local ver
    ver="$(eval "$version_cmd" 2>&1 | head -1)"
    printf "  [OK]      %-22s %s\n" "$name" "$ver"
  else
    printf "  [--]      %-22s not found (only needed for synth/STA/LEC) -- see TOOLCHAIN.md\n" "$name"
    missing_optional=1
  fi
}

check_env_file() {
  local var="$1" note="$2"
  local val="${!var:-}"
  if [ -z "$val" ]; then
    printf "  [--]      %-22s not set (%s)\n" "$var" "$note"
    missing_optional=1
  elif [ ! -f "$val" ]; then
    printf "  [MISSING] %-22s set to '%s' but file doesn't exist\n" "$var" "$val"
    missing_optional=1
  else
    printf "  [OK]      %-22s %s\n" "$var" "$val"
  fi
}

echo "=== Required for lint / regression / coverage / dashboard ==="
check_required "Verilator" verilator "verilator --version"
check_required "Python 3" python3 "python3 --version"
# Only required if this project has an embedded CPU that boots firmware
# (scripts/build_firmware.sh only exists for such projects).
if [ -x "$ROOT/scripts/build_firmware.sh" ]; then
  check_required "${TOOLCHAIN_PREFIX}gcc" "${TOOLCHAIN_PREFIX}gcc" "${TOOLCHAIN_PREFIX}gcc --version"
fi

echo
echo "=== Optional: needed only for synthesis / STA / formal LEC ==="
check_optional "Yosys" yosys "yosys -V"
check_optional "OpenSTA" sta "sta -version"
check_env_file NANGATE45_LIB "typical corner, see TOOLCHAIN.md"
check_env_file NANGATE45_SLOW_LIB "multi-corner STA only"
check_env_file NANGATE45_FAST_LIB "multi-corner STA only"

echo
if [ $missing_required -ne 0 ]; then
  echo "Missing required tools above -- lint/regression/coverage/dashboard will fail. See TOOLCHAIN.md."
  exit 1
elif [ $missing_optional -ne 0 ]; then
  echo "All required tools present. Some optional (synth/STA/LEC) tools/env vars are missing -- those steps will be skipped."
  exit 0
else
  echo "Everything present -- the full flow (including synth/STA) can run."
  exit 0
fi

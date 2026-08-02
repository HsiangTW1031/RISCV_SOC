#!/usr/bin/env bash
# Builds fw/firmware.hex (if missing or older than the firmware sources)
# and copies it into blocks/soc_top/dv/, which is gitignored (regenerable)
# and not built by anything else -- a fresh clone has no firmware.hex at
# all otherwise, and the soc_top regression/coverage targets need it.
#
# Called automatically by run_regression.sh/run_coverage.sh when this file
# exists and is executable; harmless to run standalone too:
#   ./scripts/build_firmware.sh
#
# Projects without an embedded CPU (no fw/ directory) simply don't have
# this file -- run_regression.sh/run_coverage.sh skip the hook entirely.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/scripts/project_config.sh" ] && source "$ROOT/scripts/project_config.sh"
TOP_BLOCK="${TOP_BLOCK:-soc_top}"

FW_DIR="$ROOT/fw"
FW_HEX_DST="$ROOT/blocks/$TOP_BLOCK/dv/firmware.hex"

need_fw_build=0
if [ ! -f "$FW_HEX_DST" ]; then
  need_fw_build=1
else
  for src in "$FW_DIR"/main.c "$FW_DIR"/start.S "$FW_DIR"/custom_ops.S "$FW_DIR"/linker.ld "$FW_DIR"/Makefile; do
    if [ "$src" -nt "$FW_HEX_DST" ]; then
      need_fw_build=1
    fi
  done
fi

if [ "$need_fw_build" -eq 1 ]; then
  echo "=== firmware.hex missing or stale -- building from fw/ ==="
  if ! ( cd "$FW_DIR" && make ) ; then
    echo "ERROR: firmware build failed. Is the RISC-V toolchain" >&2
    echo "(TOOLCHAIN_PREFIX=riscv-none-elf- by default) on \$PATH? See TOOLCHAIN.md." >&2
    exit 1
  fi
  cp "$FW_DIR/firmware.hex" "$FW_HEX_DST"
  echo "firmware.hex rebuilt and copied to blocks/soc_top/dv/"
  echo
fi

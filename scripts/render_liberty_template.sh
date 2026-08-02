#!/usr/bin/env bash
# Renders a Yosys .ys template (containing an @NANGATE45_LIB@ placeholder)
# into a real .ys file with $NANGATE45_LIB substituted in. Yosys command
# scripts have no native environment-variable expansion (confirmed: Yosys
# prints "$env(FOO)" back literally instead of expanding it), so templating
# + sed substitution is how this project keeps the Nangate45 PDK path out
# of version control while still letting `run_synth.sh`/`run_lec.sh` work
# with a single `export NANGATE45_LIB=...`.
#
# Usage: scripts/render_liberty_template.sh <template.ys> <rendered-output.ys>
set -euo pipefail

: "${NANGATE45_LIB:?NANGATE45_LIB is not set. Export it to your Nangate45 typical-corner .lib file path -- see TOOLCHAIN.md.}"

if [ ! -f "$NANGATE45_LIB" ]; then
  echo "ERROR: NANGATE45_LIB=$NANGATE45_LIB does not exist." >&2
  exit 1
fi

template="$1"
out="$2"
sed "s#@NANGATE45_LIB@#${NANGATE45_LIB}#g" "$template" > "$out"

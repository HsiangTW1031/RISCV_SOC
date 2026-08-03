#!/usr/bin/env bash
# Renders a Yosys .ys template (containing an @NANGATE45_LIB@ placeholder,
# and optionally @NANGATE45_SLOW_LIB@/@NANGATE45_FAST_LIB@) into a real .ys
# file with the corresponding $NANGATE45_*_LIB substituted in. Yosys command
# scripts have no native environment-variable expansion (confirmed: Yosys
# prints "$env(FOO)" back literally instead of expanding it), so templating
# + sed substitution is how this project keeps the Nangate45 PDK paths out
# of version control while still letting `run_synth.sh`/`run_lec.sh` work
# with a single `export NANGATE45_LIB=...`.
#
# The slow/fast placeholders are optional -- only required (and only
# substituted) when the template actually references them, so blocks whose
# .ys files only need the typical-corner library don't have to set env vars
# they never use.
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
cp "$template" "$out"
sed -i.bak "s#@NANGATE45_LIB@#${NANGATE45_LIB}#g" "$out"

for var in NANGATE45_SLOW_LIB NANGATE45_FAST_LIB; do
  placeholder="@${var}@"
  if grep -q "$placeholder" "$out"; then
    val="${!var:?$var is not set, but $template references $placeholder -- see TOOLCHAIN.md.}"
    if [ ! -f "$val" ]; then
      echo "ERROR: $var=$val does not exist." >&2
      exit 1
    fi
    sed -i.bak "s#${placeholder}#${val}#g" "$out"
  fi
done

rm -f "$out.bak"

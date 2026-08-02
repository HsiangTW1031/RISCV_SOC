#!/usr/bin/env bash
# Renders synth.ys (substituting $NANGATE45_LIB) and runs it. Replaces the
# old `yosys synth.ys` manual invocation now that the liberty path is a
# template placeholder instead of a hardcoded machine-local path.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

rendered=".synth.rendered.ys"
trap 'rm -f "$rendered"' EXIT
../../../scripts/render_liberty_template.sh synth.ys "$rendered"
yosys "$rendered"

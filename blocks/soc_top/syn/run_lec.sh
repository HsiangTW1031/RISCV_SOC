#!/usr/bin/env bash
# Renders lec.ys (substituting $NANGATE45_LIB) and runs it. Requires
# synth.ys (./run_synth.sh) to have already produced soc_top_out.v.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

rendered=".lec.rendered.ys"
trap 'rm -f "$rendered"' EXIT
../../../scripts/render_liberty_template.sh lec.ys "$rendered"
yosys "$rendered"

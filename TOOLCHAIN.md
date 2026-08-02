# Toolchain setup

This project's sign-off flow (`scripts/collect_soc_reports.sh` /
`scripts/reproduce_all.sh`) depends on external tools that aren't vendored
into this repo. This doc lists exactly what's needed, the versions this
project has actually been run against, and where each piece comes from.

Run `./scripts/bootstrap_check.sh` after installing everything below — it
checks each tool is on `$PATH`, reports its version, and tells you which
PDK env vars (if any) are still missing.

## Required for lint / regression / coverage / dashboard (no PDK needed)

| Tool | Tested version | Install (macOS/Homebrew) |
|---|---|---|
| [Verilator](https://www.veripool.org/verilator/) | 5.050 | `brew install verilator` |
| Python 3 | 3.9+ (stdlib only — no pip packages required) | ships with macOS / `brew install python3` |

These four steps (`run_lint.sh`, `run_regression.sh`, `run_coverage.sh` +
`analyze_coverage.py`, `build_dashboard.py`) never touch a PDK and always
work once Verilator + Python 3 are present.

## Required to build/run firmware (needed for the `soc_top` regression target)

| Tool | Tested version | Install |
|---|---|---|
| RISC-V GCC toolchain | xPack `riscv-none-elf-gcc` **15.2.0-1** | Download the `riscv-none-elf-gcc` archive for your OS/arch from [xPack's riscv-none-elf-gcc releases](https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases) and put its `bin/` on `$PATH`. |

The toolchain prefix must be `riscv-none-elf-` (xPack's naming convention —
`riscv-none-elf-gcc`, `riscv-none-elf-objcopy`), not the more common
`riscv32-unknown-elf-*`/`riscv64-unknown-elf-*` triple used by other
distributions. Override via `fw/Makefile`'s `TOOLCHAIN_PREFIX` if you're
using a differently-prefixed toolchain of an equivalent GCC version.

`scripts/run_regression.sh` builds `firmware.hex` from `fw/` automatically
(and copies it into `blocks/soc_top/dv/`) whenever it's missing or the
firmware sources are newer than the last build — you don't need to run
`fw/Makefile` by hand unless you're iterating on firmware code directly.

## Required for synthesis / STA / formal LEC (needs a Nangate45 PDK)

| Tool | Tested version | Install (macOS/Homebrew) |
|---|---|---|
| [Yosys](https://github.com/YosysHQ/yosys) | 0.67 | `brew install yosys` |
| [OpenSTA](https://github.com/The-OpenROAD-Project/OpenSTA) | 3.1.0 | No Homebrew formula — build from source (see below) |

OpenSTA has no Homebrew formula; build it from source:

```bash
git clone https://github.com/The-OpenROAD-Project/OpenSTA.git
cd OpenSTA
# follow the repo's own build instructions (CMake + its Docker/Brewfile
# dependency list) -- installs a `sta` binary; put it on $PATH.
```

Keep the cloned source tree around after building — the multi-corner STA
scripts (`sta_mcmm.tcl`) need its bundled test-suite corner libraries (see
below), not just the built binary.

### Getting the Nangate45 PDK (not vendored in this repo)

This project targets the **Nangate Open Cell Library** (a non-manufacturable,
research-only 45nm standard-cell library — no relation to a real
manufacturable process). Three liberty files are needed, referenced via
environment variables (no hardcoded paths in this repo — see below):

| Env var | Used by | What it needs to point at |
|---|---|---|
| `NANGATE45_LIB` | `run_synth.sh`, `run_lec.sh`, `sta.tcl` (all blocks) | `NangateOpenCellLibrary_typical.lib` |
| `NANGATE45_SLOW_LIB` | `sta_mcmm.tcl` (multi-corner STA only) | `Nangate45_slow.lib` |
| `NANGATE45_FAST_LIB` | `sta_mcmm.tcl` (multi-corner STA only) | `Nangate45_fast.lib` |

**`NANGATE45_LIB`** — the easiest source is the `flow/platforms/nangate45/lib/`
directory of [OpenROAD-flow-scripts](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts)
(clone that repo, or download just that subdirectory). That directory ships
its own `LICENSE` (Apache-2.0, originally from Si2/NanGate) permitting
redistribution — it just isn't vendored into *this* repo to keep it lean and
to match how PDKs are normally handled (an installed environment resource,
not a build artifact tracked alongside RTL).

**`NANGATE45_SLOW_LIB` / `NANGATE45_FAST_LIB`** — these come from OpenSTA's
own test fixtures: `<opensta-source>/test/nangate45/Nangate45_slow.lib` and
`Nangate45_fast.lib`. They're corner variants of the same underlying Nangate
data, bundled inside the OpenSTA repo for its test suite; their licensing
isn't as clearly marked as the typical-corner file above, so treat them the
same way (obtain your own copy from the OpenSTA source tree you built above,
don't expect them in this repo).

Once you have the files:

```bash
export NANGATE45_LIB=/path/to/nangate45/lib/NangateOpenCellLibrary_typical.lib
export NANGATE45_SLOW_LIB=/path/to/OpenSTA/test/nangate45/Nangate45_slow.lib
export NANGATE45_FAST_LIB=/path/to/OpenSTA/test/nangate45/Nangate45_fast.lib
```

Put these in your shell profile (`~/.zshrc` etc.) so they persist across
sessions. Without them set, `./scripts/collect_soc_reports.sh` and
`./scripts/reproduce_all.sh` still run everything that doesn't need a PDK
(regression/lint/coverage/dashboard) and skip synthesis/STA gracefully
with a note; `run_synth.sh`/`run_lec.sh`/`sta.tcl`/`sta_mcmm.tcl` run
standalone will each fail fast with a clear "NANGATE45_LIB is not set"
error instead of a confusing tool error.

## Why templated `.ys` files instead of a straight env-var read

Yosys `.ys` command scripts have no native environment-variable expansion
(confirmed: `yosys -p 'log $env(FOO)'` prints the literal string `$env(FOO)`,
it doesn't expand it). So `blocks/{aes,soc_top}/syn/{synth,lec}.ys` are
checked in as templates containing an `@NANGATE45_LIB@` placeholder, and
`run_synth.sh` / `run_lec.sh` render them (via `scripts/render_liberty_template.sh`,
a `sed` substitution) into a temp file before invoking Yosys. Run those
wrapper scripts, not `yosys synth.ys` directly. OpenSTA's `.tcl` scripts
don't need this — Tcl reads environment variables natively
(`$::env(NANGATE45_LIB)`), so `sta.tcl`/`sta_mcmm.tcl` are edited directly
and can still be run as plain `sta sta.tcl`.

## Formal LEC timing note

`blocks/aes/syn/run_lec.sh`'s `equiv_induct -seq 12` step takes 10+ minutes
and still only reaches ~97.7% proven (see `docs/lec_report.md`) — it's
deliberately **not** part of `collect_soc_reports.sh`/`reproduce_all.sh`'s
automated path. Run it manually only when you specifically want to redo the
formal equivalence check.

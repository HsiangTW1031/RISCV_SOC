# Changelog

Maps each git tag to what changed and why. Commit messages have the "what";
`docs/project_retrospective.md` has the full bug-by-bug story behind most of
these — this file is the short index between the two.

## [v1.2.0] - 2026-08-03

Convention-over-configuration for lint/regression/coverage: every block now
owns its own `dv/testlist.sh` (regression+coverage targets) and
`lint/lintlist.sh` (lint-only tops), sourced by generic drivers
(`run_regression.sh`/`run_coverage.sh`/`run_lint.sh`) instead of three
central scripts hand-listing every block's file set. Adding a block means
adding its manifest files, not editing shared scripts.

### Added
- `scripts/lib_verilator_targets.sh` / `scripts/lib_lint_targets.sh`:
  shared `run_target`/`lint_target` functions each block's manifest calls
- `scripts/coverage_config.py`: the project-specific knowledge
  `analyze_coverage.py` needs (FSM state tables, lint-finding triage
  rules, vendored-file overrides) -- pulled out of the engine itself
- `scripts/project_config.sh`: project name, repo URL, and which block is
  the whole-chip top level (`TOP_BLOCK`), read by
  `collect_soc_reports.sh`/`build_dashboard.py`/`build_firmware.sh`
  instead of a hardcoded `soc_top`/`RISCV_SOC` string in each

### Changed
- `analyze_coverage.py` auto-discovers which `.v` file belongs to which
  block by scanning `blocks/*/rtl/` (skipping symlinks) instead of a
  hardcoded filename→block dict that would go stale as blocks are added
- `build_dashboard.py` reads project name/URL/tagline from env vars
  (set by `collect_soc_reports.sh` from `project_config.sh`) instead of
  hardcoding "RISCV_SOC" and its GitHub URL in three places

### Fixed
- `soc_top`'s regression/coverage manifest referenced shared RTL through
  its own `rtl/` symlink farm; since coverage dedupes toggle points by
  file path, a symlink's different path string caused every shared
  module's toggle coverage to be double-counted against its owning
  block's own numbers. Switched to canonical per-block paths -- toggle
  coverage now matches the pre-refactor numbers exactly (69.5%/80.1%
  before/after waivers, not the ~43%/51% the bug produced)
- The dashboard's "Regression" KPI tile has shown **"0/0 PASS" since it
  was introduced** (predates this refactor, only caught while validating
  it): the target-count logic assumed each regression-summary row starts
  with `PASS:`/`FAIL:`, but rows actually start with the target's own
  name -- the result is the 2nd column. Now correctly shows the real
  pass count (`19/19 PASS`), and would show a partial count in red if a
  future run actually had failures instead of silently reading zero
- `bootstrap_check.sh` only requires the RISC-V toolchain when
  `scripts/build_firmware.sh` exists, instead of unconditionally (a
  project without an embedded CPU would have failed this check for a
  toolchain it doesn't need)

This engine was also packaged as a reusable skill
(`Levi-agent/.claude/skills/ic-verification-scaffold`) for scaffolding
future IC/SoC projects with the same automation from day one — see that
skill's `references/design-rationale.md` for the full story, including
these two bugs.

Verified regression (19/19 PASS), lint (135 findings, identical
per-block counts), coverage (line/branch/toggle before+after waivers),
and synthesis chip area all match the pre-refactor numbers exactly.

## [v1.1.0] - 2026-08-02

Local reproducibility: a fresh clone on another machine can now run the
whole sign-off flow (or as much of it as the machine has tools for) with a
documented, scripted path instead of hitting one developer's hardcoded
`/Users/.../eda/...` paths.

### Added
- `TOOLCHAIN.md`: exact tested tool versions (Verilator 5.050, Yosys 0.67,
  OpenSTA 3.1.0, xPack `riscv-none-elf-gcc` 15.2.0-1) and where to get the
  Nangate45 PDK
- `scripts/bootstrap_check.sh`: verifies every tool + PDK env var is in
  place before running anything
- `scripts/reproduce_all.sh`: one command from a fresh clone to firmware
  build → lint → regression → coverage → synth+STA (if a PDK is present)
  → HTML dashboard
- `blocks/{aes,soc_top}/syn/run_synth.sh` / `run_lec.sh`: render the
  `@NANGATE45_LIB@` template in `synth.ys`/`lec.ys` and invoke Yosys —
  Yosys command scripts have no native env-var expansion, so this
  replaces the old `yosys synth.ys` manual invocation
- `run_regression.sh` now auto-builds and copies `firmware.hex` from
  `fw/` when it's missing or stale, instead of failing the `soc_top`
  target with no explanation on a fresh clone

### Changed
- `blocks/{aes,soc_top}/{syn,sta}/*.{ys,tcl}` (10 files): hardcoded
  Nangate45 liberty paths replaced with `NANGATE45_LIB` /
  `NANGATE45_SLOW_LIB` / `NANGATE45_FAST_LIB` env vars — `.tcl` files
  read them natively via `$::env(...)`, `.ys` files via the template +
  wrapper approach above
- `scripts/collect_soc_reports.sh` now skips synthesis/STA gracefully
  (marked `SKIPPED (no PDK)`) instead of failing outright when
  `NANGATE45_LIB` isn't set
- **Decision: the Nangate45 PDK stays out of version control** (BYO-PDK).
  The typical-corner liberty file turned out to be Apache-2.0 and could
  legally be vendored, but the OpenSTA-bundled slow/fast corner files
  don't carry the same clear licensing, and treating the PDK as an
  installed environment resource (not a build artifact) matches real
  industry practice.

### Fixed
- `scripts/build_dashboard.py` crashed (`TypeError` on `NoneType`) when
  rendering the dashboard after synthesis/STA were skipped — found while
  testing the no-PDK path end-to-end; now shows "N/A (no PDK)" instead
- `scripts/build_dashboard.py`'s regression-pass check matched the
  literal string `"ALL 18 regression targets PASS"`, stale since a 19th
  target (`jtag_chain_fast_tck`) was added — now matches `ALL \d+ ...`

Includes the artifact refresh from `7dcb557` (re-ran signoff reports
after the reset-synchronizer RTL change landed in v1.0.0).

## [v1.0.0] - 2026-08-02

Everything past the Phase 7 checklist: turning "all phases done" into an
actual sign-off-grade result, one layer at a time (see
`docs/project_retrospective.md`'s "Phase 7 後續補強" for the bug-by-bug
version of this list).

### Added
- Dedicated per-block Verilator `--lint-only` pass, independent of
  whatever a given testbench build happens to suppress — caught 4 real
  dead-code findings
- `reports/sign_off/`: a one-stop, committed sign-off snapshot
  (regression + lint + synthesis + STA + coverage) readable without the
  toolchain installed
- Quantitative coverage (line/toggle/branch/FSM) and an HTML sign-off
  dashboard (`scripts/run_coverage.sh` → `analyze_coverage.py` →
  `build_dashboard.py`)
- Toggle coverage waiver process, with a quantified before/after report
  for signals that structurally can never toggle
- Multi-corner STA (setup at the slow corner, hold at the fast corner),
  formal LEC (logic equivalence check between RTL and the synthesized
  netlist), and gate-level simulation
- CDC (Clock Domain Crossing) verification: SDC async clock grouping,
  structural review, and a ratio stress test (`tck` faster than `clk`)
- RDC (Reset Domain Crossing) synchronizers for the `clk` and `tck`
  domains — this project's only genuinely asynchronous-reset flip-flops

### Changed
- Renamed directories to match industry-standard naming:
  `sim`→`dv`, `sdc`→`constraints`, `reports/soc_top`→`reports/sign_off`
- Removed résumé/interview-oriented wording from committed docs so they
  read as pure technical documentation

### Fixed
- A watchdog testbench constant that had drifted from the RTL's actual
  default and gone unnoticed because a stale binary kept looking green —
  caught the first time the new unified `run_regression.sh` ran

## [phase7] - 2026-08-02

- Architecture, memory-map, verification, and performance docs
- Whole-SoC synthesis + STA against Nangate45
- Unified regression script (`scripts/run_regression.sh`)

## [phase6] - 2026-08-02

- AES CBC/CTR chaining
- AXI4 burst DMA engine, wired into `soc_top`

## [phase5] - 2026-08-02

- JTAG debug bridge
- Crossbar upgraded from single-master to 2-master arbitration
- README status refresh for Phases 3-4

## [phase4] - 2026-08-01

- AES-128 encrypt+decrypt core, wired into `soc_top`
- Nangate45 synthesis + STA for the AES core, standalone AES spec/report
- IP specifications for Timer, Watchdog, UART, I2C, SPI

## [phase3] - 2026-08-01

- I2C master + SPI master, crossbar expanded to 7 slaves

## [phase2] - 2026-08-01

- Timer + Watchdog interrupts through PicoRV32's real IRQ mechanism

## [phase1] - 2026-08-01

- Hand-written AXI4-Lite crossbar, ROM/RAM/UART
- `soc_top` boots real firmware for the first time

## [phase0] - 2026-08-01

- Project docs and phase plan
- PicoRV32 vendored into `rtl/core/`

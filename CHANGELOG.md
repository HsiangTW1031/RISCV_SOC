# Changelog

Maps each git tag to what changed and why. Commit messages have the "what";
`docs/project_retrospective.md` has the full bug-by-bug story behind most of
these — this file is the short index between the two.

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

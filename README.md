# RISCV_SOC

A from-scratch RISC-V SoC platform: PicoRV32 core, a hand-written AXI4-Lite
crossbar, an AES-128 accelerator, and a set of peripherals (timer, watchdog,
UART, I2C, SPI, JTAG). Simulation-based sign-off (Verilator + Yosys/Nangate45
+ OpenSTA) — no FPGA or ASIC tape-out target.

Full project plan, phase-by-phase breakdown, architecture rationale, and open
risks: see [`docs/phase_plan.md`](docs/phase_plan.md).

## Status

Phase 0 (foundation) in progress:
- [x] PicoRV32 vendored into `rtl/core/` (see `rtl/core/VENDORED_SOURCE.md`)
- [x] RISC-V toolchain installed (xPack `riscv-none-elf-gcc` 15.2.0) and
      validated end-to-end against PicoRV32's own Verilator testbench
- [x] `IC_fe_flow` skill's `run_flow.sh` generalized to support multi-file
      filelists, per-block `rtl/`+`sdc/` conventions, and configurable
      liberty path
- [ ] git repo pushed to GitHub
- [ ] Phase 1: hand-written AXI4-Lite crossbar + first runnable SoC skeleton

## Layout

Each block under `blocks/` is independently runnable through the shared
`IC_fe_flow` skill:

```bash
~/Desktop/Levi-agent/.claude/skills/IC_fe_flow/run_flow.sh \
    ~/Desktop/Levi-agent/projects/RISCV_SOC/blocks/<block-name> <top_module> <clk_period_ns>
```

See `docs/phase_plan.md` for the full directory structure and the reasoning
behind it (per-block `rtl/lint/sdc/syn/sta/sim`, shared `rtl/core`, `fw/`,
`tb/common/`).

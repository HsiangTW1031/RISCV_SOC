# RISCV_SOC

A from-scratch RISC-V SoC platform: PicoRV32 core, a hand-written AXI4-Lite
crossbar, an AES-128 accelerator, and a set of peripherals (timer, watchdog,
UART, I2C, SPI, JTAG). Simulation-based sign-off (Verilator + Yosys/Nangate45
+ OpenSTA) — no FPGA or ASIC tape-out target.

Full project plan, phase-by-phase breakdown, architecture rationale, and open
risks: see [`docs/phase_plan.md`](docs/phase_plan.md).

## Status

**Phase 0 (foundation) — done:**
- [x] PicoRV32 vendored into `rtl/core/` (see `rtl/core/VENDORED_SOURCE.md`)
- [x] RISC-V toolchain installed (xPack `riscv-none-elf-gcc` 15.2.0) and
      validated end-to-end against PicoRV32's own Verilator testbench
- [x] git repo initialized and pushed to GitHub
      (github.com/HsiangTW1031/RISCV_SOC)

**Phase 1 (runnable SoC skeleton) — done:**
- [x] Shared AXI4-Lite signal/port convention (`rtl/include/axi_lite.vh`,
      `rtl/include/addr_map.vh`)
- [x] C++ AXI-Lite bus functional model (`tb/common/axi_lite_bfm.h`),
      validated against a trivial always-ready fake slave first
- [x] Hand-written `axi_lite_xbar` (1 master × 3 slaves for this phase:
      ROM/RAM/UART), address-decode + SLVERR-on-miss validated against fake
      slave stand-ins before any real peripheral existed
- [x] `boot_rom` (64KB, `$readmemh`) and `sram` (128KB, byte-strobe writes)
      behavioral models, each independently tested
- [x] `uart` (TX-only), independently tested by decoding the actual serial
      line bit-by-bit
- [x] `soc_top` integration (CPU + crossbar + ROM/RAM/UART) + firmware
      (`fw/`) + a self-checking testbench that decodes UART TX and diffs
      against the expected string
- [x] **First real milestone reached: the full SoC boots real compiled C
      firmware and prints `Hello World` over the (simulated) UART line —
      1206 cycles, testbench exits 0.**

**Phase 2 (interrupts, timer, watchdog) — done:**
- [x] `axi_lite_xbar` expanded to 5 slaves (added Timer, Watchdog)
- [x] `timer` — down-counter, auto-reload, sticky STATUS.EXPIRED, one-cycle
      `irq` pulse; cycle-accurate directed unit test
- [x] `watchdog` — WARNING interrupt at a configurable margin before
      timeout, a level-held `wdog_reset_req` output when it actually
      expires, KICK to feed it; cycle-accurate directed unit test covering
      both the WARNING and reset-request timing exactly
- [x] `fw/custom_ops.S` (PicoRV32's getq/setq/retirq/maskirq opcodes) +
      `fw/start.S` real ISR (saves all caller-saved GPRs + q0, masks IRQs
      for the duration of the handler, calls a C `irq_handler`)
- [x] `soc_top`: `ENABLE_IRQ=1`, irq[3]=Timer, irq[4]=Watchdog
- [x] **Milestone: the full SoC runs 5 real Timer interrupts through
      PicoRV32's non-standard IRQ mechanism, kicks the Watchdog from the
      ISR each time, and reports the count over UART — 8907 cycles,
      testbench exits 0.**
- [x] Found and fixed a real hardware/firmware interaction bug during
      bring-up: a **level-held** IRQ line combined with PicoRV32's
      `LATCHED_IRQ` mechanism (which re-OR's the raw irq input into its
      internal pending register every cycle, regardless of the dynamic
      `maskirq` mask) guarantees a spurious second ISR entry once the
      handler unmasks, no matter how fast firmware clears the status bit.
      Fixed by making `timer`/`watchdog`'s `irq` outputs single-cycle
      **pulses** instead, with the sticky status bits kept as separate,
      independently-readable registers. See `blocks/timer/rtl/timer.v`'s
      header comment for the full explanation.

**Not started:** Phase 3 (I2C, SPI) onward — see `docs/phase_plan.md`.

## Running things

There's no flow-automation skill wired up yet for this project (the
generic `IC_fe_flow` skill was retired — a project-specific one will
replace it once the architecture has settled). For now, lint/synth/sim/STA
are run directly:

```bash
# full-SoC smoke test (rebuilds + runs; firmware.hex must already be built)
cd blocks/soc_top/sim
verilator -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-PINCONNECTEMPTY \
  --cc --exe --build --trace --top-module soc_top \
  -I../../../rtl/include \
  ../rtl/picorv32.v ../rtl/axi_lite_xbar.v ../rtl/boot_rom.v ../rtl/sram.v \
  ../rtl/timer.v ../rtl/watchdog.v ../rtl/uart.v ../rtl/soc_top.v \
  sim_main.cpp -o soc_sim --Mdir obj_dir
./obj_dir/soc_sim

# rebuild firmware after editing fw/main.c or fw/start.S
cd fw && make && cp firmware.hex ../blocks/soc_top/sim/firmware.hex
```

The `-Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED` flags silence lint
warnings that come from PicoRV32's own (unmodified, vendored) coding
style, not from this project's RTL.

## Layout

Each block under `blocks/` has its own `rtl/lint/sdc/syn/sta/sim` —
independent enough to lint/synthesize/STA on its own later (useful for
giving e.g. `aes` its own synthesis report). `soc_top`'s `rtl/` is a set of
symlinks into every other block's canonical source, so there's exactly one
copy of each module. See `docs/phase_plan.md` for the full rationale.

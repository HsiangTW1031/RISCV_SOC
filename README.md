# RISCV_SOC

A from-scratch RISC-V SoC platform: PicoRV32 core, a hand-written AXI4-Lite
crossbar, an AES-128 accelerator (with CBC/CTR chaining and an AXI4 burst
DMA engine), and a set of peripherals (timer, watchdog, UART, I2C, SPI,
JTAG). Simulation-based sign-off (Verilator + Yosys/Nangate45 + OpenSTA) —
no FPGA or ASIC tape-out target.

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

**Phase 3 (I2C, SPI) — done:**
- [x] `axi_lite_xbar` expanded to 7 slaves (added I2C, SPI)
- [x] `spi_master` — shift-register, all 4 CPOL/CPHA modes, configurable
      clock divider; tested byte-accurate against a fake SPI slave over
      loopback (all 4 modes, busy/no-queue behavior)
- [x] `i2c_master` — byte-level FSM (START / 7-bit addr+RW / ACK / data /
      STOP), no clock stretching and no multi-byte burst (documented scope
      cuts); tested against a fake I2C slave (write, read,
      NACK-on-unknown-address, busy/no-queue)
- [x] `soc_top` wired, full-SoC regression (Hello World + 5 Timer IRQs)
      confirmed unchanged after the crossbar/soc_top expansion
- [x] Found and fixed two real I2C protocol-timing bugs during bring-up
      (not just logic bugs): a START condition split across the wrong
      number of clock edges, and an ACK/NACK drive released at
      `scl_rising` instead of the following `scl_falling` — the latter
      looks electrically identical to a STOP condition (SDA rises while
      SCL is still high) and was aborting every transfer instantly. See
      `blocks/i2c/rtl/i2c_master.v`'s header comment.

**Phase 4 (AES-128 accelerator, résumé-focus module) — done:**
- [x] `aes_pkg.vh` — S-box, inverse S-box, and the GF(2^8)
      multiply-by-constant helpers MixColumns/InvMixColumns need, derived
      from first principles (multiplicative inverse + the FIPS-197 affine
      transform) in a throwaway script rather than hand-transcribed, then
      cross-checked against published FIPS-197 reference values
- [x] `aes_key_expand` — iterative (one round key per clock cycle) AES-128
      key schedule, verified against the FIPS-197 Appendix A.1 key
      expansion example
- [x] `aes_core` — iterative round datapath (~21 cycles/block), both
      encrypt and decrypt (FIPS-197 5.3's straightforward Inverse Cipher);
      verified against the FIPS-197 Appendix B and Appendix C.1
      known-answer vectors in both directions, plus a 500-iteration
      differential test against an independent, from-scratch C++
      reference model
- [x] `aes` AXI4-Lite register wrapper — KEY registers are deliberately
      **write-only** (no key readback), unlike every other R/W register in
      this project
- [x] `axi_lite_xbar` expanded to 8 slaves (added AES); `soc_top` wired;
      full-SoC regression still unchanged
- [x] Nangate45 synthesis + STA (`blocks/aes/syn`, `blocks/aes/sta`):
      `aes_core` ≈ 39,406 μm², critical path 10.153 ns (Fmax ≈ 98.5 MHz) —
      running through the key schedule's variable-indexed round-key read,
      not the round datapath itself as originally expected; root cause and
      the obvious pipelining fix are written up rather than hidden
- [x] `docs/specs/*.md` for all six peripherals (Timer, Watchdog, UART,
      I2C, SPI, AES) and `docs/aes_report.md` (what AES/Rijndael is, its
      FIPS-197 standardization history, why it's still considered secure
      today, and an explicit list of what this RTL implementation does
      *not* provide — no side-channel hardening, not production-secure)

**Phase 5 (JTAG debug bridge, crossbar → 2-master) — done:**
- [x] `jtag_tap` — IEEE 1149.1 16-state TAP FSM, verified against an
      independent C++ transition-table model over 5000 random TMS steps,
      plus an explicit test of the "5 consecutive TMS=1 always returns to
      Test-Logic-Reset from any state" safety property
- [x] `jtag_dtm` — IR/DR registers (IDCODE, BYPASS, AXI_ADDR/AXI_DATA/AXI_CTRL)
- [x] `jtag_axi_bridge` — the only module crossing the `tck`/`clk` clock
      domains; owns its own CDC (toggle-bit synchronization, not level
      synchronization — see below)
- [x] `axi_lite_xbar` upgraded from 1 master to a genuine 2-master design
      (CPU=s0, JTAG bridge=s1), fixed-priority arbitration (CPU wins ties),
      write/read channel groups arbitrated independently, grant locked for
      the full duration of an in-flight transaction
- [x] `soc_top` wired; JTAG writes and reads back a RAM scratch word
      through the real crossbar without disturbing the existing firmware
      regression (Hello World + 5 Timer IRQs still passes unchanged)
- [x] Found and fixed two real bugs during bring-up: a level-based CDC
      synchronizer that silently missed short BUSY pulses whenever `tck`
      ran much slower than `clk` (fixed with toggle-bit synchronization,
      which can't miss a transition regardless of clock ratio), and a
      crossbar arbitration bug where the write-side grant could be stolen
      mid-transaction on the exact cycle both AW and W landed together —
      caught only by `soc_top`-level integration testing (concurrent CPU +
      JTAG contention), not the crossbar's own unit test. See
      `docs/specs/jtag.md` and `docs/project_retrospective.md`.

**Phase 6 (optional extension: AES CBC/CTR + AXI4 burst DMA) — done:**
- [x] `aes_chain` — CBC/CTR mode-of-operation wrapper around the unmodified
      Phase 4 `aes_core`, verified against NIST SP 800-38A Appendix F.2/F.5
      vectors (both directions)
- [x] `rtl/include/axi4.vh` + `dma_ram` — a deliberately-scoped-down AXI4
      burst subset (INCR bursts, fixed 4-byte beats), kept architecturally
      separate from the AXI4-Lite-only crossbar rather than adding burst
      support project-wide
- [x] `dma_engine` — AXI4-Lite control port (crossbar's 9th slave) + AXI4
      burst master streaming multi-block messages straight through
      `aes_chain` to a private `dma_ram`, zero CPU involvement per block;
      verified end-to-end (CBC encrypt, CTR, CBC decrypt, 4 blocks each)
      against NIST vectors — 15/15 checks green
- [x] `soc_top` wired (DMA control port reachable via the real crossbar);
      full regression unchanged
- [x] Found and fixed two real RTL bugs during bring-up (same "combinational
      logic reads a register that hasn't updated yet this edge" class as a
      SPI/register-offset bug from Phase 3) plus one test-harness bug — see
      `docs/specs/dma.md` and `docs/project_retrospective.md` for the full
      root-cause writeups

**Phase 7 (documentation & sign-off) — done:**
- [x] `docs/architecture.md`, `docs/memory_map.md`,
      `docs/verification_summary.md`, `docs/performance.md`
- [x] Whole-SoC Yosys synthesis + OpenSTA timing (Nangate45; the three
      plain memory arrays blackboxed as SRAM macros, everything else —
      PicoRV32, the crossbar, every peripheral, AES, DMA — synthesized for
      real): **Fmax ≈ 91.2 MHz**, critical path in AES key expansion,
      consistent with the standalone `aes_core` result from Phase 4
- [x] Measured (not estimated) performance data: AES throughput ≈ 69.5 MB/s,
      DMA throughput ≈ 37.4 MB/s (39 cycles/block average), interrupt
      latency 3-14 cycles (avg 8.6) measured directly from a VCD trace
- [x] `scripts/run_regression.sh` — rebuilds and runs all 18 block
      testbenches in one pass; running it caught a real latent bug (a
      watchdog testbench constant that had drifted from the RTL's actual
      default and gone unnoticed because a stale binary kept looking green)
- [x] `docs/project_retrospective.md` — phase-by-phase account of every
      real bug found across the whole project, root cause and fix,
      including two error patterns that each recurred independently in
      more than one phase

**All phases (0-7) complete.** See `docs/phase_plan.md` for the original
plan and `docs/project_retrospective.md` for the full bug/debugging history.

## Running things

The easiest way to check everything at once:

```bash
./scripts/run_regression.sh
```

This rebuilds and runs all 18 block testbenches fresh (no incremental-build
assumptions) and prints a PASS/FAIL summary table — the same script used to
sign off Phase 7 (see `docs/verification_summary.md`).

There's also a dedicated, independent lint-only pass per block (separate
from whatever warnings a given simulation build happens to suppress):

```bash
./scripts/run_lint.sh
```

Each block's report lands in `blocks/<name>/lint/lint_report.txt`. This is
what caught a handful of genuine dead code across the project (an unused
register in the JTAG bridge, an unused FSM state in `aes_chain`, etc.) —
see `docs/project_retrospective.md`'s "Phase 7 後續補強" section for the
full story on why a dedicated lint pass turned out to be worth adding after
all, and what it found.

To collect a full whole-SoC sign-off snapshot (simulation regression +
lint + synthesis + STA) into one place:

```bash
./scripts/collect_soc_reports.sh
```

This writes into `reports/soc_top/` — unlike the per-block `syn`/`sta`/`lint`
scratch output (gitignored, regenerable), `reports/` **is** committed: it's
the sign-off snapshot, readable straight from the repo without needing the
toolchain installed.

There's no flow-automation skill wired up yet for synth/STA (the generic
`IC_fe_flow` skill was retired — a project-specific one will replace it once
the architecture has settled). For now those are run directly, e.g.:

```bash
# full-SoC smoke test (rebuilds + runs; firmware.hex must already be built)
cd blocks/soc_top/sim
verilator -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-PINCONNECTEMPTY \
  --cc --exe --build --trace --top-module soc_top \
  -I../../../rtl/include -I../rtl \
  ../rtl/picorv32.v ../rtl/axi_lite_xbar.v ../rtl/boot_rom.v ../rtl/sram.v \
  ../rtl/timer.v ../rtl/watchdog.v ../rtl/uart.v ../rtl/i2c_master.v ../rtl/spi_master.v \
  ../rtl/aes_key_expand.v ../rtl/aes_core.v ../rtl/aes_chain.v ../rtl/aes.v \
  ../rtl/dma_ram.v ../rtl/dma_engine.v \
  ../rtl/jtag_tap.v ../rtl/jtag_dtm.v ../rtl/jtag_axi_bridge.v \
  ../rtl/soc_top.v sim_main.cpp -o soc_sim --Mdir obj_dir
./obj_dir/soc_sim

# whole-SoC synthesis + STA (Nangate45; memories blackboxed, see
# docs/performance.md for why)
cd blocks/soc_top/syn && yosys synth.ys
cd ../sta && sta sta.tcl

# rebuild firmware after editing fw/main.c or fw/start.S
cd fw && make && cp firmware.hex ../blocks/soc_top/sim/firmware.hex
```

The `-Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED` flags silence lint
warnings that come from PicoRV32's own (unmodified, vendored) coding
style, not from this project's RTL.

## Layout

Each block under `blocks/` has its own `rtl/lint/sim`. Only `aes` and
`soc_top` also have `sdc/syn/sta` — every other block is small enough that
a standalone synthesis/STA run wasn't worth doing on its own; their real
timing signoff happens once, for real, as part of the whole-SoC synthesis
(see `blocks/soc_top/syn/synth.ys` and `blocks/soc_top/sta/sta.tcl`, or
`blocks/aes/syn/synth.ys` / `blocks/aes/sta/sta.tcl` for the standalone AES
core numbers cited in `docs/aes_report.md`). Empty, never-used `sdc/syn/sta`
scaffold directories for the other blocks (plus a fully-empty leftover
`blocks/jtag_tap/` from before `blocks/jtag/` existed) were removed —
`git status` showed no change from deleting them, confirming git never
tracked empty directories in the first place.
`soc_top`'s `rtl/` is a set of symlinks into every other block's canonical
source, so there's exactly one copy of each module. See
`docs/phase_plan.md` for the full rationale.

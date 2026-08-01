# Vendored source: PicoRV32

- Upstream: https://github.com/YosysHQ/picorv32.git
- Vendored commit: a473fc8fca393771d83b0ffcf0b14db3393339d8
- Upstream commit date: 2026-07-31
- Files: `picorv32.v` (unmodified), `COPYING` (ISC license)
- Variant used in this project: `picorv32_axi` (AXI4-Lite master), instantiated from `picorv32.v`
- Verified on this machine: built and ran PicoRV32's own `test_verilator` target
  (Verilator + xPack riscv-none-elf-gcc 15.2.0) — all self-checks passed
  (CPI 4.81, multiply/divide hard/soft cross-check, IRQ counters all nonzero).

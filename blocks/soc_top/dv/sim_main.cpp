// Full-SoC smoke test. Phase 1 proved the CPU/crossbar/ROM/UART path by
// printing "Hello World". Phase 2 extends the same firmware to configure
// the Timer for periodic interrupts, count them in a real ISR (through
// PicoRV32's non-standard getq/setq/retirq mechanism), kick the Watchdog
// from that ISR, and report the interrupt count over UART — so this test
// now also proves interrupts actually fired, not just that the program
// ran. Decoded bit-by-bit off the UART TX line (not an internal probe),
// exactly like a real serial terminal would see it. Self-checking: exits
// 0 only on an exact string match.
#include "Vsoc_top.h"
#include "verilated.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif
#include "verilated_vcd_c.h"
#include <cstdio>
#include <string>

static const int CLKS_PER_BIT = 4; // must match uart.v's default parameter

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  ctx->traceEverOn(true);
  Vsoc_top* dut = new Vsoc_top{ctx};

  VerilatedVcdC* tfp = new VerilatedVcdC;
  dut->trace(tfp, 99);
  tfp->open("wave.vcd");

  dut->clk = 0;
  vluint64_t sim_time = 0;
  auto clock = [&]() {
    dut->clk = !dut->clk;
    dut->eval();
    tfp->dump(sim_time);
    sim_time += 5;
    dut->clk = !dut->clk;
    dut->eval();
    tfp->dump(sim_time);
    sim_time += 5;
  };

  dut->tck = 0; dut->tms = 1; dut->tdi = 0; // hold the JTAG TAP in Test-Logic-Reset while idle

  dut->rst = 1;
  for (int i = 0; i < 4; i++) clock();
  dut->rst = 0;

  const std::string expected = "Hello World\nTimer IRQs: 5\n";
  std::string got;
  const long GLOBAL_TIMEOUT_CYCLES = 2000000;
  long cycles = 0;
  bool timed_out = false;

  while (got.size() < expected.size()) {
    // wait for the start bit (tx idle-high -> low), bailing out if the
    // whole run takes unreasonably long (firmware/RTL bug, not a slow-but-
    // working system).
    while (dut->uart_tx) {
      clock();
      cycles++;
      if (cycles > GLOBAL_TIMEOUT_CYCLES) { timed_out = true; break; }
    }
    if (timed_out) break;

    for (int j = 0; j < CLKS_PER_BIT / 2; j++) { clock(); cycles++; }
    uint8_t byte = 0;
    for (int b = 0; b < 8; b++) {
      for (int j = 0; j < CLKS_PER_BIT; j++) { clock(); cycles++; }
      if (dut->uart_tx) byte |= (1 << b);
    }
    // stop bit
    for (int j = 0; j < CLKS_PER_BIT; j++) { clock(); cycles++; }

    got.push_back((char)byte);
  }

  printf("cycles=%ld received=\"", cycles);
  for (char c : got) {
    if (c == '\n') printf("\\n");
    else putchar(c);
  }
  printf("\"\n");

  if (timed_out) {
    printf("FAIL: timed out after %ld cycles waiting for UART output\n", cycles);
    return 1;
  }
  if (got != expected) {
    printf("FAIL: got %zu byte(s), expected %zu bytes\n", got.size(), expected.size());
    return 1;
  }

  // ---- Phase 5: JTAG debug bridge, exercised through the REAL soc_top
  // (crossbar arbitration + sram.v), not a standalone bench -- write then
  // read back a scratch RAM word to prove the whole JTAG->bridge->
  // crossbar->SRAM path works end-to-end. Runs after the CPU regression
  // above completes, since only the JTAG side is driving the bus now.
  int jtag_fail = 0;
  auto jtag_check = [&](const char* what, bool cond) {
    if (!cond) { printf("FAIL: %s\n", what); jtag_fail++; }
  };

  auto tap_edge = [&](int tms, int tdi) -> int {
    dut->tms = tms; dut->tdi = tdi;
    dut->eval();
    int tdo = dut->tdo;
    dut->tck = 1; dut->eval();
    for (int i = 0; i < 5; i++) clock();
    dut->tck = 0; dut->eval();
    for (int i = 0; i < 5; i++) clock();
    return tdo;
  };
  auto ir_scan = [&](uint8_t val) {
    tap_edge(1, 0); tap_edge(1, 0); tap_edge(0, 0); tap_edge(0, 0);
    for (int i = 0; i < 4; i++) tap_edge(i == 3 ? 1 : 0, (val >> i) & 1);
    tap_edge(1, 0); tap_edge(0, 0);
  };
  auto dr_scan32 = [&](uint32_t val_in) -> uint32_t {
    tap_edge(1, 0); tap_edge(0, 0); tap_edge(0, 0);
    uint32_t out = 0;
    for (int i = 0; i < 32; i++) {
      int tdo = tap_edge(i == 31 ? 1 : 0, (val_in >> i) & 1);
      out |= (uint32_t(tdo & 1) << i);
    }
    tap_edge(1, 0); tap_edge(0, 0);
    return out;
  };
  const uint8_t IR_AXI_ADDR = 0x2, IR_AXI_DATA = 0x3, IR_AXI_CTRL = 0x4;

  tap_edge(0, 0); // TEST_LOGIC_RESET -> RUN_TEST_IDLE

  const uint32_t SCRATCH_ADDR = 0x10008000; // well clear of this tiny firmware's footprint
  const uint32_t SCRATCH_VAL  = 0x600DF00D;

  ir_scan(IR_AXI_ADDR); dr_scan32(SCRATCH_ADDR);
  ir_scan(IR_AXI_DATA); dr_scan32(SCRATCH_VAL);
  ir_scan(IR_AXI_CTRL); dr_scan32(0x1); // rw=0 (write), start=1
  uint32_t status; int spins = 0;
  do { status = dr_scan32(0); spins++; } while ((status & 0x1) && spins < 100);
  jtag_check("JTAG write to RAM: bridge completed", spins < 100);
  jtag_check("JTAG write to RAM: OKAY response", (status & 0x2) != 0);

  ir_scan(IR_AXI_ADDR); dr_scan32(SCRATCH_ADDR);
  ir_scan(IR_AXI_CTRL); dr_scan32(0x3); // rw=1 (read), start=1
  spins = 0;
  do { status = dr_scan32(0); spins++; } while ((status & 0x1) && spins < 100);
  jtag_check("JTAG read from RAM: bridge completed", spins < 100);
  ir_scan(IR_AXI_DATA);
  uint32_t rd_val = dr_scan32(0);
  jtag_check("JTAG read-back matches JTAG-written value (through the real crossbar+SRAM)",
             rd_val == SCRATCH_VAL);

  // ---- Phase 6: confirm the DMA engine's AXI4-Lite control port is
  // correctly address-decoded and routed as the crossbar's 9th slave
  // (0x4000_6000). This only proves the *wiring* (address decode +
  // crossbar routing) is correct -- the DMA engine's actual multi-block
  // AES streaming logic is already exhaustively verified against NIST
  // SP 800-38A vectors at the block level (blocks/dma/sim/
  // dma_engine_sim_main.cpp, 15/15 checks), and re-proving that here
  // would be redundant; dma_ram is deliberately not reachable from the
  // crossbar at all (see dma_ram.v's header), so a real end-to-end DMA
  // operation can only be driven/observed at the block level anyway.
  const uint32_t DMA_SRC_ADDR_REG = 0x40006008;
  const uint32_t DMA_TEST_VAL     = 0xCAFEF00D;

  ir_scan(IR_AXI_ADDR); dr_scan32(DMA_SRC_ADDR_REG);
  ir_scan(IR_AXI_DATA); dr_scan32(DMA_TEST_VAL);
  ir_scan(IR_AXI_CTRL); dr_scan32(0x1); // rw=0 (write), start=1
  spins = 0;
  do { status = dr_scan32(0); spins++; } while ((status & 0x1) && spins < 100);
  jtag_check("JTAG write to DMA SRC_ADDR reg: bridge completed", spins < 100);
  jtag_check("JTAG write to DMA SRC_ADDR reg: OKAY response", (status & 0x2) != 0);

  ir_scan(IR_AXI_ADDR); dr_scan32(DMA_SRC_ADDR_REG);
  ir_scan(IR_AXI_CTRL); dr_scan32(0x3); // rw=1 (read), start=1
  spins = 0;
  do { status = dr_scan32(0); spins++; } while ((status & 0x1) && spins < 100);
  jtag_check("JTAG read from DMA SRC_ADDR reg: bridge completed", spins < 100);
  ir_scan(IR_AXI_DATA);
  rd_val = dr_scan32(0);
  jtag_check("JTAG read-back matches JTAG-written DMA SRC_ADDR value "
             "(crossbar's 9th slave correctly address-decoded)",
             rd_val == DMA_TEST_VAL);

  tfp->close();
#if VM_COVERAGE
  VerilatedCov::write("coverage.dat");
#endif
  delete dut;
  delete ctx;

  if (jtag_fail) {
    printf("FAIL: %d JTAG check(s) failed\n", jtag_fail);
    return 1;
  }

  printf("PASS: soc_top booted firmware, printed \"Hello World\", ran 5 real "
         "Timer interrupts through PicoRV32's getq/setq/retirq ISR path "
         "(kicking the Watchdog each time), and reported the count over "
         "UART — all through real AXI4-Lite transactions; the JTAG debug "
         "bridge also wrote and read back a RAM word through the real "
         "2-master crossbar, and reached the DMA engine's control port as "
         "the crossbar's 9th slave (Phase 6)\n");
  return 0;
}

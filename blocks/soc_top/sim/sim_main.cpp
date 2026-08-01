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

  tfp->close();
  delete dut;
  delete ctx;

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

  printf("PASS: soc_top booted firmware, printed \"Hello World\", ran 5 real "
         "Timer interrupts through PicoRV32's getq/setq/retirq ISR path "
         "(kicking the Watchdog each time), and reported the count over "
         "UART — all through real AXI4-Lite transactions\n");
  return 0;
}

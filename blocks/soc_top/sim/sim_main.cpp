// Full-SoC smoke test — Phase 1 exit criterion: the real compiled firmware
// (fw/main.c) runs on picorv32_axi through the hand-written crossbar,
// reaches boot_rom via a real AXI transaction on every fetch, and prints
// "Hello World\n" out the UART TX line, decoded here bit-by-bit (not
// trusted via any internal probe) exactly like a real serial terminal
// would see it. Self-checking: exits 0 only on an exact string match.
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

  const std::string expected = "Hello World\n";
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
    printf("FAIL: got %zu byte(s), expected \"Hello World\\n\" (%zu bytes)\n",
           got.size(), expected.size());
    return 1;
  }

  printf("PASS: soc_top booted firmware and printed \"Hello World\" over UART "
         "(CPU -> crossbar -> boot_rom fetch, -> uart TX, all through real "
         "AXI4-Lite transactions)\n");
  return 0;
}

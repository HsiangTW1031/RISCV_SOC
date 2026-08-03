// Validates boot_rom.v: $readmemh load, read correctness, and that writes
// are rejected (SLVERR) without altering memory.
#include "Vboot_rom.h"
#include "verilated.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif
#include "axi_lite_bfm.h"
#include <cstdio>

static const uint8_t RESP_OKAY   = 0x0;
static const uint8_t RESP_SLVERR = 0x2;

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vboot_rom* dut = new Vboot_rom{ctx};

  AxiLiteSignals sig;
  sig.awvalid = &dut->s_awvalid; sig.awready = &dut->s_awready; sig.awaddr = &dut->s_awaddr;
  sig.wvalid  = &dut->s_wvalid;  sig.wready  = &dut->s_wready;  sig.wdata  = &dut->s_wdata;  sig.wstrb = &dut->s_wstrb;
  sig.bvalid  = &dut->s_bvalid;  sig.bready  = &dut->s_bready;  sig.bresp  = &dut->s_bresp;
  sig.arvalid = &dut->s_arvalid; sig.arready = &dut->s_arready; sig.araddr = &dut->s_araddr;
  sig.rvalid  = &dut->s_rvalid;  sig.rready  = &dut->s_rready;  sig.rdata  = &dut->s_rdata;  sig.rresp = &dut->s_rresp;

  dut->clk = 0;
  auto tick_half = [&]() { dut->clk = !dut->clk; dut->eval(); };
  AxiLiteBfm bfm(sig, tick_half);

  dut->resetn = 0;
  bfm.clock(); bfm.clock();
  dut->resetn = 1;
  bfm.clock();

  int fail_count = 0;
  auto check = [&](const char* what, bool cond) {
    if (!cond) { printf("FAIL: %s\n", what); fail_count++; }
  };

  uint32_t rd; uint8_t resp; bool ok;

  static const uint32_t expected[4] = {0xAAAA0001, 0xBBBB0002, 0xCCCC0003, 0xDDDD0004};
  for (int i = 0; i < 4; i++) {
    ok = bfm.read(i * 4, &rd, &resp);
    char msg[64];
    snprintf(msg, sizeof(msg), "read word %d", i);
    check(msg, ok && rd == expected[i] && resp == RESP_OKAY);
  }

  // write attempt must be rejected and must not alter memory.
  ok = bfm.write(0x00000000, 0xFFFFFFFF, 0xF, &resp);
  check("write to ROM completes (self-answers)", ok);
  check("write to ROM resp SLVERR", resp == RESP_SLVERR);

  ok = bfm.read(0x00000000, &rd, &resp);
  check("ROM word 0 unchanged after write attempt", ok && rd == 0xAAAA0001);

#if VM_COVERAGE
  VerilatedCov::write("coverage.dat");
#endif
  delete dut;
  delete ctx;

  if (fail_count) { printf("FAIL: %d check(s) failed\n", fail_count); return 1; }
  printf("PASS: boot_rom (load + read + write-rejected) all green\n");
  return 0;
}

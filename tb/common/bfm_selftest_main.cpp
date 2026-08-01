// Validates axi_lite_bfm.h against fake_axi_lite_slave.v BEFORE the BFM is
// ever pointed at real DUT logic (crossbar, peripherals, ...). If this
// fails, the bug is in the BFM, not in a block under test.
#include "Vfake_axi_lite_slave.h"
#include "verilated.h"
#include "axi_lite_bfm.h"
#include <cstdio>

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vfake_axi_lite_slave* dut = new Vfake_axi_lite_slave{ctx};

  AxiLiteSignals sig;
  sig.awvalid = &dut->s_awvalid; sig.awready = &dut->s_awready; sig.awaddr = &dut->s_awaddr;
  sig.wvalid  = &dut->s_wvalid;  sig.wready  = &dut->s_wready;  sig.wdata  = &dut->s_wdata;  sig.wstrb = &dut->s_wstrb;
  sig.bvalid  = &dut->s_bvalid;  sig.bready  = &dut->s_bready;  sig.bresp  = &dut->s_bresp;
  sig.arvalid = &dut->s_arvalid; sig.arready = &dut->s_arready; sig.araddr = &dut->s_araddr;
  sig.rvalid  = &dut->s_rvalid;  sig.rready  = &dut->s_rready;  sig.rdata  = &dut->s_rdata;  sig.rresp = &dut->s_rresp;

  dut->clk = 0;
  auto tick_half = [&]() {
    dut->clk = !dut->clk;
    dut->eval();
  };

  AxiLiteBfm bfm(sig, tick_half);

  dut->rst = 1;
  bfm.clock();
  bfm.clock();
  dut->rst = 0;
  bfm.clock();

  int fail_count = 0;

  // 1. write then read back the same word.
  uint8_t resp = 0xFF;
  bool ok = bfm.write(0x00, 0xDEADBEEF, 0xF, &resp);
  if (!ok || resp != 0x00) { printf("FAIL: write#1 ok=%d resp=%02x\n", ok, resp); fail_count++; }

  uint32_t rd = 0xFFFFFFFF;
  ok = bfm.read(0x00, &rd, &resp);
  if (!ok || rd != 0xDEADBEEF || resp != 0x00) {
    printf("FAIL: read#1 ok=%d data=%08x resp=%02x\n", ok, rd, resp);
    fail_count++;
  }

  // 2. distinct addresses don't alias.
  bfm.write(0x04, 0x12345678, 0xF, &resp);
  bfm.write(0x08, 0x0000CAFE, 0xF, &resp);
  bfm.read(0x04, &rd, &resp);
  if (rd != 0x12345678) { printf("FAIL: addr 0x04 got %08x\n", rd); fail_count++; }
  bfm.read(0x08, &rd, &resp);
  if (rd != 0x0000CAFE) { printf("FAIL: addr 0x08 got %08x\n", rd); fail_count++; }
  bfm.read(0x00, &rd, &resp);
  if (rd != 0xDEADBEEF) { printf("FAIL: addr 0x00 clobbered, got %08x\n", rd); fail_count++; }

  // 3. back-to-back writes without idle cycles between them.
  for (int i = 0; i < 8; i++) {
    ok = bfm.write(i * 4, 0x1000 + i, 0xF, &resp);
    if (!ok) { printf("FAIL: burst write #%d timed out\n", i); fail_count++; }
  }
  for (int i = 0; i < 8; i++) {
    ok = bfm.read(i * 4, &rd, &resp);
    if (!ok || rd != (uint32_t)(0x1000 + i)) {
      printf("FAIL: burst read #%d got %08x want %08x\n", i, rd, 0x1000 + i);
      fail_count++;
    }
  }

  delete dut;
  delete ctx;

  if (fail_count) {
    printf("FAIL: %d check(s) failed\n", fail_count);
    return 1;
  }
  printf("PASS: axi_lite_bfm self-test (write/read, no-aliasing, back-to-back) all green\n");
  return 0;
}

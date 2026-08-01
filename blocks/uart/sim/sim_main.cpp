// Validates uart.v (TX-only, Phase 1 scope): decodes the actual serial line
// (start bit, 8 data bits LSB-first, stop bit) rather than trusting
// STATUS alone, checks busy behavior, and confirms a write-while-busy is
// dropped (no FIFO yet — documented behavior, not a bug).
#include "Vuart.h"
#include "verilated.h"
#include "axi_lite_bfm.h"
#include <cstdio>

static const uint8_t RESP_OKAY    = 0x0;
static const int     CLKS_PER_BIT = 4; // must match uart.v's default parameter

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vuart* dut = new Vuart{ctx};

  AxiLiteSignals sig;
  sig.awvalid = &dut->s_awvalid; sig.awready = &dut->s_awready; sig.awaddr = &dut->s_awaddr;
  sig.wvalid  = &dut->s_wvalid;  sig.wready  = &dut->s_wready;  sig.wdata  = &dut->s_wdata;  sig.wstrb = &dut->s_wstrb;
  sig.bvalid  = &dut->s_bvalid;  sig.bready  = &dut->s_bready;  sig.bresp  = &dut->s_bresp;
  sig.arvalid = &dut->s_arvalid; sig.arready = &dut->s_arready; sig.araddr = &dut->s_araddr;
  sig.rvalid  = &dut->s_rvalid;  sig.rready  = &dut->s_rready;  sig.rdata  = &dut->s_rdata;  sig.rresp = &dut->s_rresp;

  dut->clk = 0;
  auto tick_half = [&]() { dut->clk = !dut->clk; dut->eval(); };
  AxiLiteBfm bfm(sig, tick_half);

  dut->rst = 1;
  bfm.clock(); bfm.clock();
  dut->rst = 0;
  bfm.clock();

  int fail_count = 0;
  auto check = [&](const char* what, bool cond) {
    if (!cond) { printf("FAIL: %s\n", what); fail_count++; }
  };

  auto read_busy = [&]() -> bool {
    uint32_t rd; uint8_t resp;
    bfm.read(0x4, &rd, &resp);
    return rd & 0x1;
  };

  // Waits for the start bit (tx idle-high -> low), advances to the middle
  // of each bit period, samples data bits LSB-first, and checks the stop
  // bit. Returns the decoded byte; sets *stop_ok to whether tx was high
  // (correct) during the stop bit.
  auto capture_byte = [&](bool* stop_ok, int timeout = 200) -> uint8_t {
    int i = 0;
    for (; i < timeout && dut->tx; i++) bfm.clock();
    for (int j = 0; j < CLKS_PER_BIT / 2; j++) bfm.clock(); // -> mid of start bit
    uint8_t byte = 0;
    for (int b = 0; b < 8; b++) {
      for (int j = 0; j < CLKS_PER_BIT; j++) bfm.clock();
      if (dut->tx) byte |= (1 << b);
    }
    for (int j = 0; j < CLKS_PER_BIT; j++) bfm.clock(); // -> mid of stop bit
    *stop_ok = dut->tx;
    return byte;
  };

  uint8_t resp; bool ok, stop_ok;

  // ---- 1. basic byte, decode the wire, check STATUS around it ----
  check("idle: not busy before any write", !read_busy());
  ok = bfm.write(0x0, 0x41 /* 'A' */, 0xF, &resp); // TXDATA
  check("write TXDATA ok", ok && resp == RESP_OKAY);
  // do_start_tx is a registered pulse, so TX_IDLE->TX_START (and therefore
  // the busy flag) becomes visible a couple of cycles after the write
  // completes, not on the very same cycle — give it that settling time
  // before sampling STATUS.
  bfm.clock(); bfm.clock();
  check("busy shortly after write", read_busy());

  uint8_t got = capture_byte(&stop_ok);
  check("decoded byte == 0x41", got == 0x41);
  check("stop bit high", stop_ok);

  for (int i = 0; i < 3; i++) bfm.clock(); // let busy settle back to idle
  check("not busy after frame completes", !read_busy());

  // ---- 2. a different byte, to rule out a stuck/always-matching decoder ----
  bfm.write(0x0, 0xA5, 0xF, &resp);
  got = capture_byte(&stop_ok);
  check("decoded byte == 0xA5", got == 0xA5);
  check("stop bit high (2nd byte)", stop_ok);

  // ---- 3. write-while-busy is dropped, not queued ----
  for (int i = 0; i < 3; i++) bfm.clock();
  check("idle before test 3", !read_busy());
  bfm.write(0x0, 0x11, 0xF, &resp);          // starts transmitting 0x11
  bfm.write(0x0, 0x22, 0xF, &resp);          // should be ignored: busy
  got = capture_byte(&stop_ok);
  check("first write wins while busy (got 0x11)", got == 0x11);
  for (int i = 0; i < 3; i++) bfm.clock();
  check("no second frame queued after the dropped write", !read_busy());

  delete dut;
  delete ctx;

  if (fail_count) { printf("FAIL: %d check(s) failed\n", fail_count); return 1; }
  printf("PASS: uart TX (frame decode, busy behavior, write-while-busy dropped) all green\n");
  return 0;
}

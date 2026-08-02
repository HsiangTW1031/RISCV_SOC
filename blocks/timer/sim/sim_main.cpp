// Cycle-accurate directed test for timer.v. Every AXI-Lite transaction in
// this design (always-ready slave, single-cycle turnaround) takes exactly
// one full clock() call, and the timer's internal counter advances on
// every clock edge regardless of whether that edge happens to carry an AXI
// transaction — so a small software model of "one RTL cycle" is kept here
// and advanced after every single BFM call, then checked against readback.
#include "Vtimer.h"
#include "verilated.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif
#include "axi_lite_bfm.h"
#include <cstdio>

static const uint8_t  RESP_OKAY = 0x0;
static const uint32_t RELOAD    = 5;

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vtimer* dut = new Vtimer{ctx};

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

  // ---- software model of the RTL, advanced once per BFM call ----
  bool     model_en = false;
  uint32_t model_count = 0xFFFFFFFF;
  bool     model_expired = false;
  bool     model_write_ctrl_en_this_cycle = false; // set just before the call that issues it

  auto advance_model = [&]() {
    if (model_write_ctrl_en_this_cycle) {
      model_count = RELOAD;
      // expiry check is suppressed this cycle by the same-cycle enabling write
    } else if (model_en && model_count == 0) {
      model_count = RELOAD;
      model_expired = true;
    } else if (model_en) {
      model_count -= 1;
    }
    model_write_ctrl_en_this_cycle = false;
  };

  uint32_t rd; uint8_t resp; bool ok;

  // ---- register read/write basics ----
  ok = bfm.write(0x4, RELOAD, 0xF, &resp); advance_model(); // REG_RELOAD
  check("write RELOAD ok", ok && resp == RESP_OKAY);

  ok = bfm.read(0x4, &rd, &resp); advance_model();
  check("read RELOAD back", ok && rd == RELOAD);

  // ---- enabling write: reloads COUNT immediately, per design ----
  model_en = true;
  model_write_ctrl_en_this_cycle = true;
  ok = bfm.write(0x0, 0x1, 0xF, &resp); advance_model(); // REG_CTRL, EN=1
  check("write CTRL EN=1 ok", ok && resp == RESP_OKAY);
  check("model sanity: count reloaded to RELOAD", model_count == RELOAD);

  // ---- walk the full down-count + wraparound twice, checking every cycle ----
  // NB: a synchronous read always returns the register's value as of the
  // *start* of that cycle (nonblocking-assignment semantics: `s_rdata <=
  // count` and `count <= count - 1` both read the pre-edge `count` on the
  // same edge) — so we snapshot the expected value BEFORE advancing the
  // model, not after.
  for (int cycle = 0; cycle < 2 * (RELOAD + 1); cycle++) {
    uint32_t expected = model_count;
    ok = bfm.read(0x8, &rd, &resp); // REG_COUNT
    advance_model();
    char msg[64];
    snprintf(msg, sizeof(msg), "COUNT at check #%d", cycle);
    check(msg, ok && rd == expected);
  }
  check("EXPIRED got set at least once by the wraparound walk", model_expired);

  // ---- STATUS reflects the sticky expired bit, and write-1 clears it ----
  {
    bool expected_expired = model_expired;
    ok = bfm.read(0xC, &rd, &resp); advance_model();
    check("STATUS.EXPIRED reads back set", ok && (rd & 1) == (expected_expired ? 1u : 0u));
  }

  ok = bfm.write(0xC, 0x1, 0xF, &resp); advance_model(); // write-1-to-clear
  model_expired = false;
  check("write STATUS=1 (clear) ok", ok && resp == RESP_OKAY);

  {
    bool expected_expired = model_expired;
    ok = bfm.read(0xC, &rd, &resp); advance_model();
    check("STATUS.EXPIRED cleared", ok && (rd & 1) == (expected_expired ? 1u : 0u));
  }

  // clearing STATUS must not have disturbed the still-running countdown.
  {
    uint32_t expected = model_count;
    ok = bfm.read(0x8, &rd, &resp); advance_model();
    check("COUNT kept counting through the STATUS clear, unaffected", ok && rd == expected);
  }

  // ---- CTRL EN=0 stops the countdown (count holds from the NEXT cycle) ----
  // The disabling write's own cycle still sees the pre-edge ctrl_en=1 in
  // the countdown logic (same nonblocking-assignment timing as above), so
  // count decrements one final time before actually holding.
  ok = bfm.write(0x0, 0x0, 0xF, &resp); advance_model(); // EN=0
  model_en = false;
  check("write CTRL EN=0 ok", ok && resp == RESP_OKAY);

  uint32_t held_count = model_count;
  for (int i = 0; i < 3; i++) {
    uint32_t expected = model_count;
    ok = bfm.read(0x8, &rd, &resp); advance_model();
    check("COUNT holds while disabled", ok && rd == expected && expected == held_count);
  }

#if VM_COVERAGE
  VerilatedCov::write("coverage.dat");
#endif
  delete dut;
  delete ctx;

  if (fail_count) { printf("FAIL: %d check(s) failed\n", fail_count); return 1; }
  printf("PASS: timer (cycle-accurate down-count, auto-reload, sticky EXPIRED, EN stop/hold) all green\n");
  return 0;
}

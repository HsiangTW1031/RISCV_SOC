// Cycle-accurate directed test for watchdog.v — the Phase 2 exit
// criterion is that the reset-request timing is verified cycle by cycle,
// not just "eventually fires". Same snapshot-before-advance methodology
// as timer's test: a synchronous read (or any same-cycle condition check)
// always reflects the register's value as of the START of that cycle, so
// the model's expected value must be captured before advancing it.
#include "Vwatchdog.h"
#include "verilated.h"
#include "axi_lite_bfm.h"
#include <cstdio>

static const uint8_t  RESP_OKAY    = 0x0;
static const uint32_t TIMEOUT      = 6;
static const uint32_t WARN_MARGIN  = 3; // must match watchdog.v's default parameter

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vwatchdog* dut = new Vwatchdog{ctx};

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

  // ---- software model, advanced once per BFM call ----
  bool     model_en = false;
  uint32_t model_count = 0xFFFFFFFF;
  bool     model_warning = false;      // sticky STATUS.WARNING
  bool     model_reset_req = false;
  bool     model_irq_pulse = false;    // one-cycle `irq` pulse (this edge only)
  bool     model_restart_this_cycle = false;   // write_ctrl_en || write_kick
  bool     model_status_clear_this_cycle = false;

  auto advance_model = [&]() {
    uint32_t old_count = model_count;
    bool     old_en = model_en;
    bool     restart_now = model_restart_this_cycle;

    // irq is a single-cycle pulse — mirrors watchdog.v's
    // `irq_pulse <= (!restart && ctrl_en && count == WARN_MARGIN)` exactly,
    // using this same cycle's pre-edge count/en and restart signal.
    model_irq_pulse = (!restart_now) && old_en && (old_count == WARN_MARGIN);

    if (restart_now) {
      model_count   = TIMEOUT;
      model_warning = false;
      model_reset_req = false;
    } else {
      if (old_en && old_count != 0) model_count = old_count - 1;
      // else: holds (disabled, or already at 0)

      if (old_en && old_count == WARN_MARGIN) model_warning = true;
      else if (model_status_clear_this_cycle) model_warning = false;

      if (old_en && old_count == 0) model_reset_req = true;
    }
    model_restart_this_cycle = false;
    model_status_clear_this_cycle = false;
  };

  uint32_t rd; uint8_t resp; bool ok;

  // ---- basic register write/read ----
  ok = bfm.write(0x4, TIMEOUT, 0xF, &resp); advance_model(); // REG_TIMEOUT
  check("write TIMEOUT ok", ok && resp == RESP_OKAY);
  ok = bfm.read(0x4, &rd, &resp); advance_model();
  check("read TIMEOUT back", ok && rd == TIMEOUT);

  // ---- start: enabling write reloads count to TIMEOUT ----
  model_restart_this_cycle = true;
  ok = bfm.write(0x0, 0x1, 0xF, &resp); advance_model(); // REG_CTRL EN=1
  model_en = true;
  check("write CTRL EN=1 ok", ok && resp == RESP_OKAY);

  // ---- walk the countdown, checking WARNING and RESET_REQ timing exactly ----
  // Both flags are the RESULT of a cycle whose PRE-edge count matched the
  // trigger condition — so we watch for the false->true transition (the
  // model's *post*-advance value) and attribute it to the count that was
  // current going INTO that same cycle (captured before advance_model()).
  bool saw_warning_exactly_at_margin = false;
  bool saw_reset_req_exactly_at_zero = false;
  bool prev_warning = model_warning;
  bool prev_reset_req = model_reset_req;

  for (int cycle = 0; cycle < (int)TIMEOUT + 2; cycle++) {
    uint32_t pre_edge_count = model_count;

    // REG_KICK reads back as 0 always — this call is purely a one-cycle
    // "tick", not a count readback (watchdog.v has no COUNT register).
    ok = bfm.read(0x8, &rd, &resp);
    advance_model();

    if (model_warning && !prev_warning) {
      check("WARNING turned on exactly when pre-cycle count==WARN_MARGIN",
            pre_edge_count == WARN_MARGIN);
      saw_warning_exactly_at_margin = true;
    }
    if (model_reset_req && !prev_reset_req) {
      check("RESET_REQ turned on exactly when pre-cycle count==0",
            pre_edge_count == 0);
      saw_reset_req_exactly_at_zero = true;
    }
    {
      char m1[96], m2[96];
      snprintf(m1, sizeof(m1), "cycle %d: wdog_reset_req pin matches model (pre_count=%u)", cycle, pre_edge_count);
      snprintf(m2, sizeof(m2), "cycle %d: irq pulse matches model (pre_count=%u, model_irq_pulse=%d, irq=%d)",
               cycle, pre_edge_count, model_irq_pulse, (int)dut->irq);
      check(m1, dut->wdog_reset_req == (model_reset_req ? 1 : 0));
      check(m2, (bool)dut->irq == model_irq_pulse);
    }

    prev_warning = model_warning;
    prev_reset_req = model_reset_req;
  }

  check("WARNING was observed set exactly when count==WARN_MARGIN", saw_warning_exactly_at_margin);
  check("RESET_REQ was observed set exactly when count==0", saw_reset_req_exactly_at_zero);

  {
    uint32_t expected_status = (model_reset_req ? 2u : 0u) | (model_warning ? 1u : 0u);
    ok = bfm.read(0xC, &rd, &resp); advance_model();
    check("STATUS bits match model after countdown", ok && rd == expected_status);
  }
  check("irq pulse has already ended by now (it's 1-cycle wide, not sticky)", (bool)dut->irq == false);
  check("wdog_reset_req pin reflects RESET_REQ after full timeout", (bool)dut->wdog_reset_req == model_reset_req);

  // ---- STATUS write-1 clears WARNING but NOT RESET_REQ ----
  model_status_clear_this_cycle = true;
  ok = bfm.write(0xC, 0x1, 0xF, &resp); advance_model(); // write-1 to STATUS
  check("write STATUS=1 ok", ok && resp == RESP_OKAY);

  {
    uint32_t expected_status = (model_reset_req ? 2u : 0u) | (model_warning ? 1u : 0u);
    ok = bfm.read(0xC, &rd, &resp); advance_model();
    check("WARNING cleared but RESET_REQ still set (deliberately not clearable this way)",
          ok && rd == expected_status && !model_warning && model_reset_req);
  }

  // ---- KICK clears everything and restarts the count ----
  model_restart_this_cycle = true;
  ok = bfm.write(0x8, 0xFFFFFFFF, 0xF, &resp); advance_model(); // REG_KICK, data value irrelevant
  check("write KICK ok", ok && resp == RESP_OKAY);
  check("wdog_reset_req deasserted immediately after KICK", dut->wdog_reset_req == 0);

  {
    uint32_t expected_status = (model_reset_req ? 2u : 0u) | (model_warning ? 1u : 0u);
    ok = bfm.read(0xC, &rd, &resp); advance_model();
    check("STATUS fully cleared after KICK", ok && rd == 0 && expected_status == 0);
  }

  delete dut;
  delete ctx;

  if (fail_count) { printf("FAIL: %d check(s) failed\n", fail_count); return 1; }
  printf("PASS: watchdog (cycle-accurate WARNING + reset-request timing, KICK, STATUS semantics) all green\n");
  return 0;
}

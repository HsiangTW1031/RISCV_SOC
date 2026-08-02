// CDC stress test, opposite corner from jtag_chain_sim_main.cpp: that test
// drives tck much slower than clk (a real JTAG probe against a fast system
// clock, the common case); this one drives tck much FASTER than clk
// instead -- clk only gets one edge every TCK_HALVES_PER_CLK_HALF tck
// half-periods, so several tck edges (and toggle-synchronizer flips) can
// happen before the clk domain ever samples one. jtag_axi_bridge.v's CDC
// header comment explicitly claims the toggle-synchronizer/busy-compare
// scheme is robust "regardless of how large the clock-period ratio is in
// either direction" -- this test exists specifically to exercise the
// direction the other test doesn't.
//
// Otherwise identical scan sequence and checks to jtag_chain_sim_main.cpp
// (same IDCODE/AXI write-read-back/BYPASS coverage) -- only the clock
// relationship differs, to isolate the ratio itself as the variable.
#include "Vjtag_chain_testtop.h"
#include "verilated.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif
#include <cstdio>
#include <cstdint>

static const int TCK_HALVES_PER_CLK_HALF = 5;

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vjtag_chain_testtop* dut = new Vjtag_chain_testtop{ctx};

  auto clk_step = [&]() { dut->clk = !dut->clk; dut->eval(); };

  int tck_half_counter = 0;
  auto maybe_clk_step = [&]() {
    tck_half_counter++;
    if (tck_half_counter % TCK_HALVES_PER_CLK_HALF == 0) clk_step();
  };

  auto tap_edge = [&](int tms, int tdi) -> int {
    dut->tms = tms; dut->tdi = tdi;
    dut->eval();
    int tdo = dut->tdo;
    dut->tck = 1; dut->eval();
    maybe_clk_step();
    dut->tck = 0; dut->eval();
    maybe_clk_step();
    return tdo;
  };

  auto ir_scan = [&](uint8_t val) { // 4 bits, RUN_TEST_IDLE -> RUN_TEST_IDLE
    tap_edge(1, 0); // -> SELECT_DR_SCAN
    tap_edge(1, 0); // -> SELECT_IR_SCAN
    tap_edge(0, 0); // -> CAPTURE_IR
    tap_edge(0, 0); // -> SHIFT_IR
    for (int i = 0; i < 4; i++) {
      int bit = (val >> i) & 1;
      tap_edge(i == 3 ? 1 : 0, bit);
    }
    tap_edge(1, 0); // EXIT1_IR -> UPDATE_IR
    tap_edge(0, 0); // UPDATE_IR -> RUN_TEST_IDLE
  };

  auto dr_scan32 = [&](uint32_t val_in) -> uint32_t { // RUN_TEST_IDLE -> RUN_TEST_IDLE
    tap_edge(1, 0); // -> SELECT_DR_SCAN
    tap_edge(0, 0); // -> CAPTURE_DR
    tap_edge(0, 0); // -> SHIFT_DR
    uint32_t out = 0;
    for (int i = 0; i < 32; i++) {
      int bit_in = (val_in >> i) & 1;
      int tdo = tap_edge(i == 31 ? 1 : 0, bit_in);
      out |= (uint32_t(tdo & 1) << i);
    }
    tap_edge(1, 0); // EXIT1_DR -> UPDATE_DR
    tap_edge(0, 0); // UPDATE_DR -> RUN_TEST_IDLE
    return out;
  };

  const uint8_t IR_IDCODE = 0x1, IR_AXI_ADDR = 0x2, IR_AXI_DATA = 0x3, IR_AXI_CTRL = 0x4, IR_BYPASS = 0xF;

  int fail_count = 0;
  auto check = [&](const char* what, bool cond) {
    if (!cond) { printf("FAIL: %s\n", what); fail_count++; }
  };

  // ---- reset both domains, then TLR -> RUN_TEST_IDLE ----
  dut->rst = 1; dut->tck_rst = 1;
  dut->tms = 1; dut->tck = 0; dut->eval();
  for (int i = 0; i < 4; i++) { dut->tck = !dut->tck; dut->eval(); clk_step(); clk_step(); }
  dut->rst = 0; dut->tck_rst = 0;
  tap_edge(0, 0); // TEST_LOGIC_RESET -> RUN_TEST_IDLE

  // ---- IDCODE sanity: LSB must be 1 (IEEE 1149.1 requirement) ----
  ir_scan(IR_IDCODE);
  uint32_t idcode = dr_scan32(0);
  check("IDCODE LSB is 1", (idcode & 1) == 1);

  auto axi_write = [&](uint32_t addr, uint32_t data) {
    ir_scan(IR_AXI_ADDR); dr_scan32(addr);
    ir_scan(IR_AXI_DATA); dr_scan32(data);
    ir_scan(IR_AXI_CTRL); dr_scan32(0x1); // rw=0 (write), start=1
    uint32_t status;
    int spins = 0;
    do { status = dr_scan32(0); spins++; } while ((status & 0x1) && spins < 200); // poll BUSY
    check("write: bridge not stuck busy", spins < 200);
    check("write: bridge reported OKAY response", (status & 0x2) != 0);
  };

  auto axi_read = [&](uint32_t addr) -> uint32_t {
    ir_scan(IR_AXI_ADDR); dr_scan32(addr);
    ir_scan(IR_AXI_CTRL); dr_scan32(0x3); // rw=1 (read), start=1
    uint32_t status;
    int spins = 0;
    do { status = dr_scan32(0); spins++; } while ((status & 0x1) && spins < 200);
    check("read: bridge not stuck busy", spins < 200);
    check("read: bridge reported OKAY response", (status & 0x2) != 0);
    ir_scan(IR_AXI_DATA);
    return dr_scan32(0);
  };

  // ---- write then read back the same word (fake_axi_lite_slave decodes
  // addr[5:2], 16 words -> use word index 1 = byte address 0x4) ----
  axi_write(0x4, 0xCAFEF00D);
  uint32_t rd = axi_read(0x4);
  check("JTAG read-back matches JTAG-written value", rd == 0xCAFEF00D);

  // a second, different word + value, to rule out a stuck/always-matching path
  axi_write(0x8, 0x12345678);
  rd = axi_read(0x8);
  check("second word: JTAG read-back matches", rd == 0x12345678);

  // first word must still hold its value (no cross-talk between words)
  rd = axi_read(0x4);
  check("first word unaffected by the second write", rd == 0xCAFEF00D);

  // ---- BYPASS: 1-bit passthrough, one tck of latency ----
  ir_scan(IR_BYPASS);
  tap_edge(1, 0); // -> SELECT_DR_SCAN
  tap_edge(0, 0); // -> CAPTURE_DR (bypass_reg <= 0)
  tap_edge(0, 0); // -> SHIFT_DR
  int tdo1 = tap_edge(0, 1); // shift in a 1; tdo1 reflects the captured 0
  int tdo2 = tap_edge(1, 0); // shift in a 0 (exiting); tdo2 reflects the 1 just shifted in
  tap_edge(1, 0); tap_edge(0, 0); // UPDATE_DR -> RUN_TEST_IDLE
  check("BYPASS captures a fixed 0", tdo1 == 0);
  check("BYPASS shifts TDI through to TDO with 1 tck latency", tdo2 == 1);

#if VM_COVERAGE
  VerilatedCov::write("coverage.dat");
#endif
  delete dut;
  delete ctx;

  if (fail_count) { printf("FAIL: %d check(s) failed\n", fail_count); return 1; }
  printf("PASS: JTAG chain with tck FASTER than clk (opposite ratio corner from "
         "jtag_chain_sim_main.cpp) -- IDCODE, AXI write/read-back, BYPASS all green\n");
  return 0;
}

// Validates the full JTAG chain (jtag_tap + jtag_dtm + jtag_axi_bridge)
// bridged into a fake_axi_lite_slave: JTAG write then JTAG read-back
// through the same memory location, exercising the tck<->clk CDC in both
// directions. `tck` is driven deliberately much slower than `clk` (10
// clk half-cycles per tck half-cycle) to actually stress the clock-domain
// crossing rather than coincidentally working because the two clocks
// happen to be in lockstep.
#include "Vjtag_chain_testtop.h"
#include "verilated.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif
#include <cstdio>
#include <cstdint>

static const int CLK_STEPS_PER_TCK_HALF = 10;

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vjtag_chain_testtop* dut = new Vjtag_chain_testtop{ctx};

  auto clk_step = [&]() { dut->clk = !dut->clk; dut->eval(); };

  // Samples TDO *before* applying the tck rising edge (matches real JTAG
  // timing: TDO is valid throughout the low phase preceding the next
  // rising edge, reflecting the state as of the previous edge, not the
  // one about to happen), then pulses tck and lets `clk` run underneath.
  auto tap_edge = [&](int tms, int tdi) -> int {
    dut->tms = tms; dut->tdi = tdi;
    dut->eval();
    int tdo = dut->tdo;
    dut->tck = 1; dut->eval();
    for (int i = 0; i < CLK_STEPS_PER_TCK_HALF; i++) clk_step();
    dut->tck = 0; dut->eval();
    for (int i = 0; i < CLK_STEPS_PER_TCK_HALF; i++) clk_step();
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
    do { status = dr_scan32(0); spins++; } while ((status & 0x1) && spins < 50); // poll BUSY
    check("write: bridge not stuck busy", spins < 50);
    check("write: bridge reported OKAY response", (status & 0x2) != 0);
  };

  auto axi_read = [&](uint32_t addr) -> uint32_t {
    ir_scan(IR_AXI_ADDR); dr_scan32(addr);
    ir_scan(IR_AXI_CTRL); dr_scan32(0x3); // rw=1 (read), start=1
    uint32_t status;
    int spins = 0;
    do { status = dr_scan32(0); spins++; } while ((status & 0x1) && spins < 50);
    check("read: bridge not stuck busy", spins < 50);
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

  // ---- extra address/data diversity for the bridge's rdata/addr CDC
  // pipeline registers (rdata_reg/rdata_tck/rdata_sync1/rdata_sync2,
  // addr_reg/addr_tck -- see docs/coverage_waiver_report.md section 5):
  // the two words above leave some bits of these registers never
  // toggling the other way. A third word at the opposite end of the
  // address range fake_axi_lite_slave decodes (addr[5:2], 16 words),
  // with the bitwise complement of the first value, gives both the
  // address and data pipelines a maximally different pattern cheaply.
  axi_write(0x3C, ~0xCAFEF00Du);
  rd = axi_read(0x3C);
  check("third word (high address, complementary data) JTAG read-back matches", rd == (~0xCAFEF00Du));

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
  printf("PASS: JTAG chain (TAP+DTM+bridge, tck<->clk CDC, IDCODE, BYPASS, "
         "AXI write/read-back through a real AXI4-Lite slave) all green\n");
  return 0;
}

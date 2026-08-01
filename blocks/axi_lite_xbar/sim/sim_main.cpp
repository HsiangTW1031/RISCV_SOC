// Validates axi_lite_xbar's address decode + channel routing against three
// fake_axi_lite_slave stand-ins (see xbar_testtop.v), using the same
// axi_lite_bfm.h already proven against a single fake slave. Real ROM/RAM/
// UART RTL isn't needed yet to prove the crossbar's routing logic correct.
#include "Vxbar_testtop.h"
#include "verilated.h"
#include "axi_lite_bfm.h"
#include <cstdio>

static const uint8_t RESP_OKAY   = 0x0;
static const uint8_t RESP_SLVERR = 0x2;

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vxbar_testtop* dut = new Vxbar_testtop{ctx};

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

  uint8_t resp;
  uint32_t rd;
  bool ok;

  // ---- 1. ROM region (0x0000_0000) ----
  ok = bfm.write(0x00000000, 0xAAAA0001, 0xF, &resp);
  check("write ROM 0x0 ok", ok);
  check("write ROM 0x0 resp OKAY", resp == RESP_OKAY);
  ok = bfm.read(0x00000000, &rd, &resp);
  check("read ROM 0x0 ok", ok);
  check("read ROM 0x0 data", rd == 0xAAAA0001);
  check("read ROM 0x0 resp OKAY", resp == RESP_OKAY);

  // ---- 2. RAM region (0x1000_0000) ----
  ok = bfm.write(0x10000000, 0xBBBB0002, 0xF, &resp);
  check("write RAM 0x1000_0000 ok", ok);
  ok = bfm.read(0x10000004, &rd, &resp); // different word than the one written
  check("read RAM 0x1000_0004 (untouched) is zero", ok && rd == 0);
  ok = bfm.read(0x10000000, &rd, &resp);
  check("read RAM 0x1000_0000 data", ok && rd == 0xBBBB0002);

  // ---- 3. UART region (0x4000_2000) ----
  ok = bfm.write(0x40002000, 0xCCCC0003, 0xF, &resp);
  check("write UART 0x4000_2000 ok", ok);
  ok = bfm.read(0x40002000, &rd, &resp);
  check("read UART 0x4000_2000 data", ok && rd == 0xCCCC0003);

  // ---- 4. cross-region isolation: ROM word 0 unaffected by RAM/UART writes ----
  ok = bfm.read(0x00000000, &rd, &resp);
  check("ROM 0x0 unaffected by RAM/UART writes", ok && rd == 0xAAAA0001);

  // ---- 5. unmapped address -> SLVERR, no slave touched ----
  ok = bfm.write(0x50000000, 0xDEADDEAD, 0xF, &resp);
  check("write unmapped completes (crossbar self-answers)", ok);
  check("write unmapped resp SLVERR", resp == RESP_SLVERR);

  ok = bfm.read(0x50000000, &rd, &resp);
  check("read unmapped completes", ok);
  check("read unmapped resp SLVERR", resp == RESP_SLVERR);

  // a peripheral address that's in the map but not wired up yet (Timer) —
  // also expected to SLVERR at this phase, since only ROM/RAM/UART exist.
  ok = bfm.read(0x40000000, &rd, &resp);
  check("read not-yet-wired Timer addr completes", ok);
  check("read not-yet-wired Timer addr resp SLVERR", resp == RESP_SLVERR);

  // confirm the unmapped accesses didn't corrupt real slave state.
  ok = bfm.read(0x10000000, &rd, &resp);
  check("RAM 0x1000_0000 unaffected by unmapped access", ok && rd == 0xBBBB0002);

  delete dut;
  delete ctx;

  if (fail_count) {
    printf("FAIL: %d check(s) failed\n", fail_count);
    return 1;
  }
  printf("PASS: axi_lite_xbar routing/decode (ROM/RAM/UART + SLVERR on miss) all green\n");
  return 0;
}

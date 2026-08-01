// Validates sram.v: read/write round-trip, per-byte write-strobe partial
// writes, and address independence between words.
#include "Vsram.h"
#include "verilated.h"
#include "axi_lite_bfm.h"
#include <cstdio>

static const uint8_t RESP_OKAY = 0x0;

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vsram* dut = new Vsram{ctx};

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

  uint32_t rd; uint8_t resp; bool ok;

  // full-word round trip
  ok = bfm.write(0x00000000, 0x12345678, 0xF, &resp);
  check("full write ok", ok && resp == RESP_OKAY);
  ok = bfm.read(0x00000000, &rd, &resp);
  check("full read back", ok && rd == 0x12345678 && resp == RESP_OKAY);

  // distinct word independence
  ok = bfm.write(0x00000004, 0xCAFEBABE, 0xF, &resp);
  ok = bfm.read(0x00000000, &rd, &resp);
  check("word 0 unaffected by word 1 write", ok && rd == 0x12345678);
  ok = bfm.read(0x00000004, &rd, &resp);
  check("word 1 has its own value", ok && rd == 0xCAFEBABE);

  // partial (byte-strobe) write: only touch byte 0 of word 0
  ok = bfm.write(0x00000000, 0x000000FF, 0x1, &resp);
  check("partial write ok", ok && resp == RESP_OKAY);
  ok = bfm.read(0x00000000, &rd, &resp);
  check("partial write only changed byte 0", ok && rd == 0x123456FF);

  // last word in the 128KB range (index 32767): addr = 32767*4 = 0x1FFFC
  ok = bfm.write(0x0001FFFC, 0xFEEDFACE, 0xF, &resp);
  ok = bfm.read(0x0001FFFC, &rd, &resp);
  check("last word round-trips", ok && rd == 0xFEEDFACE);

  delete dut;
  delete ctx;

  if (fail_count) { printf("FAIL: %d check(s) failed\n", fail_count); return 1; }
  printf("PASS: sram (full/partial write, read-back, word independence) all green\n");
  return 0;
}

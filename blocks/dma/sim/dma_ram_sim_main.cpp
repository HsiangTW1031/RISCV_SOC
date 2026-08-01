// Validates dma_ram.v's AXI4 burst slave port directly: multi-beat INCR
// write bursts (with byte-strobe partial writes), multi-beat read bursts
// with correct RLAST timing, and back-to-back bursts (no leftover state
// from a previous burst corrupting the next one).
#include "Vdma_ram.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vdma_ram* dut = new Vdma_ram{ctx};

  auto clock = [&]() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); };

  dut->rst = 1;
  clock(); clock();
  dut->rst = 0;
  clock();

  int fail_count = 0;
  auto check = [&](const char* what, bool cond) {
    if (!cond) { printf("FAIL: %s\n", what); fail_count++; }
  };

  // Issues one INCR write burst: addr (byte address), a vector of 32-bit
  // words, one strobe per word (0xF = full word).
  auto write_burst = [&](uint32_t addr, const std::vector<uint32_t>& words, const std::vector<uint8_t>& strobes) {
    dut->s_awvalid = 1; dut->s_awaddr = addr; dut->s_awlen = words.size() - 1;
    dut->s_awsize = 2; dut->s_awburst = 1; // INCR
    int timeout = 0;
    while (!(dut->s_awvalid && dut->s_awready) && timeout < 50) { clock(); timeout++; }
    clock(); // consume the AW handshake cycle
    dut->s_awvalid = 0;

    for (size_t i = 0; i < words.size(); i++) {
      dut->s_wvalid = 1; dut->s_wdata = words[i]; dut->s_wstrb = strobes[i];
      dut->s_wlast = (i == words.size() - 1) ? 1 : 0;
      timeout = 0;
      while (!(dut->s_wvalid && dut->s_wready) && timeout < 50) { clock(); timeout++; }
      clock();
    }
    dut->s_wvalid = 0;

    dut->s_bready = 1;
    timeout = 0;
    while (!dut->s_bvalid && timeout < 50) { clock(); timeout++; }
    bool ok = dut->s_bvalid && dut->s_bresp == 0;
    clock();
    dut->s_bready = 0;
    return ok;
  };

  auto read_burst = [&](uint32_t addr, int n_beats) -> std::vector<uint32_t> {
    std::vector<uint32_t> out;
    dut->s_arvalid = 1; dut->s_araddr = addr; dut->s_arlen = n_beats - 1;
    dut->s_arsize = 2; dut->s_arburst = 1;
    int timeout = 0;
    while (!(dut->s_arvalid && dut->s_arready) && timeout < 50) { clock(); timeout++; }
    clock();
    dut->s_arvalid = 0;

    dut->s_rready = 1;
    bool last_seen = false;
    timeout = 0;
    while (!last_seen && timeout < 500) {
      if (dut->s_rvalid) {
        out.push_back(dut->s_rdata);
        if (dut->s_rlast) last_seen = true;
      }
      clock();
      timeout++;
    }
    dut->s_rready = 0;
    return out;
  };

  // ---- 4-beat write burst, then read it back ----
  {
    std::vector<uint32_t> words = {0x11111111, 0x22222222, 0x33333333, 0x44444444};
    std::vector<uint8_t> strobes = {0xF, 0xF, 0xF, 0xF};
    bool ok = write_burst(0x0, words, strobes);
    check("4-beat write burst completes with OKAY", ok);

    auto rd = read_burst(0x0, 4);
    check("4-beat read burst returns 4 beats", rd.size() == 4);
    for (int i = 0; i < 4 && i < (int)rd.size(); i++) {
      char msg[64]; snprintf(msg, sizeof(msg), "read burst beat %d matches written value", i);
      check(msg, rd[i] == words[i]);
    }
  }

  // ---- byte-strobe partial write: only touch byte 0 and byte 2 ----
  {
    std::vector<uint32_t> words = {0xAABBCCDD};
    std::vector<uint8_t> strobes = {0x5}; // strobe bits 0 and 2 -> byte0 (0xDD) and byte2 (0xBB)
    write_burst(0x10, words, strobes);
    auto rd = read_burst(0x10, 1);
    // byte0=0xDD (strobed), byte1=unchanged(0), byte2=0xBB (strobed), byte3=unchanged(0)
    check("byte-strobe partial write: only strobed bytes land", rd.size() == 1 && rd[0] == 0x00BB00DD);
  }

  // ---- a single-beat burst (AWLEN=0) works ----
  {
    std::vector<uint32_t> words = {0xDEADBEEF};
    std::vector<uint8_t> strobes = {0xF};
    write_burst(0x20, words, strobes);
    auto rd = read_burst(0x20, 1);
    check("single-beat burst round-trips", rd.size() == 1 && rd[0] == 0xDEADBEEF);
  }

  // ---- back-to-back bursts: earlier data untouched by a later, different-address burst ----
  {
    std::vector<uint32_t> words2 = {0x99999999, 0x88888888};
    std::vector<uint8_t> strobes2 = {0xF, 0xF};
    write_burst(0x30, words2, strobes2);
    auto rd_new = read_burst(0x30, 2);
    check("second burst lands correctly", rd_new.size() == 2 && rd_new[0] == 0x99999999 && rd_new[1] == 0x88888888);
    auto rd_old = read_burst(0x0, 1);
    check("earlier burst's data untouched by the later one", rd_old.size() == 1 && rd_old[0] == 0x11111111);
  }

  delete dut;
  delete ctx;

  if (fail_count) { printf("FAIL: %d check(s) failed\n", fail_count); return 1; }
  printf("PASS: dma_ram (AXI4 INCR burst read/write, byte strobes, single-beat, "
         "back-to-back bursts) all green\n");
  return 0;
}

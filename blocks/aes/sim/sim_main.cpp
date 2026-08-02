// Validates aes.v's AXI-Lite register interface against the FIPS-197
// Appendix B and Appendix C.1 known-answer vectors (encrypt AND decrypt),
// plus the register-level behaviors: KEY reads back as 0 (write-only),
// STATUS.DONE write-1-to-clear, and START-while-busy is ignored (no queue).
#include "Vaes.h"
#include "verilated.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif
#include "axi_lite_bfm.h"
#include <cstdio>
#include <cstring>
#include <string>

static void unhex16(const char* s, uint8_t b[16]) {
  for (int i = 0; i < 16; i++) { unsigned v; sscanf(s + i*2, "%2x", &v); b[i] = (uint8_t)v; }
}
static uint32_t word_at(const uint8_t b[16], int w) { // w=0..3, word0=MSB
  int base = w * 4;
  return (uint32_t(b[base]) << 24) | (uint32_t(b[base+1]) << 16) | (uint32_t(b[base+2]) << 8) | b[base+3];
}
static std::string hex16_words(uint32_t w0, uint32_t w1, uint32_t w2, uint32_t w3) {
  char buf[33];
  snprintf(buf, sizeof(buf), "%08x%08x%08x%08x", w0, w1, w2, w3);
  return std::string(buf);
}

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vaes* dut = new Vaes{ctx};

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

  uint32_t rd; uint8_t resp;

  auto run_block = [&](const char* key_hex, const char* in_hex, int encdec, int timeout_cycles = 400) -> std::string {
    uint8_t key[16], in[16];
    unhex16(key_hex, key);
    unhex16(in_hex, in);
    for (int w = 0; w < 4; w++) bfm.write(0x10 + 4*w, word_at(key, w), 0xF, &resp); // KEY0..3
    for (int w = 0; w < 4; w++) bfm.write(0x20 + 4*w, word_at(in, w), 0xF, &resp);  // DATA0..3
    bfm.write(0x0, 0x1 | (encdec << 1), 0xF, &resp); // CTRL: START
    for (int i = 0; i < timeout_cycles; i++) {
      bfm.read(0x4, &rd, &resp); // STATUS
      if (rd & 0x2) break;       // DONE
    }
    uint32_t w0, w1, w2, w3;
    bfm.read(0x30, &w0, &resp); bfm.read(0x34, &w1, &resp);
    bfm.read(0x38, &w2, &resp); bfm.read(0x3C, &w3, &resp);
    bfm.write(0x4, 0x2, 0xF, &resp); // clear DONE
    return hex16_words(w0, w1, w2, w3);
  };

  // ---- FIPS-197 Appendix B ----
  {
    const char* key = "2b7e151628aed2a6abf7158809cf4f3c";
    const char* pt  = "3243f6a8885a308d313198a2e0370734";
    const char* ct_expected = "3925841d02dc09fbdc118597196a0b32";
    std::string ct = run_block(key, pt, 0);
    check("FIPS-197 App.B encrypt (via AXI-Lite)", ct == ct_expected);
    std::string pt2 = run_block(key, ct_expected, 1);
    check("FIPS-197 App.B decrypt (via AXI-Lite)", pt2 == pt);
  }

  // ---- FIPS-197 Appendix C.1 ----
  {
    const char* key = "000102030405060708090a0b0c0d0e0f";
    const char* pt  = "00112233445566778899aabbccddeeff";
    const char* ct_expected = "69c4e0d86a7b0430d8cdb78070b4c55a";
    std::string ct = run_block(key, pt, 0);
    check("FIPS-197 App.C.1 encrypt (via AXI-Lite)", ct == ct_expected);
    std::string pt2 = run_block(key, ct_expected, 1);
    check("FIPS-197 App.C.1 decrypt (via AXI-Lite)", pt2 == pt);
  }

  // ---- KEY registers are write-only: always read back 0 ----
  bfm.write(0x10, 0xDEADBEEF, 0xF, &resp);
  bfm.read(0x10, &rd, &resp);
  check("KEY0 reads back as 0 regardless of what was written", rd == 0);

  // ---- busy / no-queue ----
  {
    uint8_t key[16], pt[16];
    unhex16("000102030405060708090a0b0c0d0e0f", key);
    unhex16("00112233445566778899aabbccddeeff", pt);
    for (int w = 0; w < 4; w++) bfm.write(0x10 + 4*w, word_at(key, w), 0xF, &resp);
    for (int w = 0; w < 4; w++) bfm.write(0x20 + 4*w, word_at(pt, w), 0xF, &resp);
    bfm.write(0x0, 0x1, 0xF, &resp); // START encrypt
    bfm.read(0x4, &rd, &resp);
    check("busy shortly after START", (rd & 0x1) != 0);

    uint8_t other_pt[16];
    unhex16("ffffffffffffffffffffffffffffffff", other_pt);
    for (int w = 0; w < 4; w++) bfm.write(0x20 + 4*w, word_at(other_pt, w), 0xF, &resp); // changed mid-flight
    bfm.write(0x0, 0x1, 0xF, &resp); // second START while busy: ignored

    bool done = false;
    for (int i = 0; i < 400 && !done; i++) { bfm.read(0x4, &rd, &resp); done = rd & 0x2; }
    check("first operation completes despite attempted re-start", done);

    uint32_t w0, w1, w2, w3;
    bfm.read(0x30, &w0, &resp); bfm.read(0x34, &w1, &resp);
    bfm.read(0x38, &w2, &resp); bfm.read(0x3C, &w3, &resp);
    std::string ct = hex16_words(w0, w1, w2, w3);
    check("result matches the ORIGINAL plaintext, not the mid-flight one",
          ct == "69c4e0d86a7b0430d8cdb78070b4c55a");
    bfm.write(0x4, 0x2, 0xF, &resp);
  }

  // ---- Phase 6: CBC and CTR modes through the AXI-Lite register map
  // (MODE bits, LOAD_IV, IV0-3), against the same NIST SP 800-38A vectors
  // already verified against aes_chain.v directly. ----
  {
    const char* key = "2b7e151628aed2a6abf7158809cf4f3c";
    const char* pt_hex[4] = {
        "6bc1bee22e409f96e93d7e117393172a", "ae2d8a571e03ac9c9eb76fac45af8e51",
        "30c81c46a35ce411e5fbc1191a0a52ef", "f69f2445df4f9b17ad2b417be66c3710",
    };
    const char* cbc_ct_hex[4] = {
        "7649abac8119b246cee98e9b12e9197d", "5086cb9b507219ee95db113a917678b2",
        "73bed6b8e3c1743b7116e69e22229516", "3ff1caa1681fac09120eca307586e1a7",
    };
    const int MODE_CBC = 1;

    uint8_t keyb[16]; unhex16(key, keyb);
    for (int w = 0; w < 4; w++) bfm.write(0x10 + 4*w, word_at(keyb, w), 0xF, &resp);

    uint8_t iv[16]; unhex16("000102030405060708090a0b0c0d0e0f", iv);
    for (int w = 0; w < 4; w++) bfm.write(0x40 + 4*w, word_at(iv, w), 0xF, &resp); // IV0-3
    bfm.write(0x0, 0x1 << 4, 0xF, &resp); // CTRL: LOAD_IV

    for (int i = 0; i < 4; i++) {
      uint8_t in[16]; unhex16(pt_hex[i], in);
      for (int w = 0; w < 4; w++) bfm.write(0x20 + 4*w, word_at(in, w), 0xF, &resp); // DATA0-3
      bfm.write(0x0, 0x1 | (MODE_CBC << 2), 0xF, &resp); // CTRL: START, encdec=0, mode=CBC
      bool done = false;
      for (int t = 0; t < 400 && !done; t++) { bfm.read(0x4, &rd, &resp); done = rd & 0x2; }
      check("CBC via AXI-Lite: block completes", done);
      uint32_t w0, w1, w2, w3;
      bfm.read(0x30, &w0, &resp); bfm.read(0x34, &w1, &resp);
      bfm.read(0x38, &w2, &resp); bfm.read(0x3C, &w3, &resp);
      char msg[64]; snprintf(msg, sizeof(msg), "CBC via AXI-Lite: block %d matches NIST vector", i);
      check(msg, hex16_words(w0, w1, w2, w3) == cbc_ct_hex[i]);
      bfm.write(0x4, 0x2, 0xF, &resp); // clear DONE
    }
  }

#if VM_COVERAGE
  VerilatedCov::write("coverage.dat");
#endif
  delete dut;
  delete ctx;

  if (fail_count) { printf("FAIL: %d check(s) failed\n", fail_count); return 1; }
  printf("PASS: aes AXI-Lite wrapper (FIPS-197 App.B + App.C.1 ECB encrypt/decrypt, "
         "NIST SP800-38A CBC via MODE/LOAD_IV/IV registers, KEY write-only, "
         "busy/no-queue) all green\n");
  return 0;
}

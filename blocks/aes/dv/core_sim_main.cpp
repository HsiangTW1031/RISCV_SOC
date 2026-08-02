// Directed test for aes_core.v (encrypt + decrypt) against the FIPS-197
// Appendix B and Appendix C.1 known-answer vectors. Drives the module
// directly -- this is the pre-AXI-Lite datapath/FSM test; the AXI-Lite
// wrapper (aes.v) gets its own pass over the same vectors through the
// register interface in aes_sim_main.cpp.
#include "Vaes_core.h"
#include "verilated.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>

// key_in/data_in/data_out are 128-bit ports -> Verilator represents each as
// 4 x uint32_t words, word[0] = bits[31:0] (LSB) .. word[3] = bits[127:96]
// (MSB). aes_core.v's byte 0 is bits[127:120] (the MSB byte), so byte0..3
// live in word[3], byte4..7 in word[2], byte8..11 in word[1], byte12..15
// in word[0].
static void bytes_to_words(const uint8_t b[16], uint32_t w[4]) {
  for (int i = 0; i < 4; i++) {
    int base = 12 - i * 4;
    w[i] = (uint32_t(b[base]) << 24) | (uint32_t(b[base+1]) << 16) | (uint32_t(b[base+2]) << 8) | b[base+3];
  }
}
static void words_to_bytes(const uint32_t w[4], uint8_t b[16]) {
  for (int i = 0; i < 4; i++) {
    int base = 12 - i * 4;
    b[base]   = (w[i] >> 24) & 0xFF;
    b[base+1] = (w[i] >> 16) & 0xFF;
    b[base+2] = (w[i] >> 8) & 0xFF;
    b[base+3] = w[i] & 0xFF;
  }
}
static void hex16(const uint8_t b[16], char* out) {
  for (int i = 0; i < 16; i++) sprintf(out + i * 2, "%02x", b[i]);
  out[32] = '\0';
}
static void unhex16(const char* s, uint8_t b[16]) {
  for (int i = 0; i < 16; i++) { unsigned v; sscanf(s + i*2, "%2x", &v); b[i] = (uint8_t)v; }
}

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vaes_core* dut = new Vaes_core{ctx};

  auto clock = [&]() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
  };

  dut->rst = 1;
  clock(); clock();
  dut->rst = 0;
  clock();

  int fail_count = 0;
  auto check = [&](const char* what, bool cond) {
    if (!cond) { printf("FAIL: %s\n", what); fail_count++; }
  };

  auto run_block = [&](const char* key_hex, const char* in_hex, int encdec) -> std::string {
    uint8_t key[16], in[16];
    unhex16(key_hex, key);
    unhex16(in_hex, in);
    uint32_t kw[4], iw[4];
    bytes_to_words(key, kw);
    bytes_to_words(in, iw);
    for (int i = 0; i < 4; i++) { dut->key_in[i] = kw[i]; dut->data_in[i] = iw[i]; }
    dut->encdec = encdec;
    dut->start = 1;
    clock();
    dut->start = 0;

    int timeout = 0;
    while (!dut->done && timeout < 200) { clock(); timeout++; }
    if (!dut->done) return "TIMEOUT";

    uint32_t ow[4] = {dut->data_out[0], dut->data_out[1], dut->data_out[2], dut->data_out[3]};
    uint8_t out[16];
    words_to_bytes(ow, out);
    char hex[33];
    hex16(out, hex);
    return std::string(hex);
  };

  // ---- FIPS-197 Appendix B ----
  {
    const char* key = "2b7e151628aed2a6abf7158809cf4f3c";
    const char* pt  = "3243f6a8885a308d313198a2e0370734";
    const char* ct_expected = "3925841d02dc09fbdc118597196a0b32";
    std::string ct = run_block(key, pt, 0);
    check("FIPS-197 App.B encrypt", ct == ct_expected);
    printf("App.B encrypt: got %s expected %s\n", ct.c_str(), ct_expected);
    std::string pt2 = run_block(key, ct_expected, 1);
    check("FIPS-197 App.B decrypt", pt2 == pt);
    printf("App.B decrypt: got %s expected %s\n", pt2.c_str(), pt);
  }

  // ---- FIPS-197 Appendix C.1 (AES-128) ----
  {
    const char* key = "000102030405060708090a0b0c0d0e0f";
    const char* pt  = "00112233445566778899aabbccddeeff";
    const char* ct_expected = "69c4e0d86a7b0430d8cdb78070b4c55a";
    std::string ct = run_block(key, pt, 0);
    check("FIPS-197 App.C.1 encrypt", ct == ct_expected);
    printf("App.C.1 encrypt: got %s expected %s\n", ct.c_str(), ct_expected);
    std::string pt2 = run_block(key, ct_expected, 1);
    check("FIPS-197 App.C.1 decrypt", pt2 == pt);
    printf("App.C.1 decrypt: got %s expected %s\n", pt2.c_str(), pt);
  }

#if VM_COVERAGE
  VerilatedCov::write("coverage.dat");
#endif
  delete dut;
  delete ctx;

  if (fail_count) { printf("FAIL: %d check(s) failed\n", fail_count); return 1; }
  printf("PASS: aes_core (FIPS-197 App.B + App.C.1, encrypt and decrypt) all green\n");
  return 0;
}

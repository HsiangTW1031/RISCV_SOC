// Validates aes_chain.v (CBC and CTR mode wrapping the unmodified Phase 4
// aes_core.v) against the NIST SP 800-38A AES-128 example vectors
// (Appendix F.2.1/F.2.2 for CBC, F.5.1/F.5.2 for CTR) -- the same vectors
// already cross-checked in Python before this RTL was written.
#include "Vaes_chain.h"
#include "verilated.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif
#include <cstdio>
#include <cstdint>
#include <cstring>

static void unhex16(const char* s, uint8_t b[16]) {
  for (int i = 0; i < 16; i++) { unsigned v; sscanf(s + i*2, "%2x", &v); b[i] = (uint8_t)v; }
}
static void bytes_to_words(const uint8_t b[16], uint32_t w[4]) {
  for (int i = 0; i < 4; i++) {
    int base = 12 - i * 4;
    w[i] = (uint32_t(b[base]) << 24) | (uint32_t(b[base+1]) << 16) | (uint32_t(b[base+2]) << 8) | b[base+3];
  }
}
static void words_to_bytes(const uint32_t w[4], uint8_t b[16]) {
  for (int i = 0; i < 4; i++) {
    int base = 12 - i * 4;
    b[base] = (w[i]>>24)&0xFF; b[base+1]=(w[i]>>16)&0xFF; b[base+2]=(w[i]>>8)&0xFF; b[base+3]=w[i]&0xFF;
  }
}
static void hex16(const uint8_t b[16], char* out) {
  for (int i = 0; i < 16; i++) sprintf(out + i*2, "%02x", b[i]);
  out[32] = '\0';
}

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vaes_chain* dut = new Vaes_chain{ctx};

  auto clock = [&]() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); };

  dut->rst = 1;
  clock(); clock();
  dut->rst = 0;
  clock();

  int fail_count = 0;
  auto check = [&](const char* what, bool cond) {
    if (!cond) { printf("FAIL: %s\n", what); fail_count++; }
  };

  const char* key_hex = "2b7e151628aed2a6abf7158809cf4f3c";
  uint8_t key[16]; unhex16(key_hex, key);
  uint32_t kw[4]; bytes_to_words(key, kw);
  for (int i = 0; i < 4; i++) dut->key_in[i] = kw[i];

  const char* pt_hex[4] = {
      "6bc1bee22e409f96e93d7e117393172a",
      "ae2d8a571e03ac9c9eb76fac45af8e51",
      "30c81c46a35ce411e5fbc1191a0a52ef",
      "f69f2445df4f9b17ad2b417be66c3710",
  };

  auto load_iv = [&](const char* iv_hex) {
    uint8_t iv[16]; unhex16(iv_hex, iv);
    uint32_t ivw[4]; bytes_to_words(iv, ivw);
    for (int i = 0; i < 4; i++) dut->iv_in[i] = ivw[i];
    dut->load_iv = 1;
    clock();
    dut->load_iv = 0;
  };

  auto run_block = [&](const char* in_hex, int encdec, int mode) -> std::string {
    uint8_t in[16]; unhex16(in_hex, in);
    uint32_t inw[4]; bytes_to_words(in, inw);
    for (int i = 0; i < 4; i++) dut->data_in[i] = inw[i];
    dut->encdec = encdec;
    dut->mode = mode;
    dut->start = 1;
    clock();
    dut->start = 0;
    int timeout = 0;
    while (!dut->done && timeout < 200) { clock(); timeout++; }
    uint32_t ow[4] = {dut->data_out[0], dut->data_out[1], dut->data_out[2], dut->data_out[3]};
    uint8_t out[16]; words_to_bytes(ow, out);
    char hex[33]; hex16(out, hex);
    return std::string(hex);
  };

  const int MODE_CBC = 1, MODE_CTR = 2;

  // ---- CBC encrypt: NIST SP800-38A F.2.1 ----
  const char* expected_cbc_ct[4] = {
      "7649abac8119b246cee98e9b12e9197d",
      "5086cb9b507219ee95db113a917678b2",
      "73bed6b8e3c1743b7116e69e22229516",
      "3ff1caa1681fac09120eca307586e1a7",
  };
  load_iv("000102030405060708090a0b0c0d0e0f");
  std::string cbc_ct[4];
  for (int i = 0; i < 4; i++) {
    cbc_ct[i] = run_block(pt_hex[i], 0, MODE_CBC);
    char msg[64]; snprintf(msg, sizeof(msg), "CBC encrypt block %d matches NIST vector", i);
    check(msg, cbc_ct[i] == expected_cbc_ct[i]);
  }

  // ---- CBC decrypt: feed the ciphertext blocks back, recover plaintext ----
  load_iv("000102030405060708090a0b0c0d0e0f");
  for (int i = 0; i < 4; i++) {
    std::string pt = run_block(cbc_ct[i].c_str(), 1, MODE_CBC);
    char msg[64]; snprintf(msg, sizeof(msg), "CBC decrypt block %d recovers plaintext", i);
    check(msg, pt == pt_hex[i]);
  }

  // ---- CTR: NIST SP800-38A F.5.1 ----
  const char* expected_ctr_ct[4] = {
      "874d6191b620e3261bef6864990db6ce",
      "9806f66b7970fdff8617187bb9fffdff",
      "5ae4df3edbd5d35e5b4f09020db03eab",
      "1e031dda2fbe03d1792170a0f3009cee",
  };
  load_iv("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff");
  std::string ctr_ct[4];
  for (int i = 0; i < 4; i++) {
    ctr_ct[i] = run_block(pt_hex[i], 0, MODE_CTR);
    char msg[64]; snprintf(msg, sizeof(msg), "CTR block %d matches NIST vector", i);
    check(msg, ctr_ct[i] == expected_ctr_ct[i]);
  }

  // ---- CTR "decrypt" (identical operation) recovers plaintext ----
  load_iv("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff");
  for (int i = 0; i < 4; i++) {
    std::string pt = run_block(ctr_ct[i].c_str(), 1, MODE_CTR);
    char msg[64]; snprintf(msg, sizeof(msg), "CTR block %d round-trip recovers plaintext", i);
    check(msg, pt == pt_hex[i]);
  }

#if VM_COVERAGE
  VerilatedCov::write("coverage.dat");
#endif
  delete dut;
  delete ctx;

  if (fail_count) { printf("FAIL: %d check(s) failed\n", fail_count); return 1; }
  printf("PASS: aes_chain (CBC + CTR vs NIST SP 800-38A vectors, encrypt+decrypt) all green\n");
  return 0;
}

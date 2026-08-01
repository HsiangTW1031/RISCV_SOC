// Unit test for aes_key_expand.v against the FIPS-197 Appendix A.1 AES-128
// key expansion example (independently re-derived and cross-checked in a
// throwaway Python script before this test was written -- see
// docs/aes_report.md). Drives the module directly (no AXI-Lite here; this
// is an internal building block, not a CPU-visible peripheral).
#include "Vaes_key_expand.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>

// round_keys is a 1408-bit (44 x 32-bit word) output; Verilator represents
// it as an array of uint32_t words, word[0] = bits[31:0] (LSBs). The RTL
// packs round_keys[128*i +: 128] = rk[i], so rk[i]'s 4 words live at
// word[4*i .. 4*i+3], word[4*i] = rk[i][31:0] (least-significant word of
// that round key) up to word[4*i+3] = rk[i][127:96].
static void get_round_key(const Vaes_key_expand* dut, int i, uint8_t out[16]) {
  for (int w = 0; w < 4; w++) {
    uint32_t word = dut->round_keys[4 * i + w];
    // word w=0 -> rk bytes [15:12] (LSB word, big-endian byte order within
    // the word to match FIPS-197's "w = a<<24|b<<16|c<<8|d" convention)
    int base = 12 - w * 4;
    out[base + 0] = (word >> 24) & 0xFF;
    out[base + 1] = (word >> 16) & 0xFF;
    out[base + 2] = (word >> 8) & 0xFF;
    out[base + 3] = word & 0xFF;
  }
}

static void hex16(const uint8_t b[16], char* out) {
  for (int i = 0; i < 16; i++) sprintf(out + i * 2, "%02x", b[i]);
  out[32] = '\0';
}

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vaes_key_expand* dut = new Vaes_key_expand{ctx};

  auto clock = [&]() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
  };

  dut->rst = 1;
  clock(); clock();
  dut->rst = 0;
  clock();

  // FIPS-197 Appendix A.1 example key
  const uint8_t key[16] = {0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,
                           0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f};
  const char* expected[11] = {
      "000102030405060708090a0b0c0d0e0f",
      "d6aa74fdd2af72fadaa678f1d6ab76fe",
      "b692cf0b643dbdf1be9bc5006830b3fe",
      "b6ff744ed2c2c9bf6c590cbf0469bf41",
      "47f7f7bc95353e03f96c32bcfd058dfd",
      "3caaa3e8a99f9deb50f3af57adf622aa",
      "5e390f7df7a69296a7553dc10aa31f6b",
      "14f9701ae35fe28c440adf4d4ea9c026",
      "47438735a41c65b9e016baf4aebf7ad2",
      "549932d1f08557681093ed9cbe2c974e",
      "13111d7fe3944a17f307a78b4d2b30c5",
  };

  dut->key_in[0] = (key[12]<<24)|(key[13]<<16)|(key[14]<<8)|key[15];
  dut->key_in[1] = (key[8]<<24)|(key[9]<<16)|(key[10]<<8)|key[11];
  dut->key_in[2] = (key[4]<<24)|(key[5]<<16)|(key[6]<<8)|key[7];
  dut->key_in[3] = (key[0]<<24)|(key[1]<<16)|(key[2]<<8)|key[3];
  dut->start = 1;
  clock();
  dut->start = 0;

  int fail_count = 0;
  int timeout = 0;
  while (!dut->done && timeout < 100) { clock(); timeout++; }
  if (!dut->done) { printf("FAIL: aes_key_expand never asserted done\n"); return 1; }

  for (int i = 0; i <= 10; i++) {
    uint8_t rk[16];
    get_round_key(dut, i, rk);
    char got[33];
    hex16(rk, got);
    bool ok = strcmp(got, expected[i]) == 0;
    if (!ok) {
      printf("FAIL: rk[%d] = %s, expected %s\n", i, got, expected[i]);
      fail_count++;
    }
  }

  delete dut;
  delete ctx;

  if (fail_count) { printf("FAIL: %d round key(s) mismatched\n", fail_count); return 1; }
  printf("PASS: aes_key_expand (all 11 round keys match FIPS-197 Appendix A.1) all green\n");
  return 0;
}

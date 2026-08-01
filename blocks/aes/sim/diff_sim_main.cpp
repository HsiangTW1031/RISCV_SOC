// Differential test: a from-scratch, self-contained C++ AES-128 reference
// model (no external crypto library -- the S-box/round-constant tables are
// computed at program start from the GF(2^8) definition, the same way the
// RTL's tables were derived, but via a completely independent code path)
// run against 500+ random plaintext/key pairs through the actual RTL (via
// Verilator, through the AXI-Lite register interface), checking that
// ciphertexts match and that decrypting the RTL's own ciphertext recovers
// the original plaintext. This is the Phase 4 exit criterion for coverage
// beyond the fixed FIPS-197 KAT vectors, which only exercise two
// particular (key, plaintext) pairs.
#include "Vaes.h"
#include "verilated.h"
#include "axi_lite_bfm.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <random>
#include <array>

// ---------------------------------------------------------------------
// Self-contained C++ AES-128 reference model
// ---------------------------------------------------------------------
namespace aes_ref {

static uint8_t sbox[256], inv_sbox[256];
static uint8_t rcon[11];

static uint8_t gmul(uint8_t a, uint8_t b) {
  uint8_t p = 0;
  for (int i = 0; i < 8; i++) {
    if (b & 1) p ^= a;
    bool hi = a & 0x80;
    a <<= 1;
    if (hi) a ^= 0x1B;
    b >>= 1;
  }
  return p;
}

static void init_tables() {
  uint8_t inv[256] = {0};
  for (int a = 1; a < 256; a++)
    for (int b = 1; b < 256; b++)
      if (gmul((uint8_t)a, (uint8_t)b) == 1) { inv[a] = (uint8_t)b; break; }

  for (int a = 0; a < 256; a++) {
    uint8_t b = inv[a];
    uint8_t r = 0;
    for (int i = 0; i < 8; i++) {
      int bit = ((b >> i) & 1) ^ ((b >> ((i+4)%8)) & 1) ^ ((b >> ((i+5)%8)) & 1)
              ^ ((b >> ((i+6)%8)) & 1) ^ ((b >> ((i+7)%8)) & 1) ^ ((0x63 >> i) & 1);
      r |= (bit & 1) << i;
    }
    sbox[a] = r;
  }
  for (int a = 0; a < 256; a++) inv_sbox[sbox[a]] = (uint8_t)a;

  rcon[0] = 0x00;
  uint8_t r = 0x01;
  for (int i = 1; i <= 10; i++) { rcon[i] = r; r = gmul(r, 0x02); }
}

static uint8_t xtime(uint8_t a) { return (a & 0x80) ? ((a << 1) ^ 0x1B) : (a << 1); }
static uint8_t mul9(uint8_t a)  { uint8_t x2=xtime(a),x4=xtime(x2),x8=xtime(x4); return x8^a; }
static uint8_t mul11(uint8_t a) { uint8_t x2=xtime(a),x4=xtime(x2),x8=xtime(x4); return x8^x2^a; }
static uint8_t mul13(uint8_t a) { uint8_t x2=xtime(a),x4=xtime(x2),x8=xtime(x4); return x8^x4^a; }
static uint8_t mul14(uint8_t a) { uint8_t x2=xtime(a),x4=xtime(x2),x8=xtime(x4); return x8^x4^x2; }

using Block = std::array<uint8_t, 16>;
using RoundKeys = std::array<uint32_t, 44>; // 11 round keys x 4 words

static RoundKeys key_expansion(const Block& key) {
  RoundKeys w{};
  for (int i = 0; i < 4; i++)
    w[i] = (uint32_t(key[4*i])<<24)|(uint32_t(key[4*i+1])<<16)|(uint32_t(key[4*i+2])<<8)|key[4*i+3];
  for (int i = 4; i < 44; i++) {
    uint32_t temp = w[i-1];
    if (i % 4 == 0) {
      temp = (temp << 8) | (temp >> 24); // RotWord
      temp = (uint32_t(sbox[(temp>>24)&0xFF])<<24)|(uint32_t(sbox[(temp>>16)&0xFF])<<16)
           | (uint32_t(sbox[(temp>>8)&0xFF])<<8)|sbox[temp&0xFF]; // SubWord
      temp ^= (uint32_t(rcon[i/4]) << 24);
    }
    w[i] = w[i-4] ^ temp;
  }
  return w;
}

static Block bytes_to_state(const Block& b) { // column-major reindex is identity here; kept explicit for clarity
  return b;
}
static uint8_t& S(Block& s, int r, int c) { return s[r + 4*c]; }
static uint8_t  Sc(const Block& s, int r, int c) { return s[r + 4*c]; }

static void sub_bytes(Block& s)     { for (auto& b : s) b = sbox[b]; }
static void inv_sub_bytes(Block& s) { for (auto& b : s) b = inv_sbox[b]; }

static void shift_rows(Block& s) {
  Block t = s;
  for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) S(s,r,c) = Sc(t, r, (c+r)%4);
}
static void inv_shift_rows(Block& s) {
  Block t = s;
  for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) S(s,r,c) = Sc(t, r, (c-r+4)%4);
}

static void mix_columns(Block& s) {
  for (int c = 0; c < 4; c++) {
    uint8_t s0=Sc(s,0,c), s1=Sc(s,1,c), s2=Sc(s,2,c), s3=Sc(s,3,c);
    S(s,0,c) = xtime(s0) ^ (xtime(s1)^s1) ^ s2 ^ s3;
    S(s,1,c) = s0 ^ xtime(s1) ^ (xtime(s2)^s2) ^ s3;
    S(s,2,c) = s0 ^ s1 ^ xtime(s2) ^ (xtime(s3)^s3);
    S(s,3,c) = (xtime(s0)^s0) ^ s1 ^ s2 ^ xtime(s3);
  }
}
static void inv_mix_columns(Block& s) {
  for (int c = 0; c < 4; c++) {
    uint8_t s0=Sc(s,0,c), s1=Sc(s,1,c), s2=Sc(s,2,c), s3=Sc(s,3,c);
    S(s,0,c) = mul14(s0) ^ mul11(s1) ^ mul13(s2) ^ mul9(s3);
    S(s,1,c) = mul9(s0)  ^ mul14(s1) ^ mul11(s2) ^ mul13(s3);
    S(s,2,c) = mul13(s0) ^ mul9(s1)  ^ mul14(s2) ^ mul11(s3);
    S(s,3,c) = mul11(s0) ^ mul13(s1) ^ mul9(s2)  ^ mul14(s3);
  }
}

static void add_round_key(Block& s, const RoundKeys& w, int round) {
  for (int c = 0; c < 4; c++) {
    uint32_t word = w[4*round + c];
    S(s,0,c) ^= (word>>24)&0xFF; S(s,1,c) ^= (word>>16)&0xFF;
    S(s,2,c) ^= (word>>8)&0xFF;  S(s,3,c) ^= word&0xFF;
  }
}

static Block encrypt(const Block& pt, const Block& key) {
  RoundKeys w = key_expansion(key);
  Block s = bytes_to_state(pt);
  add_round_key(s, w, 0);
  for (int round = 1; round <= 9; round++) {
    sub_bytes(s); shift_rows(s); mix_columns(s); add_round_key(s, w, round);
  }
  sub_bytes(s); shift_rows(s); add_round_key(s, w, 10);
  return s;
}

static Block decrypt(const Block& ct, const Block& key) {
  RoundKeys w = key_expansion(key);
  Block s = bytes_to_state(ct);
  add_round_key(s, w, 10);
  for (int round = 9; round >= 1; round--) {
    inv_shift_rows(s); inv_sub_bytes(s); add_round_key(s, w, round); inv_mix_columns(s);
  }
  inv_shift_rows(s); inv_sub_bytes(s); add_round_key(s, w, 0);
  return s;
}

} // namespace aes_ref

// ---------------------------------------------------------------------
static void unhex16(const char* s, uint8_t b[16]) {
  for (int i = 0; i < 16; i++) { unsigned v; sscanf(s + i*2, "%2x", &v); b[i] = (uint8_t)v; }
}
static uint32_t word_at(const uint8_t b[16], int w) {
  int base = w * 4;
  return (uint32_t(b[base]) << 24) | (uint32_t(b[base+1]) << 16) | (uint32_t(b[base+2]) << 8) | b[base+3];
}

int main(int argc, char** argv) {
  aes_ref::init_tables();

  // ---- sanity: the from-scratch C++ reference model itself must match
  // the published FIPS-197 vectors before it's trusted as the oracle ----
  {
    aes_ref::Block key, pt, ct_expected;
    unhex16("2b7e151628aed2a6abf7158809cf4f3c", key.data());
    unhex16("3243f6a8885a308d313198a2e0370734", pt.data());
    unhex16("3925841d02dc09fbdc118597196a0b32", ct_expected.data());
    auto ct = aes_ref::encrypt(pt, key);
    if (ct != ct_expected) { printf("FAIL: C++ reference model itself doesn't match FIPS-197 App.B -- aborting\n"); return 1; }
    auto pt2 = aes_ref::decrypt(ct, key);
    if (pt2 != pt) { printf("FAIL: C++ reference model decrypt round-trip failed -- aborting\n"); return 1; }
    printf("C++ reference model verified against FIPS-197 App.B before use as the differential oracle\n");
  }

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

  uint8_t resp;
  auto rtl_run = [&](const uint8_t key[16], const uint8_t in[16], int encdec, uint8_t out[16]) -> bool {
    for (int w = 0; w < 4; w++) bfm.write(0x10 + 4*w, word_at(key, w), 0xF, &resp);
    for (int w = 0; w < 4; w++) bfm.write(0x20 + 4*w, word_at(in, w), 0xF, &resp);
    bfm.write(0x0, 0x1 | (encdec << 1), 0xF, &resp);
    uint32_t rd;
    bool done = false;
    for (int i = 0; i < 400 && !done; i++) { bfm.read(0x4, &rd, &resp); done = rd & 0x2; }
    if (!done) return false;
    uint32_t w0, w1, w2, w3;
    bfm.read(0x30, &w0, &resp); bfm.read(0x34, &w1, &resp);
    bfm.read(0x38, &w2, &resp); bfm.read(0x3C, &w3, &resp);
    bfm.write(0x4, 0x2, 0xF, &resp); // clear DONE
    uint32_t words[4] = {w0, w1, w2, w3};
    for (int w = 0; w < 4; w++) {
      out[4*w+0] = (words[w]>>24)&0xFF; out[4*w+1] = (words[w]>>16)&0xFF;
      out[4*w+2] = (words[w]>>8)&0xFF;  out[4*w+3] = words[w]&0xFF;
    }
    return true;
  };

  std::mt19937 rng(0xA5A5A5A5u);
  std::uniform_int_distribution<int> byte_dist(0, 255);

  const int N = 500;
  int fail_count = 0;
  for (int iter = 0; iter < N; iter++) {
    uint8_t key[16], pt[16];
    for (int i = 0; i < 16; i++) { key[i] = (uint8_t)byte_dist(rng); pt[i] = (uint8_t)byte_dist(rng); }

    aes_ref::Block ref_key, ref_pt;
    memcpy(ref_key.data(), key, 16);
    memcpy(ref_pt.data(), pt, 16);
    auto ref_ct = aes_ref::encrypt(ref_pt, ref_key);

    uint8_t rtl_ct[16];
    if (!rtl_run(key, pt, 0, rtl_ct)) { printf("FAIL: iter %d RTL encrypt timed out\n", iter); fail_count++; continue; }
    if (memcmp(rtl_ct, ref_ct.data(), 16) != 0) {
      printf("FAIL: iter %d encrypt mismatch between RTL and C++ reference model\n", iter);
      fail_count++;
    }

    uint8_t rtl_pt2[16];
    if (!rtl_run(key, rtl_ct, 1, rtl_pt2)) { printf("FAIL: iter %d RTL decrypt timed out\n", iter); fail_count++; continue; }
    if (memcmp(rtl_pt2, pt, 16) != 0) {
      printf("FAIL: iter %d RTL decrypt(RTL encrypt(pt)) != pt\n", iter);
      fail_count++;
    }
  }

  delete dut;
  delete ctx;

  if (fail_count) { printf("FAIL: %d/%d iteration(s) failed\n", fail_count, N); return 1; }
  printf("PASS: aes differential test (%d random plaintext/key pairs, RTL vs from-scratch "
         "C++ reference model, encrypt match + decrypt round-trip) all green\n", N);
  return 0;
}

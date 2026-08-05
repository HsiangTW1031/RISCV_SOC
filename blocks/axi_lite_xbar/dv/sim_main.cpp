// Validates axi_lite_xbar's address decode + channel routing against three
// fake_axi_lite_slave stand-ins (see xbar_testtop.v), using the same
// axi_lite_bfm.h already proven against a single fake slave. Real ROM/RAM/
// UART RTL isn't needed yet to prove the crossbar's routing logic correct.
#include "Vxbar_testtop.h"
#include "verilated.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif
#include "axi_lite_bfm.h"
#include <cstdio>

static const uint8_t RESP_OKAY   = 0x0;
static const uint8_t RESP_SLVERR = 0x2;
static const uint8_t RESP_DECERR = 0x3;

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vxbar_testtop* dut = new Vxbar_testtop{ctx};

  AxiLiteSignals sig;
  sig.awvalid = &dut->s0_awvalid; sig.awready = &dut->s0_awready; sig.awaddr = &dut->s0_awaddr;
  sig.wvalid  = &dut->s0_wvalid;  sig.wready  = &dut->s0_wready;  sig.wdata  = &dut->s0_wdata;  sig.wstrb = &dut->s0_wstrb;
  sig.bvalid  = &dut->s0_bvalid;  sig.bready  = &dut->s0_bready;  sig.bresp  = &dut->s0_bresp;
  sig.arvalid = &dut->s0_arvalid; sig.arready = &dut->s0_arready; sig.araddr = &dut->s0_araddr;
  sig.rvalid  = &dut->s0_rvalid;  sig.rready  = &dut->s0_rready;  sig.rdata  = &dut->s0_rdata;  sig.rresp = &dut->s0_rresp;

  dut->clk = 0;
  dut->s1_awvalid = 0; dut->s1_wvalid = 0; dut->s1_bready = 0; dut->s1_arvalid = 0; dut->s1_rready = 0;
  // decerr_irq is a one-cycle-pulse registered signal (stable for a full
  // clock period once asserted), so sampling it once per rising edge --
  // not once per half-cycle call -- counts each pulse exactly once.
  int decerr_irq_pulses = 0;
  auto tick_half = [&]() {
    dut->clk = !dut->clk;
    dut->eval();
    if (dut->clk == 1 && dut->decerr_irq) decerr_irq_pulses++;
  };
  AxiLiteBfm bfm(sig, tick_half);

  dut->resetn = 0;
  bfm.clock(); bfm.clock();
  dut->resetn = 1;
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

  // ---- 4. Timer region (0x4000_0000) ----
  ok = bfm.write(0x40000000, 0x11110004, 0xF, &resp);
  check("write Timer 0x4000_0000 ok", ok && resp == RESP_OKAY);
  ok = bfm.read(0x40000000, &rd, &resp);
  check("read Timer 0x4000_0000 data", ok && rd == 0x11110004);

  // ---- 5. Watchdog region (0x4000_1000) ----
  ok = bfm.write(0x40001000, 0x22220005, 0xF, &resp);
  check("write WDT 0x4000_1000 ok", ok && resp == RESP_OKAY);
  ok = bfm.read(0x40001000, &rd, &resp);
  check("read WDT 0x4000_1000 data", ok && rd == 0x22220005);

  // ---- 6. I2C region (0x4000_3000) ----
  ok = bfm.write(0x40003000, 0x33330006, 0xF, &resp);
  check("write I2C 0x4000_3000 ok", ok && resp == RESP_OKAY);
  ok = bfm.read(0x40003000, &rd, &resp);
  check("read I2C 0x4000_3000 data", ok && rd == 0x33330006);

  // ---- 7. SPI region (0x4000_4000) ----
  ok = bfm.write(0x40004000, 0x44440007, 0xF, &resp);
  check("write SPI 0x4000_4000 ok", ok && resp == RESP_OKAY);
  ok = bfm.read(0x40004000, &rd, &resp);
  check("read SPI 0x4000_4000 data", ok && rd == 0x44440007);

  // ---- 8. AES region (0x4000_5000) ----
  ok = bfm.write(0x40005000, 0x55550008, 0xF, &resp);
  check("write AES 0x4000_5000 ok", ok && resp == RESP_OKAY);
  ok = bfm.read(0x40005000, &rd, &resp);
  check("read AES 0x4000_5000 data", ok && rd == 0x55550008);

  // ---- 8b. DMA region (0x4000_6000, Phase 6) ----
  ok = bfm.write(0x40006000, 0x66660009, 0xF, &resp);
  check("write DMA 0x4000_6000 ok", ok && resp == RESP_OKAY);
  ok = bfm.read(0x40006000, &rd, &resp);
  check("read DMA 0x4000_6000 data", ok && rd == 0x66660009);

  // ---- 9. cross-region isolation: ROM word 0 unaffected by other writes ----
  ok = bfm.read(0x00000000, &rd, &resp);
  check("ROM 0x0 unaffected by RAM/Timer/WDT/UART/I2C/SPI/AES/DMA writes", ok && rd == 0xAAAA0001);

  // ---- 10. unmapped address -> DECERR, no slave touched (v2.2.0: this
  // was SLVERR before -- see rtl/include/axi_lite.vh's header for why
  // DECERR is the spec-correct code for "no slave exists here" as
  // opposed to "a real slave reported its own error"). Each miss should
  // also latch its address into the crossbar's diagnostic CSR and pulse
  // decerr_irq exactly once (see axi_lite_xbar.v's header comment).
  int irq0 = decerr_irq_pulses;
  ok = bfm.write(0x50000000, 0xDEADDEAD, 0xF, &resp);
  check("write unmapped completes (crossbar self-answers)", ok);
  check("write unmapped resp DECERR", resp == RESP_DECERR);
  check("write unmapped pulses decerr_irq exactly once", decerr_irq_pulses - irq0 == 1);

  irq0 = decerr_irq_pulses;
  ok = bfm.read(0x50000000, &rd, &resp);
  check("read unmapped completes", ok);
  check("read unmapped resp DECERR", resp == RESP_DECERR);
  check("read unmapped pulses decerr_irq exactly once", decerr_irq_pulses - irq0 == 1);

  // ---- 10b. diagnostic CSR readback (v2.2.0): confirm the two misses
  // above each landed in the right register, before anything else
  // overwrites them ----
  ok = bfm.read(0x40007000, &rd, &resp);
  check("read LAST_DECERR_WADDR completes", ok);
  check("read LAST_DECERR_WADDR resp OKAY (this address IS mapped)", resp == RESP_OKAY);
  check("LAST_DECERR_WADDR holds the write-miss address", rd == 0x50000000);

  ok = bfm.read(0x40007004, &rd, &resp);
  check("read LAST_DECERR_RADDR completes", ok);
  check("read LAST_DECERR_RADDR resp OKAY", resp == RESP_OKAY);
  check("LAST_DECERR_RADDR holds the read-miss address", rd == 0x50000000);
  // reading the CSR window itself must not be mistaken for a fresh miss.
  check("reading the CSR window doesn't itself pulse decerr_irq",
        decerr_irq_pulses - irq0 == 1); // still just the read-miss above

  // ---- 10c. writes to the CSR window are rejected (it's real, mapped,
  // read-only address space -- SLVERR, not DECERR, same distinction as
  // boot_rom rejecting writes) ----
  irq0 = decerr_irq_pulses;
  ok = bfm.write(0x40007000, 0xFFFFFFFF, 0xF, &resp);
  check("write to CSR window completes", ok);
  check("write to CSR window resp SLVERR (mapped, but read-only)", resp == RESP_SLVERR);
  check("write to CSR window doesn't pulse decerr_irq (not a decode miss)",
        decerr_irq_pulses - irq0 == 0);
  ok = bfm.read(0x40007000, &rd, &resp);
  check("CSR window write was rejected, not silently applied", ok && rd == 0x50000000);

  // a peripheral sub-address beyond DMA that's still genuinely unmapped —
  // expected to DECERR (all 9 real peripheral slots + the CSR window are
  // wired up now; this probe deliberately avoids 0x4000_7xxx, which is
  // the CSR window since v2.2.0, not unmapped anymore).
  irq0 = decerr_irq_pulses;
  ok = bfm.read(0x40008000, &rd, &resp);
  check("read genuinely-unmapped peripheral addr completes", ok);
  check("read genuinely-unmapped peripheral addr resp DECERR", resp == RESP_DECERR);
  check("that miss also pulses decerr_irq", decerr_irq_pulses - irq0 == 1);
  ok = bfm.read(0x40007004, &rd, &resp);
  check("LAST_DECERR_RADDR now reflects the newest read miss", ok && rd == 0x40008000);

  // confirm the unmapped accesses didn't corrupt real slave state.
  ok = bfm.read(0x10000000, &rd, &resp);
  check("RAM 0x1000_0000 unaffected by unmapped access", ok && rd == 0xBBBB0002);
  ok = bfm.read(0x40000000, &rd, &resp);
  check("Timer unaffected by unmapped access", ok && rd == 0x11110004);

  // ---- 11. 2-master arbitration: simultaneous write contention ----
  // Drives s0 (CPU) and s1 (JTAG) raw signals directly (not through the
  // BFM, which only knows about one master) to genuinely contend for the
  // crossbar on the same cycle, rather than just taking turns sequentially.
  auto clk_edge = [&]() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); };
  {
    dut->s0_awvalid = 1; dut->s0_awaddr = 0x00000000; dut->s0_wvalid = 1; dut->s0_wdata = 0xAAAA1111; dut->s0_wstrb = 0xF; dut->s0_bready = 1;
    dut->s1_awvalid = 1; dut->s1_awaddr = 0x10000000; dut->s1_wvalid = 1; dut->s1_wdata = 0xBBBB2222; dut->s1_wstrb = 0xF; dut->s1_bready = 1;
    dut->eval();
    check("simultaneous write contention: s0 (CPU) wins arbitration (s0_awready asserted)", dut->s0_awready == 1);
    check("simultaneous write contention: s1 (JTAG) does not win this cycle (s1_awready low)", dut->s1_awready == 0);

    int spins = 0;
    while (!dut->s0_bvalid && spins < 200) { clk_edge(); spins++; }
    check("s0's write completes while s1's request just waits", dut->s0_bvalid == 1 && spins < 200);
    clk_edge(); // consume the B handshake
    dut->s0_awvalid = 0; dut->s0_wvalid = 0; // s0 stops requesting

    spins = 0;
    while (!dut->s1_awready && spins < 200) { clk_edge(); spins++; }
    check("s1 (JTAG) gets granted once s0 stops requesting", dut->s1_awready == 1 && spins < 200);

    spins = 0;
    while (!dut->s1_bvalid && spins < 200) { clk_edge(); spins++; }
    check("s1's write completes", dut->s1_bvalid == 1 && spins < 200);
    clk_edge();
    dut->s1_awvalid = 0; dut->s1_wvalid = 0;
  }

  // confirm both writes actually landed correctly (no corruption/deadlock,
  // and s0's write from the contention above didn't get lost or garbled)
  ok = bfm.read(0x00000000, &rd, &resp);
  check("post-arbitration: ROM holds s0's contended write", ok && rd == 0xAAAA1111);
  ok = bfm.read(0x10000000, &rd, &resp);
  check("post-arbitration: RAM holds s1's contended write", ok && rd == 0xBBBB2222);

  // ---- extra data-value diversity for per-slave wdata/rdata mirrors
  // (see docs/coverage_waivers.md section 5) ----
  // Every slave above only ever saw ONE specific 32-bit value, so any bit
  // that happened to be 0 (or 1) in that one value never toggled the
  // other way in the crossbar's own per-slave rdata mirror registers (or
  // s1's wdata mirror, only exercised once above in the arbitration
  // test). Bitwise-complementing every value already used gives maximum
  // bit-flip coverage with the fewest extra transactions -- this isn't
  // testing new routing behavior (already proven above), purely toggle
  // diversity.
  struct { uint32_t addr; uint32_t val; } second_pass[] = {
      {0x40000000, ~0x11110004u}, // Timer
      {0x40001000, ~0x22220005u}, // WDT
      {0x40002000, ~0xCCCC0003u}, // UART
      {0x40003000, ~0x33330006u}, // I2C
      {0x40004000, ~0x44440007u}, // SPI
      {0x40005000, ~0x55550008u}, // AES
      {0x40006000, ~0x66660009u}, // DMA
  };
  // A 2-value scheme (original V1, then complement V2=~V1) only gives
  // BOTH directions to bits that are 1 in V1 (0->1 arriving at V1, then
  // 1->0 arriving at V2); bits that are 0 in V1 only ever see 0->1
  // (arriving at V2) and never transition back, since the sequence ends
  // there. Writing V1 back a third time completes exactly those bits'
  // missing 1->0 transition -- necessary here since several of the
  // original values (e.g. Timer's 0x11110004) have very few 1-bits, so
  // most of that register's bits would otherwise stay one-directional.
  for (auto& t : second_pass) {
    ok = bfm.write(t.addr, t.val, 0xF, &resp);
    check("second-value write ok (toggle diversity)", ok && resp == RESP_OKAY);
    ok = bfm.read(t.addr, &rd, &resp);
    check("second-value read matches (toggle diversity)", ok && rd == t.val);
    ok = bfm.write(t.addr, ~t.val, 0xF, &resp); // back to the original value
    check("third-value write ok (toggle diversity)", ok && resp == RESP_OKAY);
    ok = bfm.read(t.addr, &rd, &resp);
    check("third-value read matches (toggle diversity)", ok && rd == (~t.val));
  }

  // s1 (JTAG) wdata mirror: only exercised once above (0xBBBB2222) -- one
  // more write through the raw s1 port with a very different value.
  {
    dut->s1_awvalid = 1; dut->s1_awaddr = 0x10000004; dut->s1_wvalid = 1;
    dut->s1_wdata = 0x5555DDDD; dut->s1_wstrb = 0xF; dut->s1_bready = 1;
    int spins = 0;
    while (!dut->s1_bvalid && spins < 200) { clk_edge(); spins++; }
    check("s1 second-value write completes (toggle diversity)", dut->s1_bvalid == 1 && spins < 200);
    clk_edge();
    dut->s1_awvalid = 0; dut->s1_wvalid = 0;
  }

#if VM_COVERAGE
  VerilatedCov::write("coverage.dat");
#endif
  delete dut;
  delete ctx;

  if (fail_count) {
    printf("FAIL: %d check(s) failed\n", fail_count);
    return 1;
  }
  printf("PASS: axi_lite_xbar routing/decode (ROM/RAM/Timer/WDT/UART/I2C/SPI/AES/DMA + DECERR on miss "
         "+ diagnostic CSR/decerr_irq, v2.2.0) + 2-master arbitration (CPU-priority on contention) all green\n");
  return 0;
}

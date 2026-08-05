// Validates i2c_master.v against fake_i2c_slave.v: a write transaction, a
// read transaction, and NACK handling when the addressed slave doesn't
// exist on the bus.
#include "Vi2c_testtop.h"
#include "verilated.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif
#include "axi_lite_bfm.h"
#include <cstdio>

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vi2c_testtop* dut = new Vi2c_testtop{ctx};

  AxiLiteSignals sig;
  sig.awvalid = &dut->s_awvalid; sig.awready = &dut->s_awready; sig.awaddr = &dut->s_awaddr;
  sig.wvalid  = &dut->s_wvalid;  sig.wready  = &dut->s_wready;  sig.wdata  = &dut->s_wdata;  sig.wstrb = &dut->s_wstrb;
  sig.bvalid  = &dut->s_bvalid;  sig.bready  = &dut->s_bready;  sig.bresp  = &dut->s_bresp;
  sig.arvalid = &dut->s_arvalid; sig.arready = &dut->s_arready; sig.araddr = &dut->s_araddr;
  sig.rvalid  = &dut->s_rvalid;  sig.rready  = &dut->s_rready;  sig.rdata  = &dut->s_rdata;  sig.rresp = &dut->s_rresp;

  dut->clk = 0;
  auto tick_half = [&]() { dut->clk = !dut->clk; dut->eval(); };
  AxiLiteBfm bfm(sig, tick_half);

  dut->resetn = 0;
  bfm.clock(); bfm.clock();
  dut->resetn = 1;
  bfm.clock();

  int fail_count = 0;
  auto check = [&](const char* what, bool cond) {
    if (!cond) { printf("FAIL: %s\n", what); fail_count++; }
  };

  uint32_t rd; uint8_t resp;
  const uint8_t SLAVE_ADDR = 0x50;
  dut->slave_addr = SLAVE_ADDR;

  bfm.write(0x14, 2, 0xF, &resp); // REG_DIVIDER, fast sim clock

  auto run_and_wait = [&](uint8_t addr, int rw, uint8_t txdata, int timeout_cycles = 3000) -> bool {
    bfm.write(0x4, addr, 0xF, &resp);   // ADDR
    if (!rw) bfm.write(0x8, txdata, 0xF, &resp); // TXDATA (write transfers only)
    uint32_t ctrl = 0x1 | (rw << 1);
    bfm.write(0x0, ctrl, 0xF, &resp);   // CTRL: START
    for (int i = 0; i < timeout_cycles; i++) {
      bfm.read(0x10, &rd, &resp); // STATUS
      if (rd & 0x2) return true;  // DONE
    }
    return false;
  };

  auto clear_status = [&]() {
    bfm.write(0x10, 0x6, 0xF, &resp); // clear DONE + NACK
  };

  // ---- write transaction ----
  dut->slave_tx_byte = 0x00;
  bool w_done = run_and_wait(SLAVE_ADDR, 0, 0xAB);
  check("write transfer completed", w_done);
  bfm.read(0x10, &rd, &resp);
  check("write transfer: no NACK", (rd & 0x4) == 0);
  check("slave saw the write", dut->slave_got_write == 1);
  check("slave received the correct byte", dut->slave_rx_byte == 0xAB);
  clear_status();

  // ---- read transaction ----
  dut->slave_tx_byte = 0xCD;
  bool r_done = run_and_wait(SLAVE_ADDR, 1, 0x00);
  check("read transfer completed", r_done);
  bfm.read(0x10, &rd, &resp);
  check("read transfer: no NACK", (rd & 0x4) == 0);
  bfm.read(0xC, &rd, &resp); // RXDATA
  check("master received the correct byte", rd == 0xCD);
  check("slave saw the read", dut->slave_got_read == 1);
  clear_status();

  // ---- NACK: address nobody on the bus owns ----
  bool n_done = run_and_wait(SLAVE_ADDR + 1, 0, 0xFF);
  check("NACK'd transfer still completes (clean abort via STOP)", n_done);
  bfm.read(0x10, &rd, &resp);
  check("NACK bit set for unknown address", (rd & 0x4) != 0);
  clear_status();

  // ---- busy/no-queue: a second START while busy is ignored ----
  dut->slave_tx_byte = 0x00;
  bfm.write(0x4, SLAVE_ADDR, 0xF, &resp);
  bfm.write(0x8, 0x11, 0xF, &resp);
  bfm.write(0x0, 0x1, 0xF, &resp); // start first transfer (write)
  bfm.read(0x10, &rd, &resp);
  check("busy shortly after START", (rd & 0x1) != 0);
  bfm.write(0x8, 0x99, 0xF, &resp); // changed mid-flight, should not affect in-flight byte
  bfm.write(0x0, 0x1, 0xF, &resp);  // ignored (still busy)
  bool done2 = false;
  for (int i = 0; i < 3000 && !done2; i++) {
    bfm.read(0x10, &rd, &resp);
    done2 = rd & 0x2;
  }
  check("first transfer completes despite attempted re-start", done2);
  check("slave received the ORIGINAL byte (0x11), not the mid-flight one (0x99)",
        dut->slave_rx_byte == 0x11);

  // ---- divider register: extra bit coverage (see docs/coverage_waivers.md
  // section 5) ----
  // divider_reg is a directly-written register, so writing all-ones then a
  // small value again toggles every one of its bits both directions cheaply
  // (no extra simulation cycles needed). div_cnt only counts while a
  // transfer is actually in flight, so exercising more of ITS bit range
  // needs a real transfer running against a larger divider -- not to
  // completion (that would take as long as the divider itself), just long
  // enough to climb through a wider range than the fast-sim default (2)
  // ever reaches. Nothing checks this transfer's outcome -- it's here
  // purely for toggle diversity, not behavior verification.
  // Also uses a target address that's the bitwise complement of SLAVE_ADDR
  // (within the 7-bit field) instead of SLAVE_ADDR again, so addr_reg's
  // bits get exercised in both directions too -- SLAVE_ADDR and
  // SLAVE_ADDR+1 (used above) are both close together bit-pattern-wise.
  bfm.write(0x14, 0xFFFFFFFF, 0xF, &resp); // REG_DIVIDER: every bit high
  bfm.write(0x4, (~SLAVE_ADDR) & 0x7F, 0xF, &resp); // REG_ADDR: complementary target address
  bfm.write(0x8, 0x5A, 0xF, &resp);
  bfm.write(0x0, 0x1, 0xF, &resp);         // START: div_cnt starts climbing toward this divider
  for (int i = 0; i < 70000; i++) bfm.clock();
  bfm.write(0x14, 2, 0xF, &resp);          // restore the fast-sim default

#if VM_COVERAGE
  VerilatedCov::write("coverage.dat");
#endif
  delete dut;
  delete ctx;

  if (fail_count) { printf("FAIL: %d check(s) failed\n", fail_count); return 1; }
  printf("PASS: i2c_master (write, read, NACK-on-unknown-address, busy/no-queue) all green\n");
  return 0;
}

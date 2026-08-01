// Cycle-based AXI4-Lite master bus-functional model (BFM).
//
// Owns no simulation state itself: the caller supplies pointers to the
// DUT's slave-port signals (see AxiLiteSignals) plus a half-cycle tick
// callback that toggles clk and calls eval()/trace-dump. That keeps this
// BFM independent of which concrete Verilated top-level class it drives —
// it's reused, unmodified, against every block's testbench.
//
// Per the verification strategy this is validated against a trivial
// always-ready fake slave (see fake_axi_lite_slave.v + bfm_selftest_main.cpp)
// BEFORE it's ever pointed at real DUT logic, so a failure there is a BFM
// bug, not a DUT bug.
#pragma once

#include <cstdint>
#include <functional>

struct AxiLiteSignals {
  uint8_t*  awvalid; uint8_t*  awready; uint32_t* awaddr;
  uint8_t*  wvalid;  uint8_t*  wready;  uint32_t* wdata; uint8_t* wstrb;
  uint8_t*  bvalid;  uint8_t*  bready;  uint8_t*  bresp;
  uint8_t*  arvalid; uint8_t*  arready; uint32_t* araddr;
  uint8_t*  rvalid;  uint8_t*  rready;  uint32_t* rdata; uint8_t* rresp;
};

class AxiLiteBfm {
 public:
  AxiLiteBfm(const AxiLiteSignals& sig, std::function<void()> half_cycle_tick)
      : s(sig), tick_half(half_cycle_tick) {
    *s.awvalid = 0; *s.wvalid = 0; *s.bready = 0;
    *s.arvalid = 0; *s.rready = 0;
  }

  // One full clock period. `tick_half` must toggle clk and call eval() (and
  // any trace dump) each time it's invoked; calling it twice here lands back
  // on the same clk polarity we started from.
  void clock() { tick_half(); tick_half(); }

  // Returns true on completion within timeout_cycles, false on timeout.
  // last_resp receives the BRESP value (AXI_RESP_OKAY / AXI_RESP_SLVERR).
  bool write(uint32_t addr, uint32_t data, uint8_t strb = 0xF,
             uint8_t* last_resp = nullptr, int timeout_cycles = 200) {
    *s.awvalid = 1; *s.awaddr = addr;
    *s.wvalid  = 1; *s.wdata  = data; *s.wstrb = strb;
    *s.bready  = 1;

    bool aw_done = false, w_done = false, b_done = false;
    for (int i = 0; i < timeout_cycles && !(aw_done && w_done && b_done); i++) {
      clock();
      if (!aw_done && *s.awready) { *s.awvalid = 0; aw_done = true; }
      if (!w_done  && *s.wready)  { *s.wvalid  = 0; w_done  = true; }
      if (*s.bvalid && *s.bready) {
        if (last_resp) *last_resp = *s.bresp;
        b_done = true;
      }
    }
    *s.bready = 0;
    return aw_done && w_done && b_done;
  }

  bool read(uint32_t addr, uint32_t* out_data, uint8_t* last_resp = nullptr,
            int timeout_cycles = 200) {
    *s.arvalid = 1; *s.araddr = addr;
    *s.rready  = 1;

    bool ar_done = false, r_done = false;
    for (int i = 0; i < timeout_cycles && !(ar_done && r_done); i++) {
      clock();
      if (!ar_done && *s.arready) { *s.arvalid = 0; ar_done = true; }
      if (*s.rvalid && *s.rready) {
        *out_data = *s.rdata;
        if (last_resp) *last_resp = *s.rresp;
        r_done = true;
      }
    }
    *s.rready = 0;
    return ar_done && r_done;
  }

 private:
  AxiLiteSignals s;
  std::function<void()> tick_half;
};

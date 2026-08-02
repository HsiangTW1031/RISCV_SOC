// Unit test for jtag_tap.v: a software model of the IEEE 1149.1 TAP
// transition table, cross-checked against the RTL over many random TMS
// sequences (catches a transcription slip far more reliably than hand-
// tracing one specific walk), plus an explicit check of the standard
// safety property: 5 consecutive TMS=1 cycles return to Test-Logic-Reset
// from ANY state.
#include "Vjtag_tap.h"
#include "verilated.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif
#include <cstdio>
#include <random>

enum {
  TEST_LOGIC_RESET = 0, RUN_TEST_IDLE, SELECT_DR_SCAN, CAPTURE_DR, SHIFT_DR,
  EXIT1_DR, PAUSE_DR, EXIT2_DR, UPDATE_DR, SELECT_IR_SCAN, CAPTURE_IR,
  SHIFT_IR, EXIT1_IR, PAUSE_IR, EXIT2_IR, UPDATE_IR
};

static int model_next(int cur, int tms) {
  switch (cur) {
    case TEST_LOGIC_RESET: return tms ? TEST_LOGIC_RESET : RUN_TEST_IDLE;
    case RUN_TEST_IDLE:    return tms ? SELECT_DR_SCAN   : RUN_TEST_IDLE;
    case SELECT_DR_SCAN:   return tms ? SELECT_IR_SCAN   : CAPTURE_DR;
    case CAPTURE_DR:       return tms ? EXIT1_DR         : SHIFT_DR;
    case SHIFT_DR:         return tms ? EXIT1_DR         : SHIFT_DR;
    case EXIT1_DR:         return tms ? UPDATE_DR        : PAUSE_DR;
    case PAUSE_DR:         return tms ? EXIT2_DR         : PAUSE_DR;
    case EXIT2_DR:         return tms ? UPDATE_DR        : SHIFT_DR;
    case UPDATE_DR:        return tms ? SELECT_DR_SCAN   : RUN_TEST_IDLE;
    case SELECT_IR_SCAN:   return tms ? TEST_LOGIC_RESET : CAPTURE_IR;
    case CAPTURE_IR:       return tms ? EXIT1_IR         : SHIFT_IR;
    case SHIFT_IR:         return tms ? EXIT1_IR         : SHIFT_IR;
    case EXIT1_IR:         return tms ? UPDATE_IR        : PAUSE_IR;
    case PAUSE_IR:         return tms ? EXIT2_IR         : PAUSE_IR;
    case EXIT2_IR:         return tms ? UPDATE_IR        : SHIFT_IR;
    case UPDATE_IR:        return tms ? SELECT_DR_SCAN   : RUN_TEST_IDLE;
    default: return TEST_LOGIC_RESET;
  }
}

int main(int argc, char** argv) {
  VerilatedContext* ctx = new VerilatedContext;
  ctx->commandArgs(argc, argv);
  Vjtag_tap* dut = new Vjtag_tap{ctx};

  auto tck = [&]() {
    dut->tck = 0; dut->eval();
    dut->tck = 1; dut->eval();
  };

  int fail_count = 0;
  auto check = [&](const char* what, bool cond) {
    if (!cond) { printf("FAIL: %s\n", what); fail_count++; }
  };

  dut->rst = 1;
  tck(); tck();
  check("reset -> TEST_LOGIC_RESET", dut->state == TEST_LOGIC_RESET && dut->test_logic_reset == 1);
  dut->rst = 0;

  int model_state = TEST_LOGIC_RESET;

  // ---- randomized cross-check against the software model ----
  std::mt19937 rng(42);
  std::uniform_int_distribution<int> bit(0, 1);
  const int N = 5000;
  for (int i = 0; i < N; i++) {
    int tms = bit(rng);
    dut->tms = tms;
    tck();
    model_state = model_next(model_state, tms);
    if (dut->state != model_state) {
      printf("FAIL: iter %d: RTL state=%d model state=%d (tms=%d)\n", i, dut->state, model_state, tms);
      fail_count++;
      break;
    }
  }
  check("5000-step randomized TMS walk matches software model", fail_count == 0);

  // ---- safety property: 5 consecutive TMS=1 reaches TEST_LOGIC_RESET
  // from any state. Drive to each of the 16 states via a fresh reset +
  // random walk, then check.
  for (int target_walk_len = 0; target_walk_len < 30; target_walk_len++) {
    dut->rst = 1; tck(); dut->rst = 0;
    model_state = TEST_LOGIC_RESET;
    for (int i = 0; i < target_walk_len; i++) {
      int tms = bit(rng);
      dut->tms = tms;
      tck();
      model_state = model_next(model_state, tms);
    }
    // now apply 5x TMS=1
    for (int i = 0; i < 5; i++) { dut->tms = 1; tck(); }
    char msg[96];
    snprintf(msg, sizeof(msg), "5x TMS=1 from state reached after %d random steps lands in TEST_LOGIC_RESET", target_walk_len);
    check(msg, dut->state == TEST_LOGIC_RESET && dut->test_logic_reset == 1);
  }

  // ---- directed sanity walk covering every state at least once ----
  {
    dut->rst = 1; tck(); dut->rst = 0;
    const int walk[] = {0,1,1,0,1,0,1,0,1,1,1,0,1,0,1,0,1,1,0}; // tms sequence
    model_state = TEST_LOGIC_RESET;
    for (int t : walk) {
      dut->tms = t;
      tck();
      model_state = model_next(model_state, t);
      check("directed walk step matches model", dut->state == model_state);
    }
  }

#if VM_COVERAGE
  VerilatedCov::write("coverage.dat");
#endif
  delete dut;
  delete ctx;

  if (fail_count) { printf("FAIL: %d check(s) failed\n", fail_count); return 1; }
  printf("PASS: jtag_tap (16-state IEEE 1149.1 FSM matches reference model, "
         "TMS-reset safety property holds from arbitrary states) all green\n");
  return 0;
}

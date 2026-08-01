// IEEE 1149.1 JTAG TAP (Test Access Port) controller -- the standard
// 16-state finite state machine, unmodified from the spec. Clocked by its
// own `tck` input: this is a genuinely separate clock domain from the
// system clock (`clk` used everywhere else in this project), matching how
// real JTAG hardware works (an external probe drives TCK/TMS/TDI
// asynchronously to whatever clock the chip itself runs on). Anything
// downstream that needs to act on TAP state changes in the system clock
// domain (see jtag_axi_bridge.v) must synchronize across that boundary
// itself -- this module only implements the FSM and TDO shift-register
// plumbing, all still in the tck domain.
//
// `rst` here is a synchronous-to-tck, active-high reset -- deliberately
// NOT the traditional active-low TRST# pin, to stay consistent with this
// project's one reset convention everywhere else. This is a reasonable
// deviation: TRST# is an *optional* pin in IEEE 1149.1 (many real JTAG
// implementations omit it entirely) precisely because the TAP always has
// a reliable, mandatory reset path anyway -- 5 consecutive TMS=1 cycles
// return the FSM to Test-Logic-Reset from ANY state (proven by the
// transition table below: Test-Logic-Reset and Run-Test/Idle are always
// at most a few TMS=1 hops from anywhere, and the FSM has no state that
// can indefinitely dodge TMS=1). Real debug probes rely on this "TMS reset"
// path as the normal way to force a known state, `rst` here is just for
// simulation/power-on convenience.
module jtag_tap (
    input  wire tck,
    input  wire rst,
    input  wire tms,

    output wire [3:0] state,
    output wire       test_logic_reset,
    output wire       run_test_idle,
    output wire       select_dr_scan,
    output wire       capture_dr,
    output wire       shift_dr,
    output wire       exit1_dr,
    output wire       pause_dr,
    output wire       exit2_dr,
    output wire       update_dr,
    output wire       select_ir_scan,
    output wire       capture_ir,
    output wire       shift_ir,
    output wire       exit1_ir,
    output wire       pause_ir,
    output wire       exit2_ir,
    output wire       update_ir
);
  localparam TEST_LOGIC_RESET = 4'd0;
  localparam RUN_TEST_IDLE    = 4'd1;
  localparam SELECT_DR_SCAN   = 4'd2;
  localparam CAPTURE_DR       = 4'd3;
  localparam SHIFT_DR         = 4'd4;
  localparam EXIT1_DR         = 4'd5;
  localparam PAUSE_DR         = 4'd6;
  localparam EXIT2_DR         = 4'd7;
  localparam UPDATE_DR        = 4'd8;
  localparam SELECT_IR_SCAN   = 4'd9;
  localparam CAPTURE_IR       = 4'd10;
  localparam SHIFT_IR         = 4'd11;
  localparam EXIT1_IR         = 4'd12;
  localparam PAUSE_IR         = 4'd13;
  localparam EXIT2_IR         = 4'd14;
  localparam UPDATE_IR        = 4'd15;

  reg [3:0] state_r;
  assign state = state_r;

  function [3:0] next_state;
    input [3:0] cur;
    input       tms_in;
    begin
      case (cur)
        TEST_LOGIC_RESET: next_state = tms_in ? TEST_LOGIC_RESET : RUN_TEST_IDLE;
        RUN_TEST_IDLE:    next_state = tms_in ? SELECT_DR_SCAN   : RUN_TEST_IDLE;
        SELECT_DR_SCAN:   next_state = tms_in ? SELECT_IR_SCAN   : CAPTURE_DR;
        CAPTURE_DR:       next_state = tms_in ? EXIT1_DR         : SHIFT_DR;
        SHIFT_DR:         next_state = tms_in ? EXIT1_DR         : SHIFT_DR;
        EXIT1_DR:         next_state = tms_in ? UPDATE_DR        : PAUSE_DR;
        PAUSE_DR:         next_state = tms_in ? EXIT2_DR         : PAUSE_DR;
        EXIT2_DR:         next_state = tms_in ? UPDATE_DR        : SHIFT_DR;
        UPDATE_DR:        next_state = tms_in ? SELECT_DR_SCAN   : RUN_TEST_IDLE;
        SELECT_IR_SCAN:   next_state = tms_in ? TEST_LOGIC_RESET : CAPTURE_IR;
        CAPTURE_IR:       next_state = tms_in ? EXIT1_IR         : SHIFT_IR;
        SHIFT_IR:         next_state = tms_in ? EXIT1_IR         : SHIFT_IR;
        EXIT1_IR:         next_state = tms_in ? UPDATE_IR        : PAUSE_IR;
        PAUSE_IR:         next_state = tms_in ? EXIT2_IR         : PAUSE_IR;
        EXIT2_IR:         next_state = tms_in ? UPDATE_IR        : SHIFT_IR;
        UPDATE_IR:        next_state = tms_in ? SELECT_DR_SCAN   : RUN_TEST_IDLE;
        default:          next_state = TEST_LOGIC_RESET;
      endcase
    end
  endfunction

  always @(posedge tck) begin
    if (rst) state_r <= TEST_LOGIC_RESET;
    else     state_r <= next_state(state_r, tms);
  end

  assign test_logic_reset = (state_r == TEST_LOGIC_RESET);
  assign run_test_idle    = (state_r == RUN_TEST_IDLE);
  assign select_dr_scan   = (state_r == SELECT_DR_SCAN);
  assign capture_dr       = (state_r == CAPTURE_DR);
  assign shift_dr         = (state_r == SHIFT_DR);
  assign exit1_dr         = (state_r == EXIT1_DR);
  assign pause_dr         = (state_r == PAUSE_DR);
  assign exit2_dr         = (state_r == EXIT2_DR);
  assign update_dr        = (state_r == UPDATE_DR);
  assign select_ir_scan   = (state_r == SELECT_IR_SCAN);
  assign capture_ir       = (state_r == CAPTURE_IR);
  assign shift_ir         = (state_r == SHIFT_IR);
  assign exit1_ir         = (state_r == EXIT1_IR);
  assign pause_ir         = (state_r == PAUSE_IR);
  assign exit2_ir         = (state_r == EXIT2_IR);
  assign update_ir        = (state_r == UPDATE_IR);
endmodule

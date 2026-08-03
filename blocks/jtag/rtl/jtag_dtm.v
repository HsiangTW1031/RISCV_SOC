// JTAG DTM (Debug Transport Module) -- sits on top of jtag_tap.v, still
// entirely in the tck clock domain. Implements the instruction register,
// the per-instruction data shift registers, and the TDO mux. This is the
// "protocol" layer; it knows nothing about AXI or the system clock domain
// -- it only exposes a handful of tck-domain registers/pulses that
// jtag_axi_bridge.v (system-clock domain) synchronizes across.
//
// Instructions (IR_WIDTH=4 bits; any code not listed below behaves as
// BYPASS, the standard IEEE 1149.1 recommendation for unimplemented
// instructions):
//   4'h1  IDCODE    - DR=32'b, fixed ID, LSB always 1 (see below)
//   4'h2  AXI_ADDR  - DR=32'b, the address for the next bridged AXI txn
//   4'h3  AXI_DATA  - DR=32'b, write data going in / read data coming back
//   4'h4  AXI_CTRL  - DR=32'b: bit[0]=START (write to trigger a txn),
//                     bit[1]=RW (0=write,1=read); on Capture-DR this
//                     instead loads bit[0]=BUSY, bit[1]=RESP_OK (both
//                     read-only status, synchronized from the bridge)
//   4'hF  BYPASS    - DR=1 bit, plain TDI->TDO passthrough (1 tck latency)
//
// Typical sequence for a bridged AXI write: shift IR=AXI_ADDR, shift DR=
// address; shift IR=AXI_DATA, shift DR=write data; shift IR=AXI_CTRL,
// shift DR={rw=0,start=1}; poll AXI_CTRL's DR (Capture-DR) until BUSY=0.
// For a read, same but rw=1, then shift IR=AXI_DATA and Capture-DR+Shift-DR
// to read the result back out via TDO.
//
// IDCODE's LSB is defined by IEEE 1149.1 to always be 1, and BYPASS's
// single bit is always captured as 0 -- this is how real JTAG chain
// scanners auto-detect device boundaries without needing per-device
// configuration.
module jtag_dtm (
    input  wire tck,
    input  wire resetn,
    input  wire tms,
    input  wire tdi,
    output wire tdo,

    // synchronized-in from jtag_axi_bridge.v (already in the tck domain)
    input  wire        bridge_busy_tck,
    input  wire        bridge_resp_ok_tck,
    input  wire [31:0] bridge_rdata_tck,

    // synchronized-out to jtag_axi_bridge.v (still tck domain; the bridge
    // does its own CDC into the system clock domain)
    output reg         start_pulse_tck,
    output reg         rw_tck,
    output wire [31:0] addr_tck,
    output wire [31:0] wdata_tck
);
  localparam IR_IDCODE   = 4'h1;
  localparam IR_AXI_ADDR = 4'h2;
  localparam IR_AXI_DATA = 4'h3;
  localparam IR_AXI_CTRL = 4'h4;
  localparam IR_BYPASS   = 4'hF;

  // Manufacturer/part/version fields are illustrative (this isn't a real
  // registered JEDEC ID) -- what matters for the story is the mandatory
  // LSB=1, which is what lets a JTAG chain scanner tell an IDCODE-bearing
  // TAP apart from a BYPASS-only one while walking an unknown chain.
  localparam [31:0] IDCODE_VALUE = {4'h1, 16'hC0DE, 11'h051, 1'b1};

  wire capture_dr, shift_dr, update_dr, capture_ir, shift_ir, update_ir, test_logic_reset;

  jtag_tap u_tap (
      .tck(tck), .resetn(resetn), .tms(tms),
      .state(),
      .test_logic_reset(test_logic_reset),
      .run_test_idle(), .select_dr_scan(), .capture_dr(capture_dr), .shift_dr(shift_dr),
      .exit1_dr(), .pause_dr(), .exit2_dr(), .update_dr(update_dr),
      .select_ir_scan(), .capture_ir(capture_ir), .shift_ir(shift_ir),
      .exit1_ir(), .pause_ir(), .exit2_ir(), .update_ir(update_ir)
  );

  reg [3:0]  ir_shift;
  reg [3:0]  ir_reg;
  reg [31:0] dr_shift;
  reg        bypass_reg;

  reg [31:0] addr_reg;
  reg [31:0] data_reg;
  reg        bridge_busy_prev;

  assign tdo = (ir_reg == IR_BYPASS) ? bypass_reg : dr_shift[0];

  always @(posedge tck) begin
    if (!resetn || test_logic_reset) begin
      ir_reg           <= IR_IDCODE;
      start_pulse_tck  <= 1'b0;
      bridge_busy_prev <= 1'b0;
    end else begin
      start_pulse_tck  <= 1'b0; // default: single-tck-cycle pulse unless re-asserted below
      bridge_busy_prev <= bridge_busy_tck;

      // Latch the bridge's result on the busy-falling EDGE only (not
      // "whenever idle") -- doing this as a level check instead of an edge
      // check would re-latch bridge_rdata_tck every single cycle the
      // bridge sits idle, clobbering a legitimate write to AXI_DATA that's
      // staging the *next* operation before the user gets around to
      // changing RW back to write. Placed textually before the IR/DR
      // block below so an explicit update_dr (a real user action) always
      // wins if both happen to land on the same tck edge.
      if (bridge_busy_prev && !bridge_busy_tck && rw_tck) data_reg <= bridge_rdata_tck;

      // ---- IR shift/update ----
      if (shift_ir) ir_shift <= {tdi, ir_shift[3:1]};
      if (capture_ir) ir_shift <= 4'b0101; // IEEE 1149.1: capture a fixed "01" pattern (here widened to fit)
      if (update_ir) ir_reg <= ir_shift;

      // ---- DR shift/capture/update, behavior depends on the current instruction ----
      if (capture_dr) begin
        case (ir_reg)
          IR_IDCODE:   dr_shift <= IDCODE_VALUE;
          IR_AXI_ADDR: dr_shift <= addr_reg;
          IR_AXI_DATA: dr_shift <= data_reg;
          IR_AXI_CTRL: dr_shift <= {30'b0, bridge_resp_ok_tck, bridge_busy_tck};
          default:     bypass_reg <= 1'b0;
        endcase
      end else if (shift_dr) begin
        if (ir_reg == IR_BYPASS) bypass_reg <= tdi;
        else                      dr_shift   <= {tdi, dr_shift[31:1]};
      end else if (update_dr) begin
        case (ir_reg)
          IR_AXI_ADDR: addr_reg <= dr_shift;
          IR_AXI_DATA: data_reg <= dr_shift;
          IR_AXI_CTRL: begin
            rw_tck          <= dr_shift[1];
            start_pulse_tck <= dr_shift[0];
          end
          default: ; // IDCODE/BYPASS: read-only, nothing to latch
        endcase
      end
    end
  end

  assign addr_tck  = addr_reg;
  assign wdata_tck = data_reg;
endmodule

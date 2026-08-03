`include "axi_lite.vh"

// Watchdog — down-counter that must be periodically "kicked" (fed) or it
// first raises a WARNING interrupt at WARN_MARGIN cycles before timeout,
// then asserts a reset-request output when it actually reaches zero.
// Register map (byte offsets):
//   0x0 CTRL    (r/w) — bit[0] EN. Writing EN=1 also (re)loads the counter
//                       from TIMEOUT, same "enable = start" convention as
//                       timer.v.
//   0x4 TIMEOUT (r/w) — reload value.
//   0x8 KICK    (w)   — write any value: reloads the counter from TIMEOUT
//                       and clears both STATUS bits. Read returns 0.
//   0xC STATUS  (r/w) — bit[0] WARNING (sticky, write-1-to-clear); bit[1]
//                       RESET_REQ (read-only mirror of `wdog_reset_req` —
//                       deliberately NOT clearable by a plain STATUS
//                       write, only by KICK/restart, since a real reset
//                       request shouldn't be dismissable by clearing a
//                       status bit alone).
//
// `irq` is a single-cycle PULSE on the exact WARN_MARGIN cycle, NOT tied
// to the sticky STATUS.WARNING bit — see timer.v's header comment for why
// a level-held irq line paired with PicoRV32's LATCHED_IRQ mechanism
// guarantees a spurious second entry once the handler unmasks. WARNING
// only ever needs to interrupt once per occurrence, so it pulses.
// `wdog_reset_req` stays a genuine level signal (correct for anything
// meant to hold a downstream reset generator asserted), matching
// STATUS.RESET_REQ.
module watchdog #(
    parameter WARN_MARGIN = 4  // cycles remaining when WARNING first fires
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire        s_awvalid, output wire s_awready, input wire [31:0] s_awaddr,
    input  wire        s_wvalid,  output wire s_wready,  input wire [31:0] s_wdata, input wire [3:0] s_wstrb,
    output reg          s_bvalid,  input wire  s_bready,  output reg [1:0] s_bresp,
    input  wire        s_arvalid, output wire s_arready, input wire [31:0] s_araddr,
    output reg          s_rvalid,  input wire  s_rready,  output reg [31:0] s_rdata, output reg [1:0] s_rresp,

    output wire         irq,
    output wire         wdog_reset_req
);
  localparam REG_CTRL    = 4'h0;
  localparam REG_TIMEOUT = 4'h4;
  localparam REG_KICK    = 4'h8;
  localparam REG_STATUS  = 4'hC;

  reg        ctrl_en;
  reg [31:0] timeout_reg;
  reg [31:0] count;
  reg        status_warning;
  reg        status_reset_req;
  reg        irq_pulse;

  assign irq            = irq_pulse;
  assign wdog_reset_req = status_reset_req;

  assign s_awready = 1'b1;
  assign s_wready  = 1'b1;
  assign s_arready = 1'b1;

  wire [3:0] aw_offset = s_awaddr[3:0];
  wire [3:0] ar_offset = s_araddr[3:0];
  wire       do_write      = s_awvalid && s_wvalid;
  wire       write_ctrl_en = do_write && (aw_offset == REG_CTRL) && s_wdata[0];
  wire       write_kick    = do_write && (aw_offset == REG_KICK);
  wire       restart       = write_ctrl_en || write_kick;

  always @(posedge clk) begin
    if (!resetn) begin
      ctrl_en          <= 1'b0;
      timeout_reg      <= 32'hFFFFFFFF;
      count            <= 32'hFFFFFFFF;
      status_warning   <= 1'b0;
      status_reset_req <= 1'b0;
      irq_pulse        <= 1'b0;
    end else begin
      if (do_write && aw_offset == REG_CTRL)
        ctrl_en <= s_wdata[0];

      if (do_write && aw_offset == REG_TIMEOUT)
        timeout_reg <= s_wdata;

      // ---- count: single writer, explicit priority (restart wins) ----
      if (restart)
        count <= timeout_reg;
      else if (ctrl_en && count != 32'h0)
        count <= count - 32'h1;
      // else: ctrl_en && count==0 -> hold at 0 until kicked/restarted

      // ---- status_warning: set at WARN_MARGIN, cleared by restart or a
      // write-1 ----
      if (restart)
        status_warning <= 1'b0;
      else if (ctrl_en && count == WARN_MARGIN)
        status_warning <= 1'b1;
      else if (do_write && aw_offset == REG_STATUS && s_wdata[0])
        status_warning <= 1'b0;

      // ---- irq_pulse: exactly one cycle wide, same trigger condition as
      // status_warning but never held ----
      irq_pulse <= (!restart && ctrl_en && count == WARN_MARGIN);

      // ---- status_reset_req: set when the counter actually reaches 0,
      // cleared only by restart (see module header comment) ----
      if (restart)
        status_reset_req <= 1'b0;
      else if (ctrl_en && count == 32'h0)
        status_reset_req <= 1'b1;

      // ---- AXI write response ----
      if (do_write) begin
        s_bresp  <= `AXI_RESP_OKAY;
        s_bvalid <= 1'b1;
      end else begin
        s_bvalid <= 1'b0;
      end

      // ---- AXI read ----
      if (s_arvalid) begin
        case (ar_offset)
          REG_CTRL:    s_rdata <= {31'b0, ctrl_en};
          REG_TIMEOUT: s_rdata <= timeout_reg;
          REG_KICK:    s_rdata <= 32'b0;
          REG_STATUS:  s_rdata <= {30'b0, status_reset_req, status_warning};
          default:     s_rdata <= 32'b0;
        endcase
        s_rresp  <= `AXI_RESP_OKAY;
        s_rvalid <= 1'b1;
      end else begin
        s_rvalid <= 1'b0;
      end
    end
  end
endmodule

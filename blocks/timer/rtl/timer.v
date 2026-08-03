`include "axi_lite.vh"

// Timer — down-counter with auto-reload and a sticky compare-match
// interrupt. Register map (byte offsets):
//   0x0 CTRL   (r/w) — bit[0] EN. Writing EN=1 also (re)loads COUNT from
//                      RELOAD, i.e. every enabling write is a restart.
//   0x4 RELOAD (r/w) — value COUNT reloads to, both on (re)start and on
//                      every natural expiry while running.
//   0x8 COUNT  (ro)  — current counter value.
//   0xC STATUS (r/w) — bit[0] EXPIRED, sticky, write-1-to-clear (software-
//                      visible history bit — poll this if you just want to
//                      know "did it fire").
//
// `irq` is a single-cycle PULSE on the exact expiry cycle, deliberately
// NOT tied to the sticky STATUS bit. PicoRV32's LATCHED_IRQ mechanism
// OR's the raw irq input into its internal pending register every single
// cycle regardless of the dynamic irq_mask (maskirq only gates whether a
// pending bit can trigger *entry* into the handler, not whether it keeps
// getting re-latched) — so a LEVEL-held irq output that's still high when
// the handler re-enables interrupts causes a guaranteed spurious second
// entry for the same event, no matter how fast firmware clears the status
// bit. Pulsing for exactly one cycle sidesteps that class of bug entirely:
// the line has already dropped on its own long before the ISR finishes,
// regardless of firmware speed.
module timer (
    input  wire        clk,
    input  wire        resetn,

    input  wire        s_awvalid, output wire s_awready, input wire [31:0] s_awaddr,
    input  wire        s_wvalid,  output wire s_wready,  input wire [31:0] s_wdata, input wire [3:0] s_wstrb,
    output reg          s_bvalid,  input wire  s_bready,  output reg [1:0] s_bresp,
    input  wire        s_arvalid, output wire s_arready, input wire [31:0] s_araddr,
    output reg          s_rvalid,  input wire  s_rready,  output reg [31:0] s_rdata, output reg [1:0] s_rresp,

    output wire         irq
);
  localparam REG_CTRL   = 4'h0;
  localparam REG_RELOAD = 4'h4;
  localparam REG_COUNT  = 4'h8;
  localparam REG_STATUS = 4'hC;

  reg        ctrl_en;
  reg [31:0] reload_reg;
  reg [31:0] count;
  reg        status_expired;
  reg        irq_pulse;

  assign irq = irq_pulse;

  assign s_awready = 1'b1;
  assign s_wready  = 1'b1;
  assign s_arready = 1'b1;

  wire [3:0] aw_offset = s_awaddr[3:0];
  wire [3:0] ar_offset = s_araddr[3:0];
  wire       do_write   = s_awvalid && s_wvalid;
  wire       write_ctrl_en = do_write && (aw_offset == REG_CTRL) && s_wdata[0];

  always @(posedge clk) begin
    if (!resetn) begin
      ctrl_en        <= 1'b0;
      reload_reg     <= 32'hFFFFFFFF;
      count          <= 32'hFFFFFFFF;
      status_expired <= 1'b0;
      irq_pulse      <= 1'b0;
    end else begin
      // ---- ctrl_en: simple register write, no priority conflict ----
      if (do_write && aw_offset == REG_CTRL)
        ctrl_en <= s_wdata[0];

      // ---- reload_reg: simple register write ----
      if (do_write && aw_offset == REG_RELOAD)
        reload_reg <= s_wdata;

      // ---- count: single writer, explicit priority so an enabling write
      // always wins over a same-cycle natural expiry ----
      if (write_ctrl_en)
        count <= reload_reg;
      else if (ctrl_en && count == 32'h0)
        count <= reload_reg;
      else if (ctrl_en)
        count <= count - 32'h1;

      // ---- status_expired: sticky, set on natural expiry, cleared by
      // write-1, with expiry taking priority if both happen the same
      // cycle ----
      if (ctrl_en && count == 32'h0 && !write_ctrl_en)
        status_expired <= 1'b1;
      else if (do_write && aw_offset == REG_STATUS && s_wdata[0])
        status_expired <= 1'b0;

      // ---- irq_pulse: exactly one cycle wide, same trigger condition as
      // status_expired but never held — see module header comment ----
      irq_pulse <= (ctrl_en && count == 32'h0 && !write_ctrl_en);

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
          REG_CTRL:   s_rdata <= {31'b0, ctrl_en};
          REG_RELOAD: s_rdata <= reload_reg;
          REG_COUNT:  s_rdata <= count;
          REG_STATUS: s_rdata <= {31'b0, status_expired};
          default:    s_rdata <= 32'b0;
        endcase
        s_rresp  <= `AXI_RESP_OKAY;
        s_rvalid <= 1'b1;
      end else begin
        s_rvalid <= 1'b0;
      end
    end
  end
endmodule

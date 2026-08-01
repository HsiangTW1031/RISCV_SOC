`include "axi_lite.vh"

// JTAG-to-AXI4-Lite bridge master. This is the ONLY module in the JTAG
// chain that lives in the system clock domain (`clk`) -- it does the
// actual AXI4-Lite mastering, and handles the clock-domain crossing (CDC)
// to/from jtag_dtm.v's tck domain itself, so jtag_dtm.v and jtag_tap.v
// stay entirely tck-domain and don't need to know `clk` exists.
//
// CDC strategy: TWO independent toggle synchronizers, one per direction,
// and BUSY is derived by *comparing* them rather than synchronizing a
// raw level. This distinction matters and was caught by actual
// simulation, not just reasoned about up front: an earlier version of
// this module synchronized `busy` (a clk-domain level, asserted only for
// the ~3 clk cycles an AXI-Lite transaction takes) straight into the tck
// domain with a plain 2-flop synchronizer. That looks textbook-correct
// for a "level" signal, but it quietly assumes the level stays asserted
// long enough to be sampled -- with tck running much slower than clk
// (the realistic case: real JTAG probes often run at a few MHz against a
// multi-hundred-MHz system clock), the entire busy-high window can fall
// *between* two tck edges and never be observed at all, making the tck
// side believe the bridge was never busy and the transaction "completed"
// before the read result even existed.
//
// The fix: don't synchronize busy itself. Each side owns one toggle bit
// that only it ever flips (tck side flips `start_toggle_tck` once per
// START; clk side flips `done_toggle_clk` once per completion). Each
// side double-flops the *other* side's toggle for metastability safety,
// and BUSY is simply "my toggle differs from the other side's last-known
// toggle" -- a level comparison between two registers that each hold
// their value indefinitely until the next event, so neither side can
// miss it regardless of how large the clock-period ratio is in either
// direction.
//
// RDATA is a multi-bit bus, synchronized with a plain 2-flop-per-bit
// register -- safe here because the tck side only ever reads it after
// busy_tck has already fallen (i.e. after done_toggle_clk's flip has
// already been observed), by which point rdata has been stable in the
// clk domain for a while: the standard "quasi-static bus, gated by an
// already-synchronized control signal" pattern.
module jtag_axi_bridge (
    input  wire clk,
    input  wire rst,
    input  wire tck,
    input  wire tck_rst,

    // ---- tck-domain side (from jtag_dtm.v) ----
    input  wire        start_pulse_tck,
    input  wire        rw_tck,
    input  wire [31:0] addr_tck,
    input  wire [31:0] wdata_tck,
    output wire        busy_tck,
    output wire        resp_ok_tck,
    output wire [31:0] rdata_tck,

    // ---- system-clock-domain AXI4-Lite master port (to the crossbar) ----
    output wire         m_awvalid, input wire m_awready, output wire [31:0] m_awaddr,
    output wire         m_wvalid,  input wire m_wready,  output wire [31:0] m_wdata, output wire [3:0] m_wstrb,
    input  wire         m_bvalid,  output wire m_bready,  input wire [1:0]  m_bresp,
    output wire         m_arvalid, input wire m_arready, output wire [31:0] m_araddr,
    input  wire         m_rvalid,  output wire m_rready,  input wire [31:0] m_rdata, input wire [1:0] m_rresp
);
  // ==== tck -> clk: toggle synchronizer for the START event ====
  reg start_toggle_tck;
  always @(posedge tck) begin
    if (tck_rst) start_toggle_tck <= 1'b0;
    else if (start_pulse_tck) start_toggle_tck <= ~start_toggle_tck;
  end

  reg start_toggle_sync1, start_toggle_sync2, start_toggle_sync2_d;
  always @(posedge clk) begin
    if (rst) begin
      start_toggle_sync1 <= 1'b0; start_toggle_sync2 <= 1'b0; start_toggle_sync2_d <= 1'b0;
    end else begin
      start_toggle_sync1   <= start_toggle_tck;
      start_toggle_sync2   <= start_toggle_sync1;
      start_toggle_sync2_d <= start_toggle_sync2;
    end
  end
  wire start_pulse_clk = start_toggle_sync2 ^ start_toggle_sync2_d;

  // ==== clk-domain AXI4-Lite master FSM ====
  localparam IDLE   = 3'd0;
  localparam WR_GO  = 3'd1; // driving AW/W until both accepted
  localparam WR_B   = 3'd2; // waiting for BVALID
  localparam RD_GO  = 3'd3; // driving AR until accepted
  localparam RD_R   = 3'd4; // waiting for RVALID

  reg [2:0]  state;
  reg        rw_reg;
  reg [31:0] addr_reg, wdata_reg, rdata_reg;
  reg        aw_done, w_done;
  reg        resp_ok;
  reg        done_toggle_clk;

  assign m_awvalid = (state == WR_GO) && !aw_done;
  assign m_awaddr  = addr_reg;
  assign m_wvalid  = (state == WR_GO) && !w_done;
  assign m_wdata   = wdata_reg;
  assign m_wstrb   = 4'hF;
  assign m_bready  = (state == WR_B);
  assign m_arvalid = (state == RD_GO);
  assign m_araddr  = addr_reg;
  assign m_rready  = (state == RD_R);

  always @(posedge clk) begin
    if (rst) begin
      state           <= IDLE;
      done_toggle_clk <= 1'b0;
    end else begin
      case (state)
        IDLE: begin
          if (start_pulse_clk) begin
            rw_reg    <= rw_tck;
            addr_reg  <= addr_tck;
            wdata_reg <= wdata_tck;
            aw_done   <= 1'b0;
            w_done    <= 1'b0;
            state     <= rw_tck ? RD_GO : WR_GO;
          end
        end

        WR_GO: begin
          if (!aw_done && m_awready) aw_done <= 1'b1;
          if (!w_done  && m_wready)  w_done  <= 1'b1;
          if ((aw_done || m_awready) && (w_done || m_wready)) state <= WR_B;
        end

        WR_B: begin
          if (m_bvalid) begin
            resp_ok         <= (m_bresp == `AXI_RESP_OKAY);
            done_toggle_clk <= ~done_toggle_clk;
            state           <= IDLE;
          end
        end

        RD_GO: begin
          if (m_arvalid && m_arready) state <= RD_R;
        end

        RD_R: begin
          if (m_rvalid) begin
            rdata_reg       <= m_rdata;
            resp_ok         <= (m_rresp == `AXI_RESP_OKAY);
            done_toggle_clk <= ~done_toggle_clk;
            state           <= IDLE;
          end
        end

        default: state <= IDLE;
      endcase
    end
  end

  // ==== clk -> tck: toggle synchronizer for the DONE event, plus plain
  // 2-flop synchronizers for the (quasi-static once DONE is observed)
  // resp_ok/rdata payload ====
  reg done_toggle_sync1, done_toggle_sync2;
  reg resp_ok_sync1, resp_ok_sync2;
  reg [31:0] rdata_sync1, rdata_sync2;
  always @(posedge tck) begin
    if (tck_rst) begin
      done_toggle_sync1 <= 1'b0; done_toggle_sync2 <= 1'b0;
      resp_ok_sync1 <= 1'b0; resp_ok_sync2 <= 1'b0;
    end else begin
      done_toggle_sync1 <= done_toggle_clk;
      done_toggle_sync2 <= done_toggle_sync1;
      resp_ok_sync1 <= resp_ok;
      resp_ok_sync2 <= resp_ok_sync1;
      rdata_sync1   <= rdata_reg;
      rdata_sync2   <= rdata_sync1;
    end
  end

  // Busy exactly when we've issued a START whose completion hasn't been
  // observed yet -- robust regardless of the tck:clk period ratio, unlike
  // synchronizing the clk-domain `busy` level directly (see header comment).
  assign busy_tck    = (start_toggle_tck != done_toggle_sync2);
  assign resp_ok_tck = resp_ok_sync2;
  assign rdata_tck   = rdata_sync2;
endmodule

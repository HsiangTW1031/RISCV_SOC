// Trivial "always ready" AXI4-Lite slave used only to validate axi_lite_bfm.h
// itself before it's ever pointed at real DUT logic. Not part of the SoC —
// lives in tb/common alongside the BFM, not under blocks/.
module fake_axi_lite_slave (
    input  wire        clk,
    input  wire        rst,

    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_awaddr,

    input  wire        s_wvalid,
    output wire        s_wready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,

    output reg         s_bvalid,
    input  wire        s_bready,
    output wire [1:0]  s_bresp,

    input  wire        s_arvalid,
    output wire        s_arready,
    input  wire [31:0] s_araddr,

    output reg         s_rvalid,
    input  wire        s_rready,
    output reg  [31:0] s_rdata,
    output wire [1:0]  s_rresp
);
  // Accepts AW/W/AR the instant they're asserted.
  assign s_awready = 1'b1;
  assign s_wready  = 1'b1;
  assign s_arready = 1'b1;
  assign s_bresp   = 2'b00; // OKAY
  assign s_rresp   = 2'b00; // OKAY

  reg [31:0] mem [0:15]; // 16-word scratch memory; addr[5:2] selects word

  // AWREADY/WREADY/ARREADY are unconditionally 1 (always-ready), so the
  // data path must not also gate on "is a previous response still
  // outstanding" (s_bvalid/s_rvalid) — that combination deadlocks the
  // moment the master drops xREADY the cycle after a transfer completes,
  // since the response-clear branch then never gets to fire. Instead just
  // latch unconditionally whenever *valid is seen, and pulse the response
  // valid for exactly one cycle per transaction.
  always @(posedge clk) begin
    if (rst) begin
      s_bvalid <= 1'b0;
      s_rvalid <= 1'b0;
    end else begin
      if (s_awvalid && s_wvalid) begin
        mem[s_awaddr[5:2]] <= s_wdata;
        s_bvalid <= 1'b1;
      end else begin
        s_bvalid <= 1'b0;
      end

      if (s_arvalid) begin
        s_rdata  <= mem[s_araddr[5:2]];
        s_rvalid <= 1'b1;
      end else begin
        s_rvalid <= 1'b0;
      end
    end
  end
endmodule

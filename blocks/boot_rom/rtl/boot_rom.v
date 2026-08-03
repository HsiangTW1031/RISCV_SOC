`include "axi_lite.vh"

// 64KB boot ROM: read-only AXI4-Lite slave, $readmemh-loaded.
// Only addr[15:2] (14 bits) is decoded internally — the crossbar routes
// anything with addr[31:28]==ADDR_REGION_ROM here, which covers a much
// larger range than the physical 64KB; addresses beyond that alias back
// into the same array. That's an accepted Phase-1 simplification for a
// memory this small, not a bug.
module boot_rom #(
    parameter HEXFILE = "" // path for $readmemh; empty = all-zero memory
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire        s_awvalid, output wire s_awready, input wire [31:0] s_awaddr,
    input  wire        s_wvalid,  output wire s_wready,  input wire [31:0] s_wdata, input wire [3:0] s_wstrb,
    output reg          s_bvalid,  input wire  s_bready,  output reg [1:0] s_bresp,
    input  wire        s_arvalid, output wire s_arready, input wire [31:0] s_araddr,
    output reg          s_rvalid,  input wire  s_rready,  output reg [31:0] s_rdata, output reg [1:0] s_rresp
);
  localparam WORDS = 16384; // 64KB / 4 bytes

  reg [31:0] mem [0:WORDS-1];

  initial begin
    if (HEXFILE != "")
      $readmemh(HEXFILE, mem);
  end

  // Always-ready, single-cycle-turnaround slave (see fake_axi_lite_slave.v
  // for why the response-valid must NOT also gate the data-path condition).
  assign s_awready = 1'b1;
  assign s_wready  = 1'b1;
  assign s_arready = 1'b1;

  wire [13:0] rd_idx = s_araddr[15:2];

  always @(posedge clk) begin
    if (!resetn) begin
      s_bvalid <= 1'b0;
      s_rvalid <= 1'b0;
    end else begin
      // Read-only: any write is accepted (so the master doesn't hang) but
      // answered with SLVERR, and memory is left untouched.
      if (s_awvalid && s_wvalid) begin
        s_bresp  <= `AXI_RESP_SLVERR;
        s_bvalid <= 1'b1;
      end else begin
        s_bvalid <= 1'b0;
      end

      if (s_arvalid) begin
        s_rdata  <= mem[rd_idx];
        s_rresp  <= `AXI_RESP_OKAY;
        s_rvalid <= 1'b1;
      end else begin
        s_rvalid <= 1'b0;
      end
    end
  end
endmodule

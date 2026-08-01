`include "axi_lite.vh"

// 128KB data/work RAM: read-write AXI4-Lite slave with per-byte write
// strobes. Only addr[16:2] (15 bits) is decoded internally — same aliasing
// note as boot_rom.v applies.
module sram (
    input  wire        clk,
    input  wire        rst,

    input  wire        s_awvalid, output wire s_awready, input wire [31:0] s_awaddr,
    input  wire        s_wvalid,  output wire s_wready,  input wire [31:0] s_wdata, input wire [3:0] s_wstrb,
    output reg          s_bvalid,  input wire  s_bready,  output reg [1:0] s_bresp,
    input  wire        s_arvalid, output wire s_arready, input wire [31:0] s_araddr,
    output reg          s_rvalid,  input wire  s_rready,  output reg [31:0] s_rdata, output reg [1:0] s_rresp
);
  localparam WORDS = 32768; // 128KB / 4 bytes

  reg [31:0] mem [0:WORDS-1];

  assign s_awready = 1'b1;
  assign s_wready  = 1'b1;
  assign s_arready = 1'b1;

  wire [14:0] wr_idx = s_awaddr[16:2];
  wire [14:0] rd_idx = s_araddr[16:2];

  always @(posedge clk) begin
    if (rst) begin
      s_bvalid <= 1'b0;
      s_rvalid <= 1'b0;
    end else begin
      if (s_awvalid && s_wvalid) begin
        if (s_wstrb[0]) mem[wr_idx][7:0]   <= s_wdata[7:0];
        if (s_wstrb[1]) mem[wr_idx][15:8]  <= s_wdata[15:8];
        if (s_wstrb[2]) mem[wr_idx][23:16] <= s_wdata[23:16];
        if (s_wstrb[3]) mem[wr_idx][31:24] <= s_wdata[31:24];
        s_bresp  <= `AXI_RESP_OKAY;
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

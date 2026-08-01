// Synthesis-only blackbox stand-ins for the three plain memory arrays in
// this SoC (boot_rom's 64KB ROM, sram's 128KB RAM, dma_ram's 8KB scratch
// buffer). In a real ASIC flow these would be hardened SRAM macros (or,
// for an FPGA target, mapped to block RAM primitives), not synthesized
// to flip-flops -- letting Yosys turn a 32K-word `reg [31:0] mem [...]`
// array into 1M+ flip-flops would be both unrepresentative of a real
// implementation and prohibitively slow to synthesize/STA for no
// benefit. Port lists match the real modules exactly so soc_top's
// hierarchy binds cleanly; internals are intentionally empty (blackbox).
// One declaration per line, no attributes -- kept deliberately plain so
// both Yosys (synthesis) and OpenSTA's simplified Verilog reader (STA,
// which just needs the port list to link the synthesized netlist, not a
// re-synthesis) can each parse this file directly. Not a synthesizable
// deliverable -- lives in syn/, used only for the whole-SoC logic-only
// synthesis/STA run described in docs/performance.md.

module boot_rom (
    clk, rst,
    s_awvalid, s_awready, s_awaddr,
    s_wvalid, s_wready, s_wdata, s_wstrb,
    s_bvalid, s_bready, s_bresp,
    s_arvalid, s_arready, s_araddr,
    s_rvalid, s_rready, s_rdata, s_rresp
);
  parameter HEXFILE = "";
  input        clk, rst;
  input        s_awvalid; output s_awready; input [31:0] s_awaddr;
  input        s_wvalid;  output s_wready;  input [31:0] s_wdata; input [3:0] s_wstrb;
  output       s_bvalid;  input  s_bready;  output [1:0] s_bresp;
  input        s_arvalid; output s_arready; input [31:0] s_araddr;
  output       s_rvalid;  input  s_rready;  output [31:0] s_rdata; output [1:0] s_rresp;
endmodule

module sram (
    clk, rst,
    s_awvalid, s_awready, s_awaddr,
    s_wvalid, s_wready, s_wdata, s_wstrb,
    s_bvalid, s_bready, s_bresp,
    s_arvalid, s_arready, s_araddr,
    s_rvalid, s_rready, s_rdata, s_rresp
);
  input        clk, rst;
  input        s_awvalid; output s_awready; input [31:0] s_awaddr;
  input        s_wvalid;  output s_wready;  input [31:0] s_wdata; input [3:0] s_wstrb;
  output       s_bvalid;  input  s_bready;  output [1:0] s_bresp;
  input        s_arvalid; output s_arready; input [31:0] s_araddr;
  output       s_rvalid;  input  s_rready;  output [31:0] s_rdata; output [1:0] s_rresp;
endmodule

module dma_ram (
    clk, rst,
    s_awvalid, s_awready, s_awaddr, s_awlen, s_awsize, s_awburst,
    s_wvalid, s_wready, s_wdata, s_wstrb, s_wlast,
    s_bvalid, s_bready, s_bresp,
    s_arvalid, s_arready, s_araddr, s_arlen, s_arsize, s_arburst,
    s_rvalid, s_rready, s_rdata, s_rresp, s_rlast
);
  parameter SIZE_WORDS = 2048;
  input        clk, rst;
  input        s_awvalid; output s_awready; input [31:0] s_awaddr;
  input [7:0]  s_awlen; input [2:0] s_awsize; input [1:0] s_awburst;
  input        s_wvalid;  output s_wready;  input [31:0] s_wdata; input [3:0] s_wstrb; input s_wlast;
  output       s_bvalid;  input  s_bready;  output [1:0] s_bresp;
  input        s_arvalid; output s_arready; input [31:0] s_araddr;
  input [7:0]  s_arlen; input [2:0] s_arsize; input [1:0] s_arburst;
  output       s_rvalid;  input  s_rready;  output [31:0] s_rdata; output [1:0] s_rresp; output s_rlast;
endmodule

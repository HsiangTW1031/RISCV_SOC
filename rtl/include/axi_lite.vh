// AXI4-Lite conventions shared by every master/slave in RISCV_SOC.
//
// Plain Verilog-2001 has no `interface`, and Yosys 0.67's SystemVerilog
// support is thin, so we don't try to bundle AXI signals through a macro
// expanded into a module's port list (that trick is fragile across
// Verible/svlint/Yosys/Verilator when a macro's trailing comma has to line
// up differently at the end of a port list). Instead: every module writes
// an explicit, flat port list, and every AXI4-Lite port on every module
// MUST use exactly this naming convention (`<prefix>_` is `s_` for a slave
// port, `m_` for a master port; drop the prefix on the top-level soc_top
// ports where there's only one of each):
//
//   Write address channel:  <prefix>_awvalid, <prefix>_awready, <prefix>_awaddr
//   Write data channel:     <prefix>_wvalid,  <prefix>_wready,  <prefix>_wdata,  <prefix>_wstrb
//   Write response channel: <prefix>_bvalid,  <prefix>_bready,  <prefix>_bresp
//   Read address channel:   <prefix>_arvalid, <prefix>_arready, <prefix>_araddr
//   Read data channel:      <prefix>_rvalid,  <prefix>_rready,  <prefix>_rdata,  <prefix>_rresp
//
// Widths are fixed project-wide (no AXI ID signals — AXI-Lite has none;
// no burst signals — AXI-Lite has none):
`define AXI_ADDR_WIDTH 32
`define AXI_DATA_WIDTH 32
`define AXI_STRB_WIDTH 4   // AXI_DATA_WIDTH/8

// AxRESP / xRESP encoding actually used (AXI4 defines 4 values; this project
// only ever drives OKAY or SLVERR — EXOKAY/DECERR are never generated).
`define AXI_RESP_OKAY   2'b00
`define AXI_RESP_SLVERR 2'b10

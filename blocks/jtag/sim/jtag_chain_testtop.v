// Test-only harness: jtag_tap + jtag_dtm + jtag_axi_bridge, bridged
// straight into a fake_axi_lite_slave (16-word scratch memory), so the
// full JTAG-to-AXI path -- including the tck<->clk CDC -- can be
// validated end-to-end before soc_top wiring. Not a synthesizable
// deliverable; lives in sim/, not rtl/.
module jtag_chain_testtop (
    input  wire clk,
    input  wire rst,
    input  wire tck,
    input  wire tck_rst,
    input  wire tms,
    input  wire tdi,
    output wire tdo
);
  wire        start_pulse_tck, rw_tck;
  wire [31:0] addr_tck, wdata_tck;
  wire        busy_tck, resp_ok_tck;
  wire [31:0] rdata_tck;

  jtag_dtm u_dtm (
      .tck(tck), .rst(tck_rst), .tms(tms), .tdi(tdi), .tdo(tdo),
      .bridge_busy_tck(busy_tck), .bridge_resp_ok_tck(resp_ok_tck), .bridge_rdata_tck(rdata_tck),
      .start_pulse_tck(start_pulse_tck), .rw_tck(rw_tck), .addr_tck(addr_tck), .wdata_tck(wdata_tck)
  );

  wire        m_awvalid, m_awready; wire [31:0] m_awaddr;
  wire        m_wvalid,  m_wready;  wire [31:0] m_wdata; wire [3:0] m_wstrb;
  wire        m_bvalid,  m_bready;  wire [1:0]  m_bresp;
  wire        m_arvalid, m_arready; wire [31:0] m_araddr;
  wire        m_rvalid,  m_rready;  wire [31:0] m_rdata; wire [1:0] m_rresp;

  jtag_axi_bridge u_bridge (
      .clk(clk), .rst(rst), .tck(tck), .tck_rst(tck_rst),
      .start_pulse_tck(start_pulse_tck), .rw_tck(rw_tck), .addr_tck(addr_tck), .wdata_tck(wdata_tck),
      .busy_tck(busy_tck), .resp_ok_tck(resp_ok_tck), .rdata_tck(rdata_tck),
      .m_awvalid(m_awvalid), .m_awready(m_awready), .m_awaddr(m_awaddr),
      .m_wvalid(m_wvalid),   .m_wready(m_wready),   .m_wdata(m_wdata), .m_wstrb(m_wstrb),
      .m_bvalid(m_bvalid),   .m_bready(m_bready),   .m_bresp(m_bresp),
      .m_arvalid(m_arvalid), .m_arready(m_arready), .m_araddr(m_araddr),
      .m_rvalid(m_rvalid),   .m_rready(m_rready),   .m_rdata(m_rdata), .m_rresp(m_rresp)
  );

  fake_axi_lite_slave u_slave (
      .clk(clk), .rst(rst),
      .s_awvalid(m_awvalid), .s_awready(m_awready), .s_awaddr(m_awaddr),
      .s_wvalid(m_wvalid),   .s_wready(m_wready),   .s_wdata(m_wdata), .s_wstrb(m_wstrb),
      .s_bvalid(m_bvalid),   .s_bready(m_bready),   .s_bresp(m_bresp),
      .s_arvalid(m_arvalid), .s_arready(m_arready), .s_araddr(m_araddr),
      .s_rvalid(m_rvalid),   .s_rready(m_rready),   .s_rdata(m_rdata), .s_rresp(m_rresp)
  );
endmodule

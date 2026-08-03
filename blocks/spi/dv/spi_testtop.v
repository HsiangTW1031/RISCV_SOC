// Test-only harness: spi_master + fake_spi_slave loopback, so spi_master
// can be validated byte-accurately across all 4 CPOL/CPHA modes before any
// real SPI device exists. Not a synthesizable deliverable.
module spi_testtop (
    input  wire        clk,
    input  wire        resetn,

    input  wire        s_awvalid, output wire s_awready, input wire [31:0] s_awaddr,
    input  wire        s_wvalid,  output wire s_wready,  input wire [31:0] s_wdata, input wire [3:0] s_wstrb,
    output wire         s_bvalid,  input wire  s_bready,  output wire [1:0] s_bresp,
    input  wire        s_arvalid, output wire s_arready, input wire [31:0] s_araddr,
    output wire         s_rvalid,  input wire  s_rready,  output wire [31:0] s_rdata, output wire [1:0] s_rresp,

    // slave-side test controls/observability
    input  wire        slave_cpol,
    input  wire        slave_cpha,
    input  wire [7:0]  slave_preload,
    output wire [7:0]  slave_received,
    output wire        slave_xfer_done,

    output wire         irq
);
  wire sclk, mosi, miso, cs_n;

  spi_master u_spi (
      .clk(clk), .resetn(resetn),
      .s_awvalid(s_awvalid), .s_awready(s_awready), .s_awaddr(s_awaddr),
      .s_wvalid(s_wvalid),   .s_wready(s_wready),   .s_wdata(s_wdata), .s_wstrb(s_wstrb),
      .s_bvalid(s_bvalid),   .s_bready(s_bready),   .s_bresp(s_bresp),
      .s_arvalid(s_arvalid), .s_arready(s_arready), .s_araddr(s_araddr),
      .s_rvalid(s_rvalid),   .s_rready(s_rready),   .s_rdata(s_rdata), .s_rresp(s_rresp),
      .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n),
      .irq(irq)
  );

  fake_spi_slave u_slave (
      .clk(clk),
      .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n),
      .cpol(slave_cpol), .cpha(slave_cpha),
      .preload(slave_preload),
      .received(slave_received),
      .xfer_done(slave_xfer_done)
  );
endmodule

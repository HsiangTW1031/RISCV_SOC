// Test-only harness: i2c_master + fake_i2c_slave over a shared open-drain
// sda (with a pullup) and scl, so i2c_master can be validated byte-
// accurately (write, read, NACK-on-unknown-address) before any real I2C
// device exists. Not a synthesizable deliverable.
module i2c_testtop (
    input  wire        clk,
    input  wire        resetn,

    input  wire        s_awvalid, output wire s_awready, input wire [31:0] s_awaddr,
    input  wire        s_wvalid,  output wire s_wready,  input wire [31:0] s_wdata, input wire [3:0] s_wstrb,
    output wire         s_bvalid,  input wire  s_bready,  output wire [1:0] s_bresp,
    input  wire        s_arvalid, output wire s_arready, input wire [31:0] s_araddr,
    output wire         s_rvalid,  input wire  s_rready,  output wire [31:0] s_rdata, output wire [1:0] s_rresp,

    // slave-side test controls/observability
    input  wire [6:0]  slave_addr,
    input  wire [7:0]  slave_tx_byte,
    output wire [7:0]  slave_rx_byte,
    output wire        slave_got_write,
    output wire        slave_got_read,
    output wire        slave_xfer_done,

    output wire         irq
);
  wire scl, sda;

  pullup (sda);

  i2c_master u_i2c (
      .clk(clk), .resetn(resetn),
      .s_awvalid(s_awvalid), .s_awready(s_awready), .s_awaddr(s_awaddr),
      .s_wvalid(s_wvalid),   .s_wready(s_wready),   .s_wdata(s_wdata), .s_wstrb(s_wstrb),
      .s_bvalid(s_bvalid),   .s_bready(s_bready),   .s_bresp(s_bresp),
      .s_arvalid(s_arvalid), .s_arready(s_arready), .s_araddr(s_araddr),
      .s_rvalid(s_rvalid),   .s_rready(s_rready),   .s_rdata(s_rdata), .s_rresp(s_rresp),
      .scl(scl), .sda(sda),
      .irq(irq)
  );

  fake_i2c_slave u_slave (
      .clk(clk),
      .scl(scl), .sda(sda),
      .my_addr(slave_addr),
      .tx_byte(slave_tx_byte),
      .rx_byte(slave_rx_byte),
      .got_write(slave_got_write),
      .got_read(slave_got_read),
      .xfer_done(slave_xfer_done)
  );
endmodule

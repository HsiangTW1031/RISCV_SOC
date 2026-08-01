// Test-only wiring harness: axi_lite_xbar + three fake_axi_lite_slave
// stand-ins for ROM/RAM/UART, so the crossbar's address decode and channel
// routing can be validated before any real peripheral RTL exists. Not a
// synthesizable deliverable — lives in sim/, not rtl/.
module xbar_testtop (
    input  wire        clk,
    input  wire        rst,

    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_awaddr,

    input  wire        s_wvalid,
    output wire        s_wready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,

    output wire        s_bvalid,
    input  wire        s_bready,
    output wire [1:0]  s_bresp,

    input  wire        s_arvalid,
    output wire        s_arready,
    input  wire [31:0] s_araddr,

    output wire        s_rvalid,
    input  wire        s_rready,
    output wire [31:0] s_rdata,
    output wire [1:0]  s_rresp
);

  wire        rom_awvalid, rom_awready, rom_wvalid, rom_wready, rom_bvalid, rom_bready, rom_arvalid, rom_arready, rom_rvalid, rom_rready;
  wire [31:0] rom_awaddr, rom_wdata, rom_araddr, rom_rdata;
  wire [3:0]  rom_wstrb;
  wire [1:0]  rom_bresp, rom_rresp;

  wire        ram_awvalid, ram_awready, ram_wvalid, ram_wready, ram_bvalid, ram_bready, ram_arvalid, ram_arready, ram_rvalid, ram_rready;
  wire [31:0] ram_awaddr, ram_wdata, ram_araddr, ram_rdata;
  wire [3:0]  ram_wstrb;
  wire [1:0]  ram_bresp, ram_rresp;

  wire        uart_awvalid, uart_awready, uart_wvalid, uart_wready, uart_bvalid, uart_bready, uart_arvalid, uart_arready, uart_rvalid, uart_rready;
  wire [31:0] uart_awaddr, uart_wdata, uart_araddr, uart_rdata;
  wire [3:0]  uart_wstrb;
  wire [1:0]  uart_bresp, uart_rresp;

  axi_lite_xbar u_xbar (
      .clk(clk), .rst(rst),
      .s_awvalid(s_awvalid), .s_awready(s_awready), .s_awaddr(s_awaddr),
      .s_wvalid(s_wvalid),   .s_wready(s_wready),   .s_wdata(s_wdata), .s_wstrb(s_wstrb),
      .s_bvalid(s_bvalid),   .s_bready(s_bready),   .s_bresp(s_bresp),
      .s_arvalid(s_arvalid), .s_arready(s_arready), .s_araddr(s_araddr),
      .s_rvalid(s_rvalid),   .s_rready(s_rready),   .s_rdata(s_rdata), .s_rresp(s_rresp),

      .rom_awvalid(rom_awvalid), .rom_awready(rom_awready), .rom_awaddr(rom_awaddr),
      .rom_wvalid(rom_wvalid),   .rom_wready(rom_wready),   .rom_wdata(rom_wdata), .rom_wstrb(rom_wstrb),
      .rom_bvalid(rom_bvalid),   .rom_bready(rom_bready),   .rom_bresp(rom_bresp),
      .rom_arvalid(rom_arvalid), .rom_arready(rom_arready), .rom_araddr(rom_araddr),
      .rom_rvalid(rom_rvalid),   .rom_rready(rom_rready),   .rom_rdata(rom_rdata), .rom_rresp(rom_rresp),

      .ram_awvalid(ram_awvalid), .ram_awready(ram_awready), .ram_awaddr(ram_awaddr),
      .ram_wvalid(ram_wvalid),   .ram_wready(ram_wready),   .ram_wdata(ram_wdata), .ram_wstrb(ram_wstrb),
      .ram_bvalid(ram_bvalid),   .ram_bready(ram_bready),   .ram_bresp(ram_bresp),
      .ram_arvalid(ram_arvalid), .ram_arready(ram_arready), .ram_araddr(ram_araddr),
      .ram_rvalid(ram_rvalid),   .ram_rready(ram_rready),   .ram_rdata(ram_rdata), .ram_rresp(ram_rresp),

      .uart_awvalid(uart_awvalid), .uart_awready(uart_awready), .uart_awaddr(uart_awaddr),
      .uart_wvalid(uart_wvalid),   .uart_wready(uart_wready),   .uart_wdata(uart_wdata), .uart_wstrb(uart_wstrb),
      .uart_bvalid(uart_bvalid),   .uart_bready(uart_bready),   .uart_bresp(uart_bresp),
      .uart_arvalid(uart_arvalid), .uart_arready(uart_arready), .uart_araddr(uart_araddr),
      .uart_rvalid(uart_rvalid),   .uart_rready(uart_rready),   .uart_rdata(uart_rdata), .uart_rresp(uart_rresp)
  );

  fake_axi_lite_slave u_rom (
      .clk(clk), .rst(rst),
      .s_awvalid(rom_awvalid), .s_awready(rom_awready), .s_awaddr(rom_awaddr),
      .s_wvalid(rom_wvalid),   .s_wready(rom_wready),   .s_wdata(rom_wdata), .s_wstrb(rom_wstrb),
      .s_bvalid(rom_bvalid),   .s_bready(rom_bready),   .s_bresp(rom_bresp),
      .s_arvalid(rom_arvalid), .s_arready(rom_arready), .s_araddr(rom_araddr),
      .s_rvalid(rom_rvalid),   .s_rready(rom_rready),   .s_rdata(rom_rdata), .s_rresp(rom_rresp)
  );

  fake_axi_lite_slave u_ram (
      .clk(clk), .rst(rst),
      .s_awvalid(ram_awvalid), .s_awready(ram_awready), .s_awaddr(ram_awaddr),
      .s_wvalid(ram_wvalid),   .s_wready(ram_wready),   .s_wdata(ram_wdata), .s_wstrb(ram_wstrb),
      .s_bvalid(ram_bvalid),   .s_bready(ram_bready),   .s_bresp(ram_bresp),
      .s_arvalid(ram_arvalid), .s_arready(ram_arready), .s_araddr(ram_araddr),
      .s_rvalid(ram_rvalid),   .s_rready(ram_rready),   .s_rdata(ram_rdata), .s_rresp(ram_rresp)
  );

  fake_axi_lite_slave u_uart (
      .clk(clk), .rst(rst),
      .s_awvalid(uart_awvalid), .s_awready(uart_awready), .s_awaddr(uart_awaddr),
      .s_wvalid(uart_wvalid),   .s_wready(uart_wready),   .s_wdata(uart_wdata), .s_wstrb(uart_wstrb),
      .s_bvalid(uart_bvalid),   .s_bready(uart_bready),   .s_bresp(uart_bresp),
      .s_arvalid(uart_arvalid), .s_arready(uart_arready), .s_araddr(uart_araddr),
      .s_rvalid(uart_rvalid),   .s_rready(uart_rready),   .s_rdata(uart_rdata), .s_rresp(uart_rresp)
  );

endmodule

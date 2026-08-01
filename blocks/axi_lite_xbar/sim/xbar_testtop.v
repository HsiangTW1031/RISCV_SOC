// Test-only wiring harness: axi_lite_xbar + five fake_axi_lite_slave
// stand-ins for ROM/RAM/Timer/WDT/UART, so the crossbar's address decode
// and channel routing can be validated before real peripheral RTL is
// wired in. Not a synthesizable deliverable — lives in sim/, not rtl/.
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

  wire        timer_awvalid, timer_awready, timer_wvalid, timer_wready, timer_bvalid, timer_bready, timer_arvalid, timer_arready, timer_rvalid, timer_rready;
  wire [31:0] timer_awaddr, timer_wdata, timer_araddr, timer_rdata;
  wire [3:0]  timer_wstrb;
  wire [1:0]  timer_bresp, timer_rresp;

  wire        wdt_awvalid, wdt_awready, wdt_wvalid, wdt_wready, wdt_bvalid, wdt_bready, wdt_arvalid, wdt_arready, wdt_rvalid, wdt_rready;
  wire [31:0] wdt_awaddr, wdt_wdata, wdt_araddr, wdt_rdata;
  wire [3:0]  wdt_wstrb;
  wire [1:0]  wdt_bresp, wdt_rresp;

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

      .timer_awvalid(timer_awvalid), .timer_awready(timer_awready), .timer_awaddr(timer_awaddr),
      .timer_wvalid(timer_wvalid),   .timer_wready(timer_wready),   .timer_wdata(timer_wdata), .timer_wstrb(timer_wstrb),
      .timer_bvalid(timer_bvalid),   .timer_bready(timer_bready),   .timer_bresp(timer_bresp),
      .timer_arvalid(timer_arvalid), .timer_arready(timer_arready), .timer_araddr(timer_araddr),
      .timer_rvalid(timer_rvalid),   .timer_rready(timer_rready),   .timer_rdata(timer_rdata), .timer_rresp(timer_rresp),

      .wdt_awvalid(wdt_awvalid), .wdt_awready(wdt_awready), .wdt_awaddr(wdt_awaddr),
      .wdt_wvalid(wdt_wvalid),   .wdt_wready(wdt_wready),   .wdt_wdata(wdt_wdata), .wdt_wstrb(wdt_wstrb),
      .wdt_bvalid(wdt_bvalid),   .wdt_bready(wdt_bready),   .wdt_bresp(wdt_bresp),
      .wdt_arvalid(wdt_arvalid), .wdt_arready(wdt_arready), .wdt_araddr(wdt_araddr),
      .wdt_rvalid(wdt_rvalid),   .wdt_rready(wdt_rready),   .wdt_rdata(wdt_rdata), .wdt_rresp(wdt_rresp),

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

  fake_axi_lite_slave u_timer (
      .clk(clk), .rst(rst),
      .s_awvalid(timer_awvalid), .s_awready(timer_awready), .s_awaddr(timer_awaddr),
      .s_wvalid(timer_wvalid),   .s_wready(timer_wready),   .s_wdata(timer_wdata), .s_wstrb(timer_wstrb),
      .s_bvalid(timer_bvalid),   .s_bready(timer_bready),   .s_bresp(timer_bresp),
      .s_arvalid(timer_arvalid), .s_arready(timer_arready), .s_araddr(timer_araddr),
      .s_rvalid(timer_rvalid),   .s_rready(timer_rready),   .s_rdata(timer_rdata), .s_rresp(timer_rresp)
  );

  fake_axi_lite_slave u_wdt (
      .clk(clk), .rst(rst),
      .s_awvalid(wdt_awvalid), .s_awready(wdt_awready), .s_awaddr(wdt_awaddr),
      .s_wvalid(wdt_wvalid),   .s_wready(wdt_wready),   .s_wdata(wdt_wdata), .s_wstrb(wdt_wstrb),
      .s_bvalid(wdt_bvalid),   .s_bready(wdt_bready),   .s_bresp(wdt_bresp),
      .s_arvalid(wdt_arvalid), .s_arready(wdt_arready), .s_araddr(wdt_araddr),
      .s_rvalid(wdt_rvalid),   .s_rready(wdt_rready),   .s_rdata(wdt_rdata), .s_rresp(wdt_rresp)
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

// Test-only wiring harness: axi_lite_xbar (2 masters: s0=CPU, s1=JTAG) +
// eight fake_axi_lite_slave stand-ins for ROM/RAM/Timer/WDT/UART/I2C/SPI/
// AES, so the crossbar's address decode, channel routing, and 2-master
// arbitration can be validated before real peripheral/JTAG-bridge RTL is
// wired in. Not a synthesizable deliverable — lives in sim/, not rtl/.
module xbar_testtop (
    input  wire        clk,
    input  wire        resetn,

    input  wire        s0_awvalid,
    output wire        s0_awready,
    input  wire [31:0] s0_awaddr,

    input  wire        s0_wvalid,
    output wire        s0_wready,
    input  wire [31:0] s0_wdata,
    input  wire [3:0]  s0_wstrb,

    output wire        s0_bvalid,
    input  wire        s0_bready,
    output wire [1:0]  s0_bresp,

    input  wire        s0_arvalid,
    output wire        s0_arready,
    input  wire [31:0] s0_araddr,

    output wire        s0_rvalid,
    input  wire        s0_rready,
    output wire [31:0] s0_rdata,
    output wire [1:0]  s0_rresp,

    input  wire        s1_awvalid,
    output wire        s1_awready,
    input  wire [31:0] s1_awaddr,

    input  wire        s1_wvalid,
    output wire        s1_wready,
    input  wire [31:0] s1_wdata,
    input  wire [3:0]  s1_wstrb,

    output wire        s1_bvalid,
    input  wire        s1_bready,
    output wire [1:0]  s1_bresp,

    input  wire        s1_arvalid,
    output wire        s1_arready,
    input  wire [31:0] s1_araddr,

    output wire        s1_rvalid,
    input  wire        s1_rready,
    output wire [31:0] s1_rdata,
    output wire [1:0]  s1_rresp
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

  wire        i2c_awvalid, i2c_awready, i2c_wvalid, i2c_wready, i2c_bvalid, i2c_bready, i2c_arvalid, i2c_arready, i2c_rvalid, i2c_rready;
  wire [31:0] i2c_awaddr, i2c_wdata, i2c_araddr, i2c_rdata;
  wire [3:0]  i2c_wstrb;
  wire [1:0]  i2c_bresp, i2c_rresp;

  wire        spi_awvalid, spi_awready, spi_wvalid, spi_wready, spi_bvalid, spi_bready, spi_arvalid, spi_arready, spi_rvalid, spi_rready;
  wire [31:0] spi_awaddr, spi_wdata, spi_araddr, spi_rdata;
  wire [3:0]  spi_wstrb;
  wire [1:0]  spi_bresp, spi_rresp;

  wire        aes_awvalid, aes_awready, aes_wvalid, aes_wready, aes_bvalid, aes_bready, aes_arvalid, aes_arready, aes_rvalid, aes_rready;
  wire [31:0] aes_awaddr, aes_wdata, aes_araddr, aes_rdata;
  wire [3:0]  aes_wstrb;
  wire [1:0]  aes_bresp, aes_rresp;

  wire        dma_awvalid, dma_awready, dma_wvalid, dma_wready, dma_bvalid, dma_bready, dma_arvalid, dma_arready, dma_rvalid, dma_rready;
  wire [31:0] dma_awaddr, dma_wdata, dma_araddr, dma_rdata;
  wire [3:0]  dma_wstrb;
  wire [1:0]  dma_bresp, dma_rresp;

  axi_lite_xbar u_xbar (
      .clk(clk), .resetn(resetn),
      .s0_awvalid(s0_awvalid), .s0_awready(s0_awready), .s0_awaddr(s0_awaddr),
      .s0_wvalid(s0_wvalid),   .s0_wready(s0_wready),   .s0_wdata(s0_wdata), .s0_wstrb(s0_wstrb),
      .s0_bvalid(s0_bvalid),   .s0_bready(s0_bready),   .s0_bresp(s0_bresp),
      .s0_arvalid(s0_arvalid), .s0_arready(s0_arready), .s0_araddr(s0_araddr),
      .s0_rvalid(s0_rvalid),   .s0_rready(s0_rready),   .s0_rdata(s0_rdata), .s0_rresp(s0_rresp),

      .s1_awvalid(s1_awvalid), .s1_awready(s1_awready), .s1_awaddr(s1_awaddr),
      .s1_wvalid(s1_wvalid),   .s1_wready(s1_wready),   .s1_wdata(s1_wdata), .s1_wstrb(s1_wstrb),
      .s1_bvalid(s1_bvalid),   .s1_bready(s1_bready),   .s1_bresp(s1_bresp),
      .s1_arvalid(s1_arvalid), .s1_arready(s1_arready), .s1_araddr(s1_araddr),
      .s1_rvalid(s1_rvalid),   .s1_rready(s1_rready),   .s1_rdata(s1_rdata), .s1_rresp(s1_rresp),

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
      .uart_rvalid(uart_rvalid),   .uart_rready(uart_rready),   .uart_rdata(uart_rdata), .uart_rresp(uart_rresp),

      .i2c_awvalid(i2c_awvalid), .i2c_awready(i2c_awready), .i2c_awaddr(i2c_awaddr),
      .i2c_wvalid(i2c_wvalid),   .i2c_wready(i2c_wready),   .i2c_wdata(i2c_wdata), .i2c_wstrb(i2c_wstrb),
      .i2c_bvalid(i2c_bvalid),   .i2c_bready(i2c_bready),   .i2c_bresp(i2c_bresp),
      .i2c_arvalid(i2c_arvalid), .i2c_arready(i2c_arready), .i2c_araddr(i2c_araddr),
      .i2c_rvalid(i2c_rvalid),   .i2c_rready(i2c_rready),   .i2c_rdata(i2c_rdata), .i2c_rresp(i2c_rresp),

      .spi_awvalid(spi_awvalid), .spi_awready(spi_awready), .spi_awaddr(spi_awaddr),
      .spi_wvalid(spi_wvalid),   .spi_wready(spi_wready),   .spi_wdata(spi_wdata), .spi_wstrb(spi_wstrb),
      .spi_bvalid(spi_bvalid),   .spi_bready(spi_bready),   .spi_bresp(spi_bresp),
      .spi_arvalid(spi_arvalid), .spi_arready(spi_arready), .spi_araddr(spi_araddr),
      .spi_rvalid(spi_rvalid),   .spi_rready(spi_rready),   .spi_rdata(spi_rdata), .spi_rresp(spi_rresp),

      .aes_awvalid(aes_awvalid), .aes_awready(aes_awready), .aes_awaddr(aes_awaddr),
      .aes_wvalid(aes_wvalid),   .aes_wready(aes_wready),   .aes_wdata(aes_wdata), .aes_wstrb(aes_wstrb),
      .aes_bvalid(aes_bvalid),   .aes_bready(aes_bready),   .aes_bresp(aes_bresp),
      .aes_arvalid(aes_arvalid), .aes_arready(aes_arready), .aes_araddr(aes_araddr),
      .aes_rvalid(aes_rvalid),   .aes_rready(aes_rready),   .aes_rdata(aes_rdata), .aes_rresp(aes_rresp),

      .dma_awvalid(dma_awvalid), .dma_awready(dma_awready), .dma_awaddr(dma_awaddr),
      .dma_wvalid(dma_wvalid),   .dma_wready(dma_wready),   .dma_wdata(dma_wdata), .dma_wstrb(dma_wstrb),
      .dma_bvalid(dma_bvalid),   .dma_bready(dma_bready),   .dma_bresp(dma_bresp),
      .dma_arvalid(dma_arvalid), .dma_arready(dma_arready), .dma_araddr(dma_araddr),
      .dma_rvalid(dma_rvalid),   .dma_rready(dma_rready),   .dma_rdata(dma_rdata), .dma_rresp(dma_rresp)
  );

  fake_axi_lite_slave u_rom (
      .clk(clk), .resetn(resetn),
      .s_awvalid(rom_awvalid), .s_awready(rom_awready), .s_awaddr(rom_awaddr),
      .s_wvalid(rom_wvalid),   .s_wready(rom_wready),   .s_wdata(rom_wdata), .s_wstrb(rom_wstrb),
      .s_bvalid(rom_bvalid),   .s_bready(rom_bready),   .s_bresp(rom_bresp),
      .s_arvalid(rom_arvalid), .s_arready(rom_arready), .s_araddr(rom_araddr),
      .s_rvalid(rom_rvalid),   .s_rready(rom_rready),   .s_rdata(rom_rdata), .s_rresp(rom_rresp)
  );

  fake_axi_lite_slave u_ram (
      .clk(clk), .resetn(resetn),
      .s_awvalid(ram_awvalid), .s_awready(ram_awready), .s_awaddr(ram_awaddr),
      .s_wvalid(ram_wvalid),   .s_wready(ram_wready),   .s_wdata(ram_wdata), .s_wstrb(ram_wstrb),
      .s_bvalid(ram_bvalid),   .s_bready(ram_bready),   .s_bresp(ram_bresp),
      .s_arvalid(ram_arvalid), .s_arready(ram_arready), .s_araddr(ram_araddr),
      .s_rvalid(ram_rvalid),   .s_rready(ram_rready),   .s_rdata(ram_rdata), .s_rresp(ram_rresp)
  );

  fake_axi_lite_slave u_timer (
      .clk(clk), .resetn(resetn),
      .s_awvalid(timer_awvalid), .s_awready(timer_awready), .s_awaddr(timer_awaddr),
      .s_wvalid(timer_wvalid),   .s_wready(timer_wready),   .s_wdata(timer_wdata), .s_wstrb(timer_wstrb),
      .s_bvalid(timer_bvalid),   .s_bready(timer_bready),   .s_bresp(timer_bresp),
      .s_arvalid(timer_arvalid), .s_arready(timer_arready), .s_araddr(timer_araddr),
      .s_rvalid(timer_rvalid),   .s_rready(timer_rready),   .s_rdata(timer_rdata), .s_rresp(timer_rresp)
  );

  fake_axi_lite_slave u_wdt (
      .clk(clk), .resetn(resetn),
      .s_awvalid(wdt_awvalid), .s_awready(wdt_awready), .s_awaddr(wdt_awaddr),
      .s_wvalid(wdt_wvalid),   .s_wready(wdt_wready),   .s_wdata(wdt_wdata), .s_wstrb(wdt_wstrb),
      .s_bvalid(wdt_bvalid),   .s_bready(wdt_bready),   .s_bresp(wdt_bresp),
      .s_arvalid(wdt_arvalid), .s_arready(wdt_arready), .s_araddr(wdt_araddr),
      .s_rvalid(wdt_rvalid),   .s_rready(wdt_rready),   .s_rdata(wdt_rdata), .s_rresp(wdt_rresp)
  );

  fake_axi_lite_slave u_uart (
      .clk(clk), .resetn(resetn),
      .s_awvalid(uart_awvalid), .s_awready(uart_awready), .s_awaddr(uart_awaddr),
      .s_wvalid(uart_wvalid),   .s_wready(uart_wready),   .s_wdata(uart_wdata), .s_wstrb(uart_wstrb),
      .s_bvalid(uart_bvalid),   .s_bready(uart_bready),   .s_bresp(uart_bresp),
      .s_arvalid(uart_arvalid), .s_arready(uart_arready), .s_araddr(uart_araddr),
      .s_rvalid(uart_rvalid),   .s_rready(uart_rready),   .s_rdata(uart_rdata), .s_rresp(uart_rresp)
  );

  fake_axi_lite_slave u_i2c (
      .clk(clk), .resetn(resetn),
      .s_awvalid(i2c_awvalid), .s_awready(i2c_awready), .s_awaddr(i2c_awaddr),
      .s_wvalid(i2c_wvalid),   .s_wready(i2c_wready),   .s_wdata(i2c_wdata), .s_wstrb(i2c_wstrb),
      .s_bvalid(i2c_bvalid),   .s_bready(i2c_bready),   .s_bresp(i2c_bresp),
      .s_arvalid(i2c_arvalid), .s_arready(i2c_arready), .s_araddr(i2c_araddr),
      .s_rvalid(i2c_rvalid),   .s_rready(i2c_rready),   .s_rdata(i2c_rdata), .s_rresp(i2c_rresp)
  );

  fake_axi_lite_slave u_spi (
      .clk(clk), .resetn(resetn),
      .s_awvalid(spi_awvalid), .s_awready(spi_awready), .s_awaddr(spi_awaddr),
      .s_wvalid(spi_wvalid),   .s_wready(spi_wready),   .s_wdata(spi_wdata), .s_wstrb(spi_wstrb),
      .s_bvalid(spi_bvalid),   .s_bready(spi_bready),   .s_bresp(spi_bresp),
      .s_arvalid(spi_arvalid), .s_arready(spi_arready), .s_araddr(spi_araddr),
      .s_rvalid(spi_rvalid),   .s_rready(spi_rready),   .s_rdata(spi_rdata), .s_rresp(spi_rresp)
  );

  fake_axi_lite_slave u_aes (
      .clk(clk), .resetn(resetn),
      .s_awvalid(aes_awvalid), .s_awready(aes_awready), .s_awaddr(aes_awaddr),
      .s_wvalid(aes_wvalid),   .s_wready(aes_wready),   .s_wdata(aes_wdata), .s_wstrb(aes_wstrb),
      .s_bvalid(aes_bvalid),   .s_bready(aes_bready),   .s_bresp(aes_bresp),
      .s_arvalid(aes_arvalid), .s_arready(aes_arready), .s_araddr(aes_araddr),
      .s_rvalid(aes_rvalid),   .s_rready(aes_rready),   .s_rdata(aes_rdata), .s_rresp(aes_rresp)
  );

  fake_axi_lite_slave u_dma (
      .clk(clk), .resetn(resetn),
      .s_awvalid(dma_awvalid), .s_awready(dma_awready), .s_awaddr(dma_awaddr),
      .s_wvalid(dma_wvalid),   .s_wready(dma_wready),   .s_wdata(dma_wdata), .s_wstrb(dma_wstrb),
      .s_bvalid(dma_bvalid),   .s_bready(dma_bready),   .s_bresp(dma_bresp),
      .s_arvalid(dma_arvalid), .s_arready(dma_arready), .s_araddr(dma_araddr),
      .s_rvalid(dma_rvalid),   .s_rready(dma_rready),   .s_rdata(dma_rdata), .s_rresp(dma_rresp)
  );

endmodule

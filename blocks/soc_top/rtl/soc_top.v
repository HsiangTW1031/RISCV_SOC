`include "axi_lite.vh"

// Top-level SoC integration — Phase 3 scope: CPU + crossbar + ROM/RAM/UART
// + Timer + Watchdog + I2C + SPI, interrupts enabled. AES/JTAG land in
// later phases (see docs/phase_plan.md).
//
// Known limitation (unchanged from Phase 1): picorv32_axi's mem_axi_b*/r*
// ports have no BRESP/RRESP pins at all — this adapter never checks for
// SLVERR. An unmapped-address bug in firmware won't hang the bus, but it
// also won't be caught by the CPU itself.
//
// IRQ map (matches docs/phase_plan.md): irq[3] = Timer EXPIRED,
// irq[4] = Watchdog WARNING, irq[5] = I2C transfer done, irq[6] = SPI
// transfer done. irq[0]/irq[1] are PicoRV32's own built-in bus-error/
// illegal-instruction traps; everything else is unused this phase.
// wdog_reset_req is exposed at the top level for observability but is NOT
// yet wired to actually reset the SoC — that's a deliberate, documented
// scope cut (see docs/phase_plan.md risk notes).
module soc_top #(
    parameter FIRMWARE_HEX = "firmware.hex"
) (
    input  wire clk,
    input  wire rst,
    output wire uart_tx,
    output wire wdog_reset_req,
    output wire i2c_scl,
    inout  wire i2c_sda,
    output wire spi_sclk,
    output wire spi_mosi,
    input  wire spi_miso,
    output wire spi_cs_n
);
  wire resetn = !rst;

  // ---- CPU AXI4-Lite master ----
  wire        cpu_awvalid, cpu_awready;
  wire [31:0] cpu_awaddr;
  wire        cpu_wvalid, cpu_wready;
  wire [31:0] cpu_wdata;
  wire [3:0]  cpu_wstrb;
  wire        cpu_bvalid, cpu_bready;
  wire        cpu_arvalid, cpu_arready;
  wire [31:0] cpu_araddr;
  wire        cpu_rvalid, cpu_rready;
  wire [31:0] cpu_rdata;

  wire        timer_irq, wdt_irq, i2c_irq, spi_irq;
  wire [31:0] irq_bus = {25'b0, spi_irq, i2c_irq, wdt_irq, timer_irq, 3'b0};
  // bit6=spi_irq, bit5=i2c_irq, bit4=wdt_irq, bit3=timer_irq, bits[2:0]
  // reserved for PicoRV32's own bus-error/illegal-instruction/(unused) traps.

  picorv32_axi #(
      .ENABLE_MUL(1),
      .ENABLE_DIV(1),
      .COMPRESSED_ISA(1),
      .ENABLE_IRQ(1),
      .MASKED_IRQ(32'h0000_0000),
      .LATCHED_IRQ(32'hFFFF_FFFF),
      .STACKADDR(32'h1002_0000),   // top of the 128KB RAM at 0x1000_0000
      .PROGADDR_RESET(32'h0000_0000),
      .PROGADDR_IRQ(32'h0000_0010)
  ) u_cpu (
      .clk(clk),
      .resetn(resetn),
      .trap(),

      .mem_axi_awvalid(cpu_awvalid), .mem_axi_awready(cpu_awready), .mem_axi_awaddr(cpu_awaddr), .mem_axi_awprot(),
      .mem_axi_wvalid(cpu_wvalid),   .mem_axi_wready(cpu_wready),   .mem_axi_wdata(cpu_wdata),   .mem_axi_wstrb(cpu_wstrb),
      .mem_axi_bvalid(cpu_bvalid),   .mem_axi_bready(cpu_bready),
      .mem_axi_arvalid(cpu_arvalid), .mem_axi_arready(cpu_arready), .mem_axi_araddr(cpu_araddr), .mem_axi_arprot(),
      .mem_axi_rvalid(cpu_rvalid),   .mem_axi_rready(cpu_rready),   .mem_axi_rdata(cpu_rdata),

      .pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(),
      .pcpi_wr(1'b0), .pcpi_rd(32'b0), .pcpi_wait(1'b0), .pcpi_ready(1'b0),

      .irq(irq_bus), .eoi(),

      .trace_valid(), .trace_data()
  );

  // ---- crossbar <-> ROM/RAM/Timer/WDT/UART ----
  wire        rom_awvalid, rom_awready; wire [31:0] rom_awaddr;
  wire        rom_wvalid,  rom_wready;  wire [31:0] rom_wdata; wire [3:0] rom_wstrb;
  wire        rom_bvalid,  rom_bready;  wire [1:0]  rom_bresp;
  wire        rom_arvalid, rom_arready; wire [31:0] rom_araddr;
  wire        rom_rvalid,  rom_rready;  wire [31:0] rom_rdata; wire [1:0] rom_rresp;

  wire        ram_awvalid, ram_awready; wire [31:0] ram_awaddr;
  wire        ram_wvalid,  ram_wready;  wire [31:0] ram_wdata; wire [3:0] ram_wstrb;
  wire        ram_bvalid,  ram_bready;  wire [1:0]  ram_bresp;
  wire        ram_arvalid, ram_arready; wire [31:0] ram_araddr;
  wire        ram_rvalid,  ram_rready;  wire [31:0] ram_rdata; wire [1:0] ram_rresp;

  wire        timer_awvalid, timer_awready; wire [31:0] timer_awaddr;
  wire        timer_wvalid,  timer_wready;  wire [31:0] timer_wdata; wire [3:0] timer_wstrb;
  wire        timer_bvalid,  timer_bready;  wire [1:0]  timer_bresp;
  wire        timer_arvalid, timer_arready; wire [31:0] timer_araddr;
  wire        timer_rvalid,  timer_rready;  wire [31:0] timer_rdata; wire [1:0] timer_rresp;

  wire        wdt_awvalid, wdt_awready; wire [31:0] wdt_awaddr;
  wire        wdt_wvalid,  wdt_wready;  wire [31:0] wdt_wdata; wire [3:0] wdt_wstrb;
  wire        wdt_bvalid,  wdt_bready;  wire [1:0]  wdt_bresp;
  wire        wdt_arvalid, wdt_arready; wire [31:0] wdt_araddr;
  wire        wdt_rvalid,  wdt_rready;  wire [31:0] wdt_rdata; wire [1:0] wdt_rresp;

  wire        uartx_awvalid, uartx_awready; wire [31:0] uartx_awaddr;
  wire        uartx_wvalid,  uartx_wready;  wire [31:0] uartx_wdata; wire [3:0] uartx_wstrb;
  wire        uartx_bvalid,  uartx_bready;  wire [1:0]  uartx_bresp;
  wire        uartx_arvalid, uartx_arready; wire [31:0] uartx_araddr;
  wire        uartx_rvalid,  uartx_rready;  wire [31:0] uartx_rdata; wire [1:0] uartx_rresp;

  wire        i2cx_awvalid, i2cx_awready; wire [31:0] i2cx_awaddr;
  wire        i2cx_wvalid,  i2cx_wready;  wire [31:0] i2cx_wdata; wire [3:0] i2cx_wstrb;
  wire        i2cx_bvalid,  i2cx_bready;  wire [1:0]  i2cx_bresp;
  wire        i2cx_arvalid, i2cx_arready; wire [31:0] i2cx_araddr;
  wire        i2cx_rvalid,  i2cx_rready;  wire [31:0] i2cx_rdata; wire [1:0] i2cx_rresp;

  wire        spix_awvalid, spix_awready; wire [31:0] spix_awaddr;
  wire        spix_wvalid,  spix_wready;  wire [31:0] spix_wdata; wire [3:0] spix_wstrb;
  wire        spix_bvalid,  spix_bready;  wire [1:0]  spix_bresp;
  wire        spix_arvalid, spix_arready; wire [31:0] spix_araddr;
  wire        spix_rvalid,  spix_rready;  wire [31:0] spix_rdata; wire [1:0] spix_rresp;

  axi_lite_xbar u_xbar (
      .clk(clk), .rst(rst),

      .s_awvalid(cpu_awvalid), .s_awready(cpu_awready), .s_awaddr(cpu_awaddr),
      .s_wvalid(cpu_wvalid),   .s_wready(cpu_wready),   .s_wdata(cpu_wdata), .s_wstrb(cpu_wstrb),
      .s_bvalid(cpu_bvalid),   .s_bready(cpu_bready),   .s_bresp(),
      .s_arvalid(cpu_arvalid), .s_arready(cpu_arready), .s_araddr(cpu_araddr),
      .s_rvalid(cpu_rvalid),   .s_rready(cpu_rready),   .s_rdata(cpu_rdata), .s_rresp(),

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

      .uart_awvalid(uartx_awvalid), .uart_awready(uartx_awready), .uart_awaddr(uartx_awaddr),
      .uart_wvalid(uartx_wvalid),   .uart_wready(uartx_wready),   .uart_wdata(uartx_wdata), .uart_wstrb(uartx_wstrb),
      .uart_bvalid(uartx_bvalid),   .uart_bready(uartx_bready),   .uart_bresp(uartx_bresp),
      .uart_arvalid(uartx_arvalid), .uart_arready(uartx_arready), .uart_araddr(uartx_araddr),
      .uart_rvalid(uartx_rvalid),   .uart_rready(uartx_rready),   .uart_rdata(uartx_rdata), .uart_rresp(uartx_rresp),

      .i2c_awvalid(i2cx_awvalid), .i2c_awready(i2cx_awready), .i2c_awaddr(i2cx_awaddr),
      .i2c_wvalid(i2cx_wvalid),   .i2c_wready(i2cx_wready),   .i2c_wdata(i2cx_wdata), .i2c_wstrb(i2cx_wstrb),
      .i2c_bvalid(i2cx_bvalid),   .i2c_bready(i2cx_bready),   .i2c_bresp(i2cx_bresp),
      .i2c_arvalid(i2cx_arvalid), .i2c_arready(i2cx_arready), .i2c_araddr(i2cx_araddr),
      .i2c_rvalid(i2cx_rvalid),   .i2c_rready(i2cx_rready),   .i2c_rdata(i2cx_rdata), .i2c_rresp(i2cx_rresp),

      .spi_awvalid(spix_awvalid), .spi_awready(spix_awready), .spi_awaddr(spix_awaddr),
      .spi_wvalid(spix_wvalid),   .spi_wready(spix_wready),   .spi_wdata(spix_wdata), .spi_wstrb(spix_wstrb),
      .spi_bvalid(spix_bvalid),   .spi_bready(spix_bready),   .spi_bresp(spix_bresp),
      .spi_arvalid(spix_arvalid), .spi_arready(spix_arready), .spi_araddr(spix_araddr),
      .spi_rvalid(spix_rvalid),   .spi_rready(spix_rready),   .spi_rdata(spix_rdata), .spi_rresp(spix_rresp)
  );

  boot_rom #(.HEXFILE(FIRMWARE_HEX)) u_rom (
      .clk(clk), .rst(rst),
      .s_awvalid(rom_awvalid), .s_awready(rom_awready), .s_awaddr(rom_awaddr),
      .s_wvalid(rom_wvalid),   .s_wready(rom_wready),   .s_wdata(rom_wdata), .s_wstrb(rom_wstrb),
      .s_bvalid(rom_bvalid),   .s_bready(rom_bready),   .s_bresp(rom_bresp),
      .s_arvalid(rom_arvalid), .s_arready(rom_arready), .s_araddr(rom_araddr),
      .s_rvalid(rom_rvalid),   .s_rready(rom_rready),   .s_rdata(rom_rdata), .s_rresp(rom_rresp)
  );

  sram u_ram (
      .clk(clk), .rst(rst),
      .s_awvalid(ram_awvalid), .s_awready(ram_awready), .s_awaddr(ram_awaddr),
      .s_wvalid(ram_wvalid),   .s_wready(ram_wready),   .s_wdata(ram_wdata), .s_wstrb(ram_wstrb),
      .s_bvalid(ram_bvalid),   .s_bready(ram_bready),   .s_bresp(ram_bresp),
      .s_arvalid(ram_arvalid), .s_arready(ram_arready), .s_araddr(ram_araddr),
      .s_rvalid(ram_rvalid),   .s_rready(ram_rready),   .s_rdata(ram_rdata), .s_rresp(ram_rresp)
  );

  timer u_timer (
      .clk(clk), .rst(rst),
      .s_awvalid(timer_awvalid), .s_awready(timer_awready), .s_awaddr(timer_awaddr),
      .s_wvalid(timer_wvalid),   .s_wready(timer_wready),   .s_wdata(timer_wdata), .s_wstrb(timer_wstrb),
      .s_bvalid(timer_bvalid),   .s_bready(timer_bready),   .s_bresp(timer_bresp),
      .s_arvalid(timer_arvalid), .s_arready(timer_arready), .s_araddr(timer_araddr),
      .s_rvalid(timer_rvalid),   .s_rready(timer_rready),   .s_rdata(timer_rdata), .s_rresp(timer_rresp),
      .irq(timer_irq)
  );

  watchdog u_wdt (
      .clk(clk), .rst(rst),
      .s_awvalid(wdt_awvalid), .s_awready(wdt_awready), .s_awaddr(wdt_awaddr),
      .s_wvalid(wdt_wvalid),   .s_wready(wdt_wready),   .s_wdata(wdt_wdata), .s_wstrb(wdt_wstrb),
      .s_bvalid(wdt_bvalid),   .s_bready(wdt_bready),   .s_bresp(wdt_bresp),
      .s_arvalid(wdt_arvalid), .s_arready(wdt_arready), .s_araddr(wdt_araddr),
      .s_rvalid(wdt_rvalid),   .s_rready(wdt_rready),   .s_rdata(wdt_rdata), .s_rresp(wdt_rresp),
      .irq(wdt_irq),
      .wdog_reset_req(wdog_reset_req)
  );

  uart u_uart (
      .clk(clk), .rst(rst),
      .s_awvalid(uartx_awvalid), .s_awready(uartx_awready), .s_awaddr(uartx_awaddr),
      .s_wvalid(uartx_wvalid),   .s_wready(uartx_wready),   .s_wdata(uartx_wdata), .s_wstrb(uartx_wstrb),
      .s_bvalid(uartx_bvalid),   .s_bready(uartx_bready),   .s_bresp(uartx_bresp),
      .s_arvalid(uartx_arvalid), .s_arready(uartx_arready), .s_araddr(uartx_araddr),
      .s_rvalid(uartx_rvalid),   .s_rready(uartx_rready),   .s_rdata(uartx_rdata), .s_rresp(uartx_rresp),
      .tx(uart_tx)
  );

  i2c_master u_i2c (
      .clk(clk), .rst(rst),
      .s_awvalid(i2cx_awvalid), .s_awready(i2cx_awready), .s_awaddr(i2cx_awaddr),
      .s_wvalid(i2cx_wvalid),   .s_wready(i2cx_wready),   .s_wdata(i2cx_wdata), .s_wstrb(i2cx_wstrb),
      .s_bvalid(i2cx_bvalid),   .s_bready(i2cx_bready),   .s_bresp(i2cx_bresp),
      .s_arvalid(i2cx_arvalid), .s_arready(i2cx_arready), .s_araddr(i2cx_araddr),
      .s_rvalid(i2cx_rvalid),   .s_rready(i2cx_rready),   .s_rdata(i2cx_rdata), .s_rresp(i2cx_rresp),
      .scl(i2c_scl), .sda(i2c_sda),
      .irq(i2c_irq)
  );

  spi_master u_spi (
      .clk(clk), .rst(rst),
      .s_awvalid(spix_awvalid), .s_awready(spix_awready), .s_awaddr(spix_awaddr),
      .s_wvalid(spix_wvalid),   .s_wready(spix_wready),   .s_wdata(spix_wdata), .s_wstrb(spix_wstrb),
      .s_bvalid(spix_bvalid),   .s_bready(spix_bready),   .s_bresp(spix_bresp),
      .s_arvalid(spix_arvalid), .s_arready(spix_arready), .s_araddr(spix_araddr),
      .s_rvalid(spix_rvalid),   .s_rready(spix_rready),   .s_rdata(spix_rdata), .s_rresp(spix_rresp),
      .sclk(spi_sclk), .mosi(spi_mosi), .miso(spi_miso), .cs_n(spi_cs_n),
      .irq(spi_irq)
  );
endmodule

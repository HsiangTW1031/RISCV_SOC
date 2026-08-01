`include "axi_lite.vh"

// Top-level SoC integration — Phase 2 scope: CPU + crossbar + ROM/RAM/UART
// + Timer + Watchdog, interrupts enabled. I2C/SPI/AES/JTAG land in later
// phases (see docs/phase_plan.md).
//
// Known limitation (unchanged from Phase 1): picorv32_axi's mem_axi_b*/r*
// ports have no BRESP/RRESP pins at all — this adapter never checks for
// SLVERR. An unmapped-address bug in firmware won't hang the bus, but it
// also won't be caught by the CPU itself.
//
// IRQ map (matches docs/phase_plan.md): irq[3] = Timer EXPIRED,
// irq[4] = Watchdog WARNING. irq[0]/irq[1] are PicoRV32's own built-in
// bus-error/illegal-instruction traps; everything else is unused this
// phase. wdog_reset_req is exposed at the top level for observability but
// is NOT yet wired to actually reset the SoC — that's a deliberate,
// documented scope cut for Phase 2 (see docs/phase_plan.md risk notes).
module soc_top #(
    parameter FIRMWARE_HEX = "firmware.hex"
) (
    input  wire clk,
    input  wire rst,
    output wire uart_tx,
    output wire wdog_reset_req
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

  wire        timer_irq, wdt_irq;
  wire [31:0] irq_bus = {27'b0, wdt_irq, timer_irq, 3'b0};
  // bit4=wdt_irq, bit3=timer_irq, bits[2:0] reserved for PicoRV32's own
  // bus-error/illegal-instruction/(unused) traps.

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
      .uart_rvalid(uartx_rvalid),   .uart_rready(uartx_rready),   .uart_rdata(uartx_rdata), .uart_rresp(uartx_rresp)
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
endmodule

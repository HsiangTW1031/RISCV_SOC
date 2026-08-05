`include "axi_lite.vh"

// Top-level SoC integration — Phase 5 scope: CPU + crossbar + ROM/RAM/UART
// + Timer + Watchdog + I2C + SPI + AES + a JTAG debug bridge, interrupts
// enabled. The crossbar is now a genuine 2-master design (CPU=s0, JTAG
// bridge=s1, fixed priority favoring the CPU on contention -- see
// axi_lite_xbar.v's header comment).
//
// `tck`/`tms`/`tdi`/`tdo` are a real, separate clock domain from `clk`
// (matching actual JTAG hardware). `resetn` itself is treated as coming
// from a genuinely asynchronous external source (a real POR circuit or
// reset button would be) -- feeding it directly into either domain's
// synchronous logic risks a metastable release edge, the reset-domain
// equivalent of the CDC problem `jtag_axi_bridge.v` already handles for
// data (see docs/verification/cdc_methodology.md). `resetn_clk_sync`/`resetn_tck_sync`
// below are each domain's own "asynchronous assert, synchronous
// de-assert" 2-flop reset synchronizer -- every clk-domain instance uses
// resetn_clk_sync, every tck-domain one (jtag_tap/jtag_dtm, and
// jtag_axi_bridge's tck_resetn input) uses resetn_tck_sync. This is the
// one deliberate exception to this project's synchronous-reset
// convention: a reset synchronizer's own flops must have `resetn` in
// their sensitivity list to assert immediately, which is exactly what
// it's for.
//
// Known limitation (unchanged from Phase 1): picorv32_axi's mem_axi_b*/r*
// ports have no BRESP/RRESP pins at all — this adapter never checks the
// response code at all, DECERR included. An unmapped-address bug in
// firmware won't hang the bus, but it also won't be caught by the CPU
// itself via the response channel — which is exactly why axi_lite_xbar's
// v2.2.0 diagnostic CSR + irq[9] (below) exists: it's the only way this
// SoC actually surfaces a decode-miss to firmware.
//
// IRQ map (matches docs/phase_plan.md): irq[3] = Timer EXPIRED,
// irq[4] = Watchdog WARNING, irq[5] = I2C transfer done, irq[6] = SPI
// transfer done, irq[7] = AES block done, irq[9] = axi_lite_xbar decode
// miss (v2.2.0 — see that module's header comment and
// docs/memory_map.md for the CSR that goes with it). irq[0]/irq[1] are
// PicoRV32's own built-in bus-error/illegal-instruction traps; irq[8] is
// dma_irq (see below); everything else is unused this phase.
// wdog_reset_req is exposed at the top level for observability but is
// NOT yet wired to actually reset the SoC — that's a deliberate,
// documented scope cut (see docs/phase_plan.md risk notes).
module soc_top #(
    parameter FIRMWARE_HEX = "firmware.hex"
) (
    input  wire clk,
    input  wire resetn,
    output wire uart_tx,
    output wire wdog_reset_req,
    output wire i2c_scl,
    inout  wire i2c_sda,
    output wire spi_sclk,
    output wire spi_mosi,
    input  wire spi_miso,
    output wire spi_cs_n,
    input  wire tck,
    input  wire tms,
    input  wire tdi,
    output wire tdo
);
  // ---- Reset synchronizers, one per clock domain (see header comment) ----
  reg resetn_clk_meta, resetn_clk_sync;
  always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      resetn_clk_meta <= 1'b0;
      resetn_clk_sync <= 1'b0;
    end else begin
      resetn_clk_meta <= 1'b1;
      resetn_clk_sync <= resetn_clk_meta;
    end
  end

  reg resetn_tck_meta, resetn_tck_sync;
  always @(posedge tck or negedge resetn) begin
    if (!resetn) begin
      resetn_tck_meta <= 1'b0;
      resetn_tck_sync <= 1'b0;
    end else begin
      resetn_tck_meta <= 1'b1;
      resetn_tck_sync <= resetn_tck_meta;
    end
  end

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

  wire        timer_irq, wdt_irq, i2c_irq, spi_irq, aes_irq, dma_irq;
  wire        xbar_decerr_irq;
  wire [31:0] irq_bus = {22'b0, xbar_decerr_irq, dma_irq, aes_irq, spi_irq, i2c_irq, wdt_irq, timer_irq, 3'b0};
  // bit9=xbar_decerr_irq (v2.2.0, axi_lite_xbar decode-miss, see that
  // module's header + docs/memory_map.md), bit8=dma_irq (Phase 6, whole
  // multi-block DMA+AES operation done), bit7=aes_irq, bit6=spi_irq,
  // bit5=i2c_irq, bit4=wdt_irq, bit3=timer_irq, bits[2:0] reserved for
  // PicoRV32's own bus-error/illegal-instruction/(unused) traps.

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
      .resetn(resetn_clk_sync),
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

  wire        aesx_awvalid, aesx_awready; wire [31:0] aesx_awaddr;
  wire        aesx_wvalid,  aesx_wready;  wire [31:0] aesx_wdata; wire [3:0] aesx_wstrb;
  wire        aesx_bvalid,  aesx_bready;  wire [1:0]  aesx_bresp;
  wire        aesx_arvalid, aesx_arready; wire [31:0] aesx_araddr;
  wire        aesx_rvalid,  aesx_rready;  wire [31:0] aesx_rdata; wire [1:0] aesx_rresp;

  // ---- crossbar <-> dma_engine's AXI4-Lite control port (Phase 6) ----
  wire        dmax_awvalid, dmax_awready; wire [31:0] dmax_awaddr;
  wire        dmax_wvalid,  dmax_wready;  wire [31:0] dmax_wdata; wire [3:0] dmax_wstrb;
  wire        dmax_bvalid,  dmax_bready;  wire [1:0]  dmax_bresp;
  wire        dmax_arvalid, dmax_arready; wire [31:0] dmax_araddr;
  wire        dmax_rvalid,  dmax_rready;  wire [31:0] dmax_rdata; wire [1:0] dmax_rresp;

  // ---- dma_engine's own AXI4 burst master <-> its private dma_ram.v
  // (NOT routed through the AXI4-Lite crossbar -- see dma_ram.v/
  // dma_engine.v headers for the architectural rationale) ----
  wire        dma_m_awvalid, dma_m_awready; wire [31:0] dma_m_awaddr;
  wire [7:0]  dma_m_awlen; wire [2:0] dma_m_awsize; wire [1:0] dma_m_awburst;
  wire        dma_m_wvalid, dma_m_wready; wire [31:0] dma_m_wdata; wire [3:0] dma_m_wstrb; wire dma_m_wlast;
  wire        dma_m_bvalid, dma_m_bready; wire [1:0] dma_m_bresp;
  wire        dma_m_arvalid, dma_m_arready; wire [31:0] dma_m_araddr;
  wire [7:0]  dma_m_arlen; wire [2:0] dma_m_arsize; wire [1:0] dma_m_arburst;
  wire        dma_m_rvalid, dma_m_rready; wire [31:0] dma_m_rdata; wire [1:0] dma_m_rresp; wire dma_m_rlast;

  // ---- JTAG debug bridge's AXI4-Lite master port (crossbar's s1) ----
  wire        jtag_awvalid, jtag_awready; wire [31:0] jtag_awaddr;
  wire        jtag_wvalid,  jtag_wready;  wire [31:0] jtag_wdata; wire [3:0] jtag_wstrb;
  wire        jtag_bvalid,  jtag_bready;  wire [1:0]  jtag_bresp;
  wire        jtag_arvalid, jtag_arready; wire [31:0] jtag_araddr;
  wire        jtag_rvalid,  jtag_rready;  wire [31:0] jtag_rdata; wire [1:0] jtag_rresp;

  axi_lite_xbar u_xbar (
      .clk(clk), .resetn(resetn_clk_sync),
      .decerr_irq(xbar_decerr_irq),

      .s0_awvalid(cpu_awvalid), .s0_awready(cpu_awready), .s0_awaddr(cpu_awaddr),
      .s0_wvalid(cpu_wvalid),   .s0_wready(cpu_wready),   .s0_wdata(cpu_wdata), .s0_wstrb(cpu_wstrb),
      .s0_bvalid(cpu_bvalid),   .s0_bready(cpu_bready),   .s0_bresp(),
      .s0_arvalid(cpu_arvalid), .s0_arready(cpu_arready), .s0_araddr(cpu_araddr),
      .s0_rvalid(cpu_rvalid),   .s0_rready(cpu_rready),   .s0_rdata(cpu_rdata), .s0_rresp(),

      .s1_awvalid(jtag_awvalid), .s1_awready(jtag_awready), .s1_awaddr(jtag_awaddr),
      .s1_wvalid(jtag_wvalid),   .s1_wready(jtag_wready),   .s1_wdata(jtag_wdata), .s1_wstrb(jtag_wstrb),
      .s1_bvalid(jtag_bvalid),   .s1_bready(jtag_bready),   .s1_bresp(jtag_bresp),
      .s1_arvalid(jtag_arvalid), .s1_arready(jtag_arready), .s1_araddr(jtag_araddr),
      .s1_rvalid(jtag_rvalid),   .s1_rready(jtag_rready),   .s1_rdata(jtag_rdata), .s1_rresp(jtag_rresp),

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
      .spi_rvalid(spix_rvalid),   .spi_rready(spix_rready),   .spi_rdata(spix_rdata), .spi_rresp(spix_rresp),

      .aes_awvalid(aesx_awvalid), .aes_awready(aesx_awready), .aes_awaddr(aesx_awaddr),
      .aes_wvalid(aesx_wvalid),   .aes_wready(aesx_wready),   .aes_wdata(aesx_wdata), .aes_wstrb(aesx_wstrb),
      .aes_bvalid(aesx_bvalid),   .aes_bready(aesx_bready),   .aes_bresp(aesx_bresp),
      .aes_arvalid(aesx_arvalid), .aes_arready(aesx_arready), .aes_araddr(aesx_araddr),
      .aes_rvalid(aesx_rvalid),   .aes_rready(aesx_rready),   .aes_rdata(aesx_rdata), .aes_rresp(aesx_rresp),

      .dma_awvalid(dmax_awvalid), .dma_awready(dmax_awready), .dma_awaddr(dmax_awaddr),
      .dma_wvalid(dmax_wvalid),   .dma_wready(dmax_wready),   .dma_wdata(dmax_wdata), .dma_wstrb(dmax_wstrb),
      .dma_bvalid(dmax_bvalid),   .dma_bready(dmax_bready),   .dma_bresp(dmax_bresp),
      .dma_arvalid(dmax_arvalid), .dma_arready(dmax_arready), .dma_araddr(dmax_araddr),
      .dma_rvalid(dmax_rvalid),   .dma_rready(dmax_rready),   .dma_rdata(dmax_rdata), .dma_rresp(dmax_rresp)
  );

  boot_rom #(.HEXFILE(FIRMWARE_HEX)) u_rom (
      .clk(clk), .resetn(resetn_clk_sync),
      .s_awvalid(rom_awvalid), .s_awready(rom_awready), .s_awaddr(rom_awaddr),
      .s_wvalid(rom_wvalid),   .s_wready(rom_wready),   .s_wdata(rom_wdata), .s_wstrb(rom_wstrb),
      .s_bvalid(rom_bvalid),   .s_bready(rom_bready),   .s_bresp(rom_bresp),
      .s_arvalid(rom_arvalid), .s_arready(rom_arready), .s_araddr(rom_araddr),
      .s_rvalid(rom_rvalid),   .s_rready(rom_rready),   .s_rdata(rom_rdata), .s_rresp(rom_rresp)
  );

  sram u_ram (
      .clk(clk), .resetn(resetn_clk_sync),
      .s_awvalid(ram_awvalid), .s_awready(ram_awready), .s_awaddr(ram_awaddr),
      .s_wvalid(ram_wvalid),   .s_wready(ram_wready),   .s_wdata(ram_wdata), .s_wstrb(ram_wstrb),
      .s_bvalid(ram_bvalid),   .s_bready(ram_bready),   .s_bresp(ram_bresp),
      .s_arvalid(ram_arvalid), .s_arready(ram_arready), .s_araddr(ram_araddr),
      .s_rvalid(ram_rvalid),   .s_rready(ram_rready),   .s_rdata(ram_rdata), .s_rresp(ram_rresp)
  );

  timer u_timer (
      .clk(clk), .resetn(resetn_clk_sync),
      .s_awvalid(timer_awvalid), .s_awready(timer_awready), .s_awaddr(timer_awaddr),
      .s_wvalid(timer_wvalid),   .s_wready(timer_wready),   .s_wdata(timer_wdata), .s_wstrb(timer_wstrb),
      .s_bvalid(timer_bvalid),   .s_bready(timer_bready),   .s_bresp(timer_bresp),
      .s_arvalid(timer_arvalid), .s_arready(timer_arready), .s_araddr(timer_araddr),
      .s_rvalid(timer_rvalid),   .s_rready(timer_rready),   .s_rdata(timer_rdata), .s_rresp(timer_rresp),
      .irq(timer_irq)
  );

  watchdog u_wdt (
      .clk(clk), .resetn(resetn_clk_sync),
      .s_awvalid(wdt_awvalid), .s_awready(wdt_awready), .s_awaddr(wdt_awaddr),
      .s_wvalid(wdt_wvalid),   .s_wready(wdt_wready),   .s_wdata(wdt_wdata), .s_wstrb(wdt_wstrb),
      .s_bvalid(wdt_bvalid),   .s_bready(wdt_bready),   .s_bresp(wdt_bresp),
      .s_arvalid(wdt_arvalid), .s_arready(wdt_arready), .s_araddr(wdt_araddr),
      .s_rvalid(wdt_rvalid),   .s_rready(wdt_rready),   .s_rdata(wdt_rdata), .s_rresp(wdt_rresp),
      .irq(wdt_irq),
      .wdog_reset_req(wdog_reset_req)
  );

  uart u_uart (
      .clk(clk), .resetn(resetn_clk_sync),
      .s_awvalid(uartx_awvalid), .s_awready(uartx_awready), .s_awaddr(uartx_awaddr),
      .s_wvalid(uartx_wvalid),   .s_wready(uartx_wready),   .s_wdata(uartx_wdata), .s_wstrb(uartx_wstrb),
      .s_bvalid(uartx_bvalid),   .s_bready(uartx_bready),   .s_bresp(uartx_bresp),
      .s_arvalid(uartx_arvalid), .s_arready(uartx_arready), .s_araddr(uartx_araddr),
      .s_rvalid(uartx_rvalid),   .s_rready(uartx_rready),   .s_rdata(uartx_rdata), .s_rresp(uartx_rresp),
      .tx(uart_tx)
  );

  i2c_master u_i2c (
      .clk(clk), .resetn(resetn_clk_sync),
      .s_awvalid(i2cx_awvalid), .s_awready(i2cx_awready), .s_awaddr(i2cx_awaddr),
      .s_wvalid(i2cx_wvalid),   .s_wready(i2cx_wready),   .s_wdata(i2cx_wdata), .s_wstrb(i2cx_wstrb),
      .s_bvalid(i2cx_bvalid),   .s_bready(i2cx_bready),   .s_bresp(i2cx_bresp),
      .s_arvalid(i2cx_arvalid), .s_arready(i2cx_arready), .s_araddr(i2cx_araddr),
      .s_rvalid(i2cx_rvalid),   .s_rready(i2cx_rready),   .s_rdata(i2cx_rdata), .s_rresp(i2cx_rresp),
      .scl(i2c_scl), .sda(i2c_sda),
      .irq(i2c_irq)
  );

  spi_master u_spi (
      .clk(clk), .resetn(resetn_clk_sync),
      .s_awvalid(spix_awvalid), .s_awready(spix_awready), .s_awaddr(spix_awaddr),
      .s_wvalid(spix_wvalid),   .s_wready(spix_wready),   .s_wdata(spix_wdata), .s_wstrb(spix_wstrb),
      .s_bvalid(spix_bvalid),   .s_bready(spix_bready),   .s_bresp(spix_bresp),
      .s_arvalid(spix_arvalid), .s_arready(spix_arready), .s_araddr(spix_araddr),
      .s_rvalid(spix_rvalid),   .s_rready(spix_rready),   .s_rdata(spix_rdata), .s_rresp(spix_rresp),
      .sclk(spi_sclk), .mosi(spi_mosi), .miso(spi_miso), .cs_n(spi_cs_n),
      .irq(spi_irq)
  );

  aes u_aes (
      .clk(clk), .resetn(resetn_clk_sync),
      .s_awvalid(aesx_awvalid), .s_awready(aesx_awready), .s_awaddr(aesx_awaddr),
      .s_wvalid(aesx_wvalid),   .s_wready(aesx_wready),   .s_wdata(aesx_wdata), .s_wstrb(aesx_wstrb),
      .s_bvalid(aesx_bvalid),   .s_bready(aesx_bready),   .s_bresp(aesx_bresp),
      .s_arvalid(aesx_arvalid), .s_arready(aesx_arready), .s_araddr(aesx_araddr),
      .s_rvalid(aesx_rvalid),   .s_rready(aesx_rready),   .s_rdata(aesx_rdata), .s_rresp(aesx_rresp),
      .irq(aes_irq)
  );

  // ---- Phase 6: DMA engine + its private burst-capable memory ----
  dma_engine u_dma (
      .clk(clk), .resetn(resetn_clk_sync),
      .s_awvalid(dmax_awvalid), .s_awready(dmax_awready), .s_awaddr(dmax_awaddr),
      .s_wvalid(dmax_wvalid),   .s_wready(dmax_wready),   .s_wdata(dmax_wdata), .s_wstrb(dmax_wstrb),
      .s_bvalid(dmax_bvalid),   .s_bready(dmax_bready),   .s_bresp(dmax_bresp),
      .s_arvalid(dmax_arvalid), .s_arready(dmax_arready), .s_araddr(dmax_araddr),
      .s_rvalid(dmax_rvalid),   .s_rready(dmax_rready),   .s_rdata(dmax_rdata), .s_rresp(dmax_rresp),

      .m_awvalid(dma_m_awvalid), .m_awready(dma_m_awready), .m_awaddr(dma_m_awaddr), .m_awlen(dma_m_awlen), .m_awsize(dma_m_awsize), .m_awburst(dma_m_awburst),
      .m_wvalid(dma_m_wvalid),   .m_wready(dma_m_wready),   .m_wdata(dma_m_wdata), .m_wstrb(dma_m_wstrb), .m_wlast(dma_m_wlast),
      .m_bvalid(dma_m_bvalid),   .m_bready(dma_m_bready),   .m_bresp(dma_m_bresp),
      .m_arvalid(dma_m_arvalid), .m_arready(dma_m_arready), .m_araddr(dma_m_araddr), .m_arlen(dma_m_arlen), .m_arsize(dma_m_arsize), .m_arburst(dma_m_arburst),
      .m_rvalid(dma_m_rvalid),   .m_rready(dma_m_rready),   .m_rdata(dma_m_rdata), .m_rresp(dma_m_rresp), .m_rlast(dma_m_rlast),

      .irq(dma_irq)
  );

  dma_ram u_dma_ram (
      .clk(clk), .resetn(resetn_clk_sync),
      .s_awvalid(dma_m_awvalid), .s_awready(dma_m_awready), .s_awaddr(dma_m_awaddr), .s_awlen(dma_m_awlen), .s_awsize(dma_m_awsize), .s_awburst(dma_m_awburst),
      .s_wvalid(dma_m_wvalid),   .s_wready(dma_m_wready),   .s_wdata(dma_m_wdata), .s_wstrb(dma_m_wstrb), .s_wlast(dma_m_wlast),
      .s_bvalid(dma_m_bvalid),   .s_bready(dma_m_bready),   .s_bresp(dma_m_bresp),
      .s_arvalid(dma_m_arvalid), .s_arready(dma_m_arready), .s_araddr(dma_m_araddr), .s_arlen(dma_m_arlen), .s_arsize(dma_m_arsize), .s_arburst(dma_m_arburst),
      .s_rvalid(dma_m_rvalid),   .s_rready(dma_m_rready),   .s_rdata(dma_m_rdata), .s_rresp(dma_m_rresp), .s_rlast(dma_m_rlast)
  );

  // ---- JTAG debug bridge: the crossbar's second master ----
  wire        jtag_start_pulse_tck, jtag_rw_tck;
  wire [31:0] jtag_addr_tck, jtag_wdata_tck;
  wire        jtag_busy_tck, jtag_resp_ok_tck;
  wire [31:0] jtag_rdata_tck;

  jtag_dtm u_jtag_dtm (
      .tck(tck), .resetn(resetn_tck_sync), .tms(tms), .tdi(tdi), .tdo(tdo),
      .bridge_busy_tck(jtag_busy_tck), .bridge_resp_ok_tck(jtag_resp_ok_tck), .bridge_rdata_tck(jtag_rdata_tck),
      .start_pulse_tck(jtag_start_pulse_tck), .rw_tck(jtag_rw_tck), .addr_tck(jtag_addr_tck), .wdata_tck(jtag_wdata_tck)
  );

  jtag_axi_bridge u_jtag_bridge (
      .clk(clk), .resetn(resetn_clk_sync), .tck(tck), .tck_resetn(resetn_tck_sync),
      .start_pulse_tck(jtag_start_pulse_tck), .rw_tck(jtag_rw_tck), .addr_tck(jtag_addr_tck), .wdata_tck(jtag_wdata_tck),
      .busy_tck(jtag_busy_tck), .resp_ok_tck(jtag_resp_ok_tck), .rdata_tck(jtag_rdata_tck),
      .m_awvalid(jtag_awvalid), .m_awready(jtag_awready), .m_awaddr(jtag_awaddr),
      .m_wvalid(jtag_wvalid),   .m_wready(jtag_wready),   .m_wdata(jtag_wdata), .m_wstrb(jtag_wstrb),
      .m_bvalid(jtag_bvalid),   .m_bready(jtag_bready),   .m_bresp(jtag_bresp),
      .m_arvalid(jtag_arvalid), .m_arready(jtag_arready), .m_araddr(jtag_araddr),
      .m_rvalid(jtag_rvalid),   .m_rready(jtag_rready),   .m_rdata(jtag_rdata), .m_rresp(jtag_rresp)
  );
endmodule

`include "axi_lite.vh"
`include "addr_map.vh"

// AXI4-Lite crossbar — 2 masters (s0 = CPU, s1 = the JTAG debug bridge) x
// 9 slaves (ROM, RAM, Timer, Watchdog, UART, I2C, SPI, AES, and (Phase 6)
// the DMA engine's control port -- DMA's own AXI4 burst master talks
// directly to dma_ram.v, not through here). Hand-written (the project's
// core differentiator); Verilog-2001 only.
//
// Arbitration: fixed priority, s0 (CPU) wins on simultaneous contention.
// This is a deliberate choice, not an oversight -- s1 is a debug/JTAG
// path, used occasionally and not latency-sensitive the way real-time
// CPU execution is, so favoring the CPU on a tie is the safer default
// (round-robin fairness isn't needed for "occasional debug access", and
// would only add complexity this project doesn't need). The grant is
// decided independently for the write and read channel groups (a master
// can, for instance, win the write arbitration while the other wins read,
// simultaneously) and is LOCKED for the full duration of whichever
// transaction won it -- decided once, while the pipeline is genuinely
// idle (`w_open`/`r_open` below), and held constant through issue/
// response so a transaction can never have its upstream identity change
// mid-flight. The internal decode/routing logic below (downstream side)
// is completely unchanged from the single-master version -- arbitration
// is purely a mux layer in front of it that presents whichever master
// won as "the" upstream request.
//
// Single-outstanding per channel group (write / read independently), which
// matches picorv32_axi_adapter's own behavior (it asserts AWVALID and
// WVALID together but each can be acknowledged on a different cycle, and it
// never issues a second transaction of the same kind before the first
// completes) — but this crossbar does not assume that: AW and W are
// latched independently on the upstream side, and re-driven independently
// on the downstream side, so it stays correct even against a slave (or a
// future master) that accepts AW and W on different cycles.
//
// Unmapped addresses never touch a real slave's valid signals: they're
// answered directly with SLVERR by the crossbar itself.
module axi_lite_xbar (
    input  wire        clk,
    input  wire        rst,

    // ---- upstream master 0: the CPU ----
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

    // ---- upstream master 1: the JTAG-AXI debug bridge ----
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
    output wire [1:0]  s1_rresp,

    // ---- downstream slave: ROM ----
    output reg          rom_awvalid, input wire rom_awready, output reg [31:0] rom_awaddr,
    output reg          rom_wvalid,  input wire rom_wready,  output reg [31:0] rom_wdata, output reg [3:0] rom_wstrb,
    input  wire         rom_bvalid,  output reg rom_bready,  input wire [1:0]  rom_bresp,
    output reg          rom_arvalid, input wire rom_arready, output reg [31:0] rom_araddr,
    input  wire         rom_rvalid,  output reg rom_rready,  input wire [31:0] rom_rdata, input wire [1:0] rom_rresp,

    // ---- downstream slave: RAM ----
    output reg          ram_awvalid, input wire ram_awready, output reg [31:0] ram_awaddr,
    output reg          ram_wvalid,  input wire ram_wready,  output reg [31:0] ram_wdata, output reg [3:0] ram_wstrb,
    input  wire         ram_bvalid,  output reg ram_bready,  input wire [1:0]  ram_bresp,
    output reg          ram_arvalid, input wire ram_arready, output reg [31:0] ram_araddr,
    input  wire         ram_rvalid,  output reg ram_rready,  input wire [31:0] ram_rdata, input wire [1:0] ram_rresp,

    // ---- downstream slave: Timer ----
    output reg          timer_awvalid, input wire timer_awready, output reg [31:0] timer_awaddr,
    output reg          timer_wvalid,  input wire timer_wready,  output reg [31:0] timer_wdata, output reg [3:0] timer_wstrb,
    input  wire         timer_bvalid,  output reg timer_bready,  input wire [1:0]  timer_bresp,
    output reg          timer_arvalid, input wire timer_arready, output reg [31:0] timer_araddr,
    input  wire         timer_rvalid,  output reg timer_rready,  input wire [31:0] timer_rdata, input wire [1:0] timer_rresp,

    // ---- downstream slave: Watchdog ----
    output reg          wdt_awvalid, input wire wdt_awready, output reg [31:0] wdt_awaddr,
    output reg          wdt_wvalid,  input wire wdt_wready,  output reg [31:0] wdt_wdata, output reg [3:0] wdt_wstrb,
    input  wire         wdt_bvalid,  output reg wdt_bready,  input wire [1:0]  wdt_bresp,
    output reg          wdt_arvalid, input wire wdt_arready, output reg [31:0] wdt_araddr,
    input  wire         wdt_rvalid,  output reg wdt_rready,  input wire [31:0] wdt_rdata, input wire [1:0] wdt_rresp,

    // ---- downstream slave: UART ----
    output reg          uart_awvalid, input wire uart_awready, output reg [31:0] uart_awaddr,
    output reg          uart_wvalid,  input wire uart_wready,  output reg [31:0] uart_wdata, output reg [3:0] uart_wstrb,
    input  wire         uart_bvalid,  output reg uart_bready,  input wire [1:0]  uart_bresp,
    output reg          uart_arvalid, input wire uart_arready, output reg [31:0] uart_araddr,
    input  wire         uart_rvalid,  output reg uart_rready,  input wire [31:0] uart_rdata, input wire [1:0] uart_rresp,

    // ---- downstream slave: I2C ----
    output reg          i2c_awvalid, input wire i2c_awready, output reg [31:0] i2c_awaddr,
    output reg          i2c_wvalid,  input wire i2c_wready,  output reg [31:0] i2c_wdata, output reg [3:0] i2c_wstrb,
    input  wire         i2c_bvalid,  output reg i2c_bready,  input wire [1:0]  i2c_bresp,
    output reg          i2c_arvalid, input wire i2c_arready, output reg [31:0] i2c_araddr,
    input  wire         i2c_rvalid,  output reg i2c_rready,  input wire [31:0] i2c_rdata, input wire [1:0] i2c_rresp,

    // ---- downstream slave: SPI ----
    output reg          spi_awvalid, input wire spi_awready, output reg [31:0] spi_awaddr,
    output reg          spi_wvalid,  input wire spi_wready,  output reg [31:0] spi_wdata, output reg [3:0] spi_wstrb,
    input  wire         spi_bvalid,  output reg spi_bready,  input wire [1:0]  spi_bresp,
    output reg          spi_arvalid, input wire spi_arready, output reg [31:0] spi_araddr,
    input  wire         spi_rvalid,  output reg spi_rready,  input wire [31:0] spi_rdata, input wire [1:0] spi_rresp,

    // ---- downstream slave: AES ----
    output reg          aes_awvalid, input wire aes_awready, output reg [31:0] aes_awaddr,
    output reg          aes_wvalid,  input wire aes_wready,  output reg [31:0] aes_wdata, output reg [3:0] aes_wstrb,
    input  wire         aes_bvalid,  output reg aes_bready,  input wire [1:0]  aes_bresp,
    output reg          aes_arvalid, input wire aes_arready, output reg [31:0] aes_araddr,
    input  wire         aes_rvalid,  output reg aes_rready,  input wire [31:0] aes_rdata, input wire [1:0] aes_rresp,

    // ---- downstream slave: DMA engine's AXI4-Lite control port (its
    // AXI4 burst master port to dma_ram is NOT routed through this
    // crossbar -- see dma_ram.v/dma_engine.v headers) ----
    output reg          dma_awvalid, input wire dma_awready, output reg [31:0] dma_awaddr,
    output reg          dma_wvalid,  input wire dma_wready,  output reg [31:0] dma_wdata, output reg [3:0] dma_wstrb,
    input  wire         dma_bvalid,  output reg dma_bready,  input wire [1:0]  dma_bresp,
    output reg          dma_arvalid, input wire dma_arready, output reg [31:0] dma_araddr,
    input  wire         dma_rvalid,  output reg dma_rready,  input wire [31:0] dma_rdata, input wire [1:0] dma_rresp
);

  // slave-select width sized for the full addr_map.vh SLAVE_* numbering
  // (up to SLAVE_ERR=8).
  localparam SEL_W = 4;

  function [SEL_W-1:0] decode_addr;
    input [31:0] addr;
    begin
      if (addr[31:28] == `ADDR_REGION_ROM)
        decode_addr = `SLAVE_ROM;
      else if (addr[31:28] == `ADDR_REGION_RAM)
        decode_addr = `SLAVE_RAM;
      else if (addr[31:28] == `ADDR_REGION_PERIPH && addr[15:12] == `ADDR_PERIPH_TIMER)
        decode_addr = `SLAVE_TIMER;
      else if (addr[31:28] == `ADDR_REGION_PERIPH && addr[15:12] == `ADDR_PERIPH_WDT)
        decode_addr = `SLAVE_WDT;
      else if (addr[31:28] == `ADDR_REGION_PERIPH && addr[15:12] == `ADDR_PERIPH_UART)
        decode_addr = `SLAVE_UART;
      else if (addr[31:28] == `ADDR_REGION_PERIPH && addr[15:12] == `ADDR_PERIPH_I2C)
        decode_addr = `SLAVE_I2C;
      else if (addr[31:28] == `ADDR_REGION_PERIPH && addr[15:12] == `ADDR_PERIPH_SPI)
        decode_addr = `SLAVE_SPI;
      else if (addr[31:28] == `ADDR_REGION_PERIPH && addr[15:12] == `ADDR_PERIPH_AES)
        decode_addr = `SLAVE_AES;
      else if (addr[31:28] == `ADDR_REGION_PERIPH && addr[15:12] == `ADDR_PERIPH_DMA)
        decode_addr = `SLAVE_DMA;
      else
        decode_addr = `SLAVE_ERR;
    end
  endfunction

  // =====================================================================
  // WRITE PATH
  // =====================================================================
  localparam W_IDLE    = 2'd0; // latching AW/W from upstream independently
  localparam W_ISSUE   = 2'd1; // driving AW/W to the selected slave
  localparam W_WAIT_B  = 2'd2; // waiting for the slave's B response
  localparam W_RESP    = 2'd3; // presenting B response upstream

  reg [1:0]       w_state;
  reg [SEL_W-1:0] w_sel;
  reg [31:0] w_addr_lat, w_data_lat;
  reg [3:0]  w_strb_lat;
  reg        w_have_aw, w_have_w;
  reg        w_issued_aw, w_issued_w;
  reg        s_bvalid;
  reg [1:0]  s_bresp;

  // ---- write-side arbitration: fixed priority, s0 wins ties ----
  reg  w_grant; // 1 = s0 (CPU) owns the in-flight/most-recent write txn, 0 = s1 (JTAG)
  // Must also check w_state==W_IDLE, not just "!w_have_aw && !w_have_w" --
  // when AW and W both fire on the SAME cycle (the common case for a
  // single-outstanding master that asserts them together, like the JTAG
  // bridge), the W_IDLE->W_ISSUE transition below resets w_have_aw/
  // w_have_w back to 0 as part of that SAME move, which would make this
  // read spuriously true again for one cycle while already sitting in
  // W_ISSUE -- letting a second master steal the grant out from under an
  // in-flight transaction whose address was already latched under the
  // ORIGINAL grant, so the eventual B response gets routed back to the
  // wrong master, which then waits forever for a BVALID that was actually
  // delivered to someone else. Caught by the soc_top-level JTAG test
  // (CPU kept issuing writes right as the JTAG write's grant should have
  // been locked in), not by the crossbar's own unit test, which never
  // has a competing master requesting on that exact transitional cycle.
  wire w_open = (w_state == W_IDLE) && !w_have_aw && !w_have_w;
  wire w_arb_s0 = (s0_awvalid || s0_wvalid) || !(s1_awvalid || s1_wvalid);
  wire w_grant_eff = w_open ? w_arb_s0 : w_grant;

  wire        cur_awvalid = w_grant_eff ? s0_awvalid : s1_awvalid;
  wire [31:0] cur_awaddr  = w_grant_eff ? s0_awaddr  : s1_awaddr;
  wire        cur_wvalid  = w_grant_eff ? s0_wvalid  : s1_wvalid;
  wire [31:0] cur_wdata   = w_grant_eff ? s0_wdata   : s1_wdata;
  wire [3:0]  cur_wstrb   = w_grant_eff ? s0_wstrb   : s1_wstrb;
  wire        cur_bready  = w_grant     ? s0_bready  : s1_bready;

  wire cur_awready = (w_state == W_IDLE) && !w_have_aw;
  wire cur_wready  = (w_state == W_IDLE) && !w_have_w;

  assign s0_awready = w_grant_eff ? cur_awready : 1'b0;
  assign s1_awready = w_grant_eff ? 1'b0 : cur_awready;
  assign s0_wready  = w_grant_eff ? cur_wready : 1'b0;
  assign s1_wready  = w_grant_eff ? 1'b0 : cur_wready;

  assign s0_bvalid = w_grant  ? s_bvalid : 1'b0;
  assign s1_bvalid = !w_grant ? s_bvalid : 1'b0;
  assign s0_bresp  = s_bresp;
  assign s1_bresp  = s_bresp;

  wire aw_fire = cur_awvalid && cur_awready;
  wire w_fire  = cur_wvalid  && cur_wready;
  wire aw_ready_c = w_have_aw || aw_fire;
  wire w_ready_c  = w_have_w  || w_fire;

  // Combinational routing of the downstream AW/W channels to whichever
  // slave is currently selected (only meaningful while w_state==W_ISSUE).
  always @* begin
    rom_awvalid   = 1'b0; rom_awaddr   = w_addr_lat; rom_wvalid   = 1'b0; rom_wdata   = w_data_lat; rom_wstrb   = w_strb_lat; rom_bready   = 1'b0;
    ram_awvalid   = 1'b0; ram_awaddr   = w_addr_lat; ram_wvalid   = 1'b0; ram_wdata   = w_data_lat; ram_wstrb   = w_strb_lat; ram_bready   = 1'b0;
    timer_awvalid = 1'b0; timer_awaddr = w_addr_lat; timer_wvalid = 1'b0; timer_wdata = w_data_lat; timer_wstrb = w_strb_lat; timer_bready = 1'b0;
    wdt_awvalid   = 1'b0; wdt_awaddr   = w_addr_lat; wdt_wvalid   = 1'b0; wdt_wdata   = w_data_lat; wdt_wstrb   = w_strb_lat; wdt_bready   = 1'b0;
    uart_awvalid  = 1'b0; uart_awaddr  = w_addr_lat; uart_wvalid  = 1'b0; uart_wdata  = w_data_lat; uart_wstrb  = w_strb_lat; uart_bready  = 1'b0;
    i2c_awvalid   = 1'b0; i2c_awaddr   = w_addr_lat; i2c_wvalid   = 1'b0; i2c_wdata   = w_data_lat; i2c_wstrb   = w_strb_lat; i2c_bready   = 1'b0;
    spi_awvalid   = 1'b0; spi_awaddr   = w_addr_lat; spi_wvalid   = 1'b0; spi_wdata   = w_data_lat; spi_wstrb   = w_strb_lat; spi_bready   = 1'b0;
    aes_awvalid   = 1'b0; aes_awaddr   = w_addr_lat; aes_wvalid   = 1'b0; aes_wdata   = w_data_lat; aes_wstrb   = w_strb_lat; aes_bready   = 1'b0;
    dma_awvalid   = 1'b0; dma_awaddr   = w_addr_lat; dma_wvalid   = 1'b0; dma_wdata   = w_data_lat; dma_wstrb   = w_strb_lat; dma_bready   = 1'b0;

    if (w_state == W_ISSUE) begin
      case (w_sel)
        `SLAVE_ROM:   begin rom_awvalid   = !w_issued_aw; rom_wvalid   = !w_issued_w; end
        `SLAVE_RAM:   begin ram_awvalid   = !w_issued_aw; ram_wvalid   = !w_issued_w; end
        `SLAVE_TIMER: begin timer_awvalid = !w_issued_aw; timer_wvalid = !w_issued_w; end
        `SLAVE_WDT:   begin wdt_awvalid   = !w_issued_aw; wdt_wvalid   = !w_issued_w; end
        `SLAVE_UART:  begin uart_awvalid  = !w_issued_aw; uart_wvalid  = !w_issued_w; end
        `SLAVE_I2C:   begin i2c_awvalid   = !w_issued_aw; i2c_wvalid   = !w_issued_w; end
        `SLAVE_SPI:   begin spi_awvalid   = !w_issued_aw; spi_wvalid   = !w_issued_w; end
        `SLAVE_AES:   begin aes_awvalid   = !w_issued_aw; aes_wvalid   = !w_issued_w; end
        `SLAVE_DMA:   begin dma_awvalid   = !w_issued_aw; dma_wvalid   = !w_issued_w; end
        default:      ; // SLAVE_ERR (or not-yet-implemented): no real slave touched
      endcase
    end else if (w_state == W_WAIT_B) begin
      case (w_sel)
        `SLAVE_ROM:   rom_bready   = 1'b1;
        `SLAVE_RAM:   ram_bready   = 1'b1;
        `SLAVE_TIMER: timer_bready = 1'b1;
        `SLAVE_WDT:   wdt_bready   = 1'b1;
        `SLAVE_UART:  uart_bready  = 1'b1;
        `SLAVE_I2C:   i2c_bready   = 1'b1;
        `SLAVE_SPI:   spi_bready   = 1'b1;
        `SLAVE_AES:   aes_bready   = 1'b1;
        `SLAVE_DMA:   dma_bready   = 1'b1;
        default:      ;
      endcase
    end
  end

  wire w_slave_awready = (w_sel == `SLAVE_ROM) ? rom_awready : (w_sel == `SLAVE_RAM) ? ram_awready :
                         (w_sel == `SLAVE_TIMER) ? timer_awready : (w_sel == `SLAVE_WDT) ? wdt_awready :
                         (w_sel == `SLAVE_UART) ? uart_awready : (w_sel == `SLAVE_I2C) ? i2c_awready :
                         (w_sel == `SLAVE_SPI) ? spi_awready : (w_sel == `SLAVE_AES) ? aes_awready :
                         (w_sel == `SLAVE_DMA) ? dma_awready : 1'b1;
  wire w_slave_wready  = (w_sel == `SLAVE_ROM) ? rom_wready : (w_sel == `SLAVE_RAM) ? ram_wready :
                         (w_sel == `SLAVE_TIMER) ? timer_wready : (w_sel == `SLAVE_WDT) ? wdt_wready :
                         (w_sel == `SLAVE_UART) ? uart_wready : (w_sel == `SLAVE_I2C) ? i2c_wready :
                         (w_sel == `SLAVE_SPI) ? spi_wready : (w_sel == `SLAVE_AES) ? aes_wready :
                         (w_sel == `SLAVE_DMA) ? dma_wready : 1'b1;
  wire w_slave_bvalid  = (w_sel == `SLAVE_ROM) ? rom_bvalid : (w_sel == `SLAVE_RAM) ? ram_bvalid :
                         (w_sel == `SLAVE_TIMER) ? timer_bvalid : (w_sel == `SLAVE_WDT) ? wdt_bvalid :
                         (w_sel == `SLAVE_UART) ? uart_bvalid : (w_sel == `SLAVE_I2C) ? i2c_bvalid :
                         (w_sel == `SLAVE_SPI) ? spi_bvalid : (w_sel == `SLAVE_AES) ? aes_bvalid :
                         (w_sel == `SLAVE_DMA) ? dma_bvalid : 1'b1;
  wire [1:0] w_slave_bresp = (w_sel == `SLAVE_ROM) ? rom_bresp : (w_sel == `SLAVE_RAM) ? ram_bresp :
                         (w_sel == `SLAVE_TIMER) ? timer_bresp : (w_sel == `SLAVE_WDT) ? wdt_bresp :
                         (w_sel == `SLAVE_UART) ? uart_bresp : (w_sel == `SLAVE_I2C) ? i2c_bresp :
                         (w_sel == `SLAVE_SPI) ? spi_bresp : (w_sel == `SLAVE_AES) ? aes_bresp :
                         (w_sel == `SLAVE_DMA) ? dma_bresp : `AXI_RESP_SLVERR;

  always @(posedge clk) begin
    if (rst) begin
      w_state    <= W_IDLE;
      w_have_aw  <= 1'b0;
      w_have_w   <= 1'b0;
      s_bvalid   <= 1'b0;
      w_grant    <= 1'b1;
    end else begin
      if (w_open) w_grant <= w_arb_s0;

      case (w_state)
        W_IDLE: begin
          if (aw_fire) begin
            w_addr_lat <= cur_awaddr;
            w_sel      <= decode_addr(cur_awaddr);
          end
          if (w_fire) begin
            w_data_lat <= cur_wdata;
            w_strb_lat <= cur_wstrb;
          end
          w_have_aw <= aw_ready_c;
          w_have_w  <= w_ready_c;
          if (aw_ready_c && w_ready_c) begin
            w_state     <= W_ISSUE;
            w_have_aw   <= 1'b0;
            w_have_w    <= 1'b0;
            w_issued_aw <= 1'b0;
            w_issued_w  <= 1'b0;
          end
        end

        W_ISSUE: begin
          if (w_sel == `SLAVE_ERR) begin
            w_state <= W_RESP;
          end else begin
            if (!w_issued_aw && w_slave_awready) w_issued_aw <= 1'b1;
            if (!w_issued_w  && w_slave_wready)  w_issued_w  <= 1'b1;
            if ((w_issued_aw || w_slave_awready) && (w_issued_w || w_slave_wready))
              w_state <= W_WAIT_B;
          end
        end

        W_WAIT_B: begin
          if (w_slave_bvalid) begin
            s_bresp <= w_slave_bresp;
            w_state <= W_RESP;
          end
        end

        W_RESP: begin
          if (w_sel == `SLAVE_ERR && !s_bvalid) s_bresp <= `AXI_RESP_SLVERR;
          s_bvalid <= 1'b1;
          if (s_bvalid && cur_bready) begin
            s_bvalid <= 1'b0;
            w_state  <= W_IDLE;
          end
        end

        default: w_state <= W_IDLE;
      endcase
    end
  end

  // =====================================================================
  // READ PATH
  // =====================================================================
  localparam R_IDLE   = 2'd0;
  localparam R_ISSUE  = 2'd1;
  localparam R_WAIT_R = 2'd2;
  localparam R_RESP   = 2'd3;

  reg [1:0]       r_state;
  reg [SEL_W-1:0] r_sel;
  reg [31:0] r_addr_lat;
  reg        r_issued_ar;
  reg        s_rvalid;
  reg [31:0] s_rdata;
  reg [1:0]  s_rresp;

  // ---- read-side arbitration: independent of the write side, same
  // fixed-priority (s0/CPU wins ties) scheme ----
  reg  r_grant;
  wire r_open = (r_state == R_IDLE);
  wire r_arb_s0 = s0_arvalid || !s1_arvalid;
  wire r_grant_eff = r_open ? r_arb_s0 : r_grant;

  wire        cur_arvalid = r_grant_eff ? s0_arvalid : s1_arvalid;
  wire [31:0] cur_araddr  = r_grant_eff ? s0_araddr  : s1_araddr;
  wire        cur_rready  = r_grant     ? s0_rready  : s1_rready;

  assign s0_arready = r_grant_eff ? (r_state == R_IDLE) : 1'b0;
  assign s1_arready = r_grant_eff ? 1'b0 : (r_state == R_IDLE);

  assign s0_rvalid = r_grant  ? s_rvalid : 1'b0;
  assign s1_rvalid = !r_grant ? s_rvalid : 1'b0;
  assign s0_rdata  = s_rdata;
  assign s1_rdata  = s_rdata;
  assign s0_rresp  = s_rresp;
  assign s1_rresp  = s_rresp;

  always @* begin
    rom_arvalid   = 1'b0; rom_araddr   = r_addr_lat; rom_rready   = 1'b0;
    ram_arvalid   = 1'b0; ram_araddr   = r_addr_lat; ram_rready   = 1'b0;
    timer_arvalid = 1'b0; timer_araddr = r_addr_lat; timer_rready = 1'b0;
    wdt_arvalid   = 1'b0; wdt_araddr   = r_addr_lat; wdt_rready   = 1'b0;
    uart_arvalid  = 1'b0; uart_araddr  = r_addr_lat; uart_rready  = 1'b0;
    i2c_arvalid   = 1'b0; i2c_araddr   = r_addr_lat; i2c_rready   = 1'b0;
    spi_arvalid   = 1'b0; spi_araddr   = r_addr_lat; spi_rready   = 1'b0;
    aes_arvalid   = 1'b0; aes_araddr   = r_addr_lat; aes_rready   = 1'b0;
    dma_arvalid   = 1'b0; dma_araddr   = r_addr_lat; dma_rready   = 1'b0;

    if (r_state == R_ISSUE) begin
      case (r_sel)
        `SLAVE_ROM:   rom_arvalid   = !r_issued_ar;
        `SLAVE_RAM:   ram_arvalid   = !r_issued_ar;
        `SLAVE_TIMER: timer_arvalid = !r_issued_ar;
        `SLAVE_WDT:   wdt_arvalid   = !r_issued_ar;
        `SLAVE_UART:  uart_arvalid  = !r_issued_ar;
        `SLAVE_I2C:   i2c_arvalid   = !r_issued_ar;
        `SLAVE_SPI:   spi_arvalid   = !r_issued_ar;
        `SLAVE_AES:   aes_arvalid   = !r_issued_ar;
        `SLAVE_DMA:   dma_arvalid   = !r_issued_ar;
        default:      ; // SLAVE_ERR
      endcase
    end else if (r_state == R_WAIT_R) begin
      case (r_sel)
        `SLAVE_ROM:   rom_rready   = 1'b1;
        `SLAVE_RAM:   ram_rready   = 1'b1;
        `SLAVE_TIMER: timer_rready = 1'b1;
        `SLAVE_WDT:   wdt_rready   = 1'b1;
        `SLAVE_UART:  uart_rready  = 1'b1;
        `SLAVE_I2C:   i2c_rready   = 1'b1;
        `SLAVE_SPI:   spi_rready   = 1'b1;
        `SLAVE_AES:   aes_rready   = 1'b1;
        `SLAVE_DMA:   dma_rready   = 1'b1;
        default:      ;
      endcase
    end
  end

  wire w_slave_arready_r = (r_sel == `SLAVE_ROM) ? rom_arready : (r_sel == `SLAVE_RAM) ? ram_arready :
                         (r_sel == `SLAVE_TIMER) ? timer_arready : (r_sel == `SLAVE_WDT) ? wdt_arready :
                         (r_sel == `SLAVE_UART) ? uart_arready : (r_sel == `SLAVE_I2C) ? i2c_arready :
                         (r_sel == `SLAVE_SPI) ? spi_arready : (r_sel == `SLAVE_AES) ? aes_arready :
                         (r_sel == `SLAVE_DMA) ? dma_arready : 1'b1;
  wire r_slave_rvalid    = (r_sel == `SLAVE_ROM) ? rom_rvalid : (r_sel == `SLAVE_RAM) ? ram_rvalid :
                         (r_sel == `SLAVE_TIMER) ? timer_rvalid : (r_sel == `SLAVE_WDT) ? wdt_rvalid :
                         (r_sel == `SLAVE_UART) ? uart_rvalid : (r_sel == `SLAVE_I2C) ? i2c_rvalid :
                         (r_sel == `SLAVE_SPI) ? spi_rvalid : (r_sel == `SLAVE_AES) ? aes_rvalid :
                         (r_sel == `SLAVE_DMA) ? dma_rvalid : 1'b1;
  wire [31:0] r_slave_rdata = (r_sel == `SLAVE_ROM) ? rom_rdata : (r_sel == `SLAVE_RAM) ? ram_rdata :
                         (r_sel == `SLAVE_TIMER) ? timer_rdata : (r_sel == `SLAVE_WDT) ? wdt_rdata :
                         (r_sel == `SLAVE_UART) ? uart_rdata : (r_sel == `SLAVE_I2C) ? i2c_rdata :
                         (r_sel == `SLAVE_SPI) ? spi_rdata : (r_sel == `SLAVE_AES) ? aes_rdata :
                         (r_sel == `SLAVE_DMA) ? dma_rdata : 32'h0;
  wire [1:0]  r_slave_rresp = (r_sel == `SLAVE_ROM) ? rom_rresp : (r_sel == `SLAVE_RAM) ? ram_rresp :
                         (r_sel == `SLAVE_TIMER) ? timer_rresp : (r_sel == `SLAVE_WDT) ? wdt_rresp :
                         (r_sel == `SLAVE_UART) ? uart_rresp : (r_sel == `SLAVE_I2C) ? i2c_rresp :
                         (r_sel == `SLAVE_SPI) ? spi_rresp : (r_sel == `SLAVE_AES) ? aes_rresp :
                         (r_sel == `SLAVE_DMA) ? dma_rresp : `AXI_RESP_SLVERR;

  always @(posedge clk) begin
    if (rst) begin
      r_state  <= R_IDLE;
      s_rvalid <= 1'b0;
      r_grant  <= 1'b1;
    end else begin
      if (r_open) r_grant <= r_arb_s0;

      case (r_state)
        R_IDLE: begin
          if (cur_arvalid) begin
            r_addr_lat  <= cur_araddr;
            r_sel       <= decode_addr(cur_araddr);
            r_issued_ar <= 1'b0;
            r_state     <= R_ISSUE;
          end
        end

        R_ISSUE: begin
          if (r_sel == `SLAVE_ERR) begin
            r_state <= R_RESP;
          end else begin
            if (!r_issued_ar && w_slave_arready_r) r_issued_ar <= 1'b1;
            if (r_issued_ar || w_slave_arready_r)
              r_state <= R_WAIT_R;
          end
        end

        R_WAIT_R: begin
          if (r_slave_rvalid) begin
            s_rdata <= r_slave_rdata;
            s_rresp <= r_slave_rresp;
            r_state <= R_RESP;
          end
        end

        R_RESP: begin
          if (r_sel == `SLAVE_ERR && !s_rvalid) begin
            s_rdata <= 32'h0;
            s_rresp <= `AXI_RESP_SLVERR;
          end
          s_rvalid <= 1'b1;
          if (s_rvalid && cur_rready) begin
            s_rvalid <= 1'b0;
            r_state  <= R_IDLE;
          end
        end

        default: r_state <= R_IDLE;
      endcase
    end
  end

endmodule

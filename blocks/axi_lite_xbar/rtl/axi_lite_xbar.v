`include "axi_lite.vh"
`include "addr_map.vh"

// AXI4-Lite crossbar — Phase 2 scope: 1 master x 5 slaves (ROM, RAM, Timer,
// Watchdog, UART). I2C/SPI/AES land in later phases; any address that
// decodes into their region is treated as unmapped (SLVERR) until then.
// Hand-written (the project's core differentiator); Verilog-2001 only.
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

    // ---- upstream: the single AXI4-Lite master (CPU) ----
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_awaddr,

    input  wire        s_wvalid,
    output wire        s_wready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,

    output reg         s_bvalid,
    input  wire        s_bready,
    output reg  [1:0]  s_bresp,

    input  wire        s_arvalid,
    output wire        s_arready,
    input  wire [31:0] s_araddr,

    output reg         s_rvalid,
    input  wire        s_rready,
    output reg  [31:0] s_rdata,
    output reg  [1:0]  s_rresp,

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
    input  wire         uart_rvalid,  output reg uart_rready,  input wire [31:0] uart_rdata, input wire [1:0] uart_rresp
);

  // slave-select width sized for the full addr_map.vh SLAVE_* numbering
  // (up to SLAVE_ERR=8), even though only 5 of those are wired up so far —
  // any address decoding to a not-yet-implemented slave (I2C/SPI/AES) falls
  // through to SLAVE_ERR, same as a genuinely unmapped address.
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

  wire aw_fire = s_awvalid && s_awready;
  wire w_fire  = s_wvalid  && s_wready;
  wire aw_ready_c = w_have_aw || aw_fire;
  wire w_ready_c  = w_have_w  || w_fire;

  assign s_awready = (w_state == W_IDLE) && !w_have_aw;
  assign s_wready  = (w_state == W_IDLE) && !w_have_w;

  // Combinational routing of the downstream AW/W channels to whichever
  // slave is currently selected (only meaningful while w_state==W_ISSUE).
  always @* begin
    rom_awvalid   = 1'b0; rom_awaddr   = w_addr_lat; rom_wvalid   = 1'b0; rom_wdata   = w_data_lat; rom_wstrb   = w_strb_lat; rom_bready   = 1'b0;
    ram_awvalid   = 1'b0; ram_awaddr   = w_addr_lat; ram_wvalid   = 1'b0; ram_wdata   = w_data_lat; ram_wstrb   = w_strb_lat; ram_bready   = 1'b0;
    timer_awvalid = 1'b0; timer_awaddr = w_addr_lat; timer_wvalid = 1'b0; timer_wdata = w_data_lat; timer_wstrb = w_strb_lat; timer_bready = 1'b0;
    wdt_awvalid   = 1'b0; wdt_awaddr   = w_addr_lat; wdt_wvalid   = 1'b0; wdt_wdata   = w_data_lat; wdt_wstrb   = w_strb_lat; wdt_bready   = 1'b0;
    uart_awvalid  = 1'b0; uart_awaddr  = w_addr_lat; uart_wvalid  = 1'b0; uart_wdata  = w_data_lat; uart_wstrb  = w_strb_lat; uart_bready  = 1'b0;

    if (w_state == W_ISSUE) begin
      case (w_sel)
        `SLAVE_ROM:   begin rom_awvalid   = !w_issued_aw; rom_wvalid   = !w_issued_w; end
        `SLAVE_RAM:   begin ram_awvalid   = !w_issued_aw; ram_wvalid   = !w_issued_w; end
        `SLAVE_TIMER: begin timer_awvalid = !w_issued_aw; timer_wvalid = !w_issued_w; end
        `SLAVE_WDT:   begin wdt_awvalid   = !w_issued_aw; wdt_wvalid   = !w_issued_w; end
        `SLAVE_UART:  begin uart_awvalid  = !w_issued_aw; uart_wvalid  = !w_issued_w; end
        default:      ; // SLAVE_ERR (or not-yet-implemented): no real slave touched
      endcase
    end else if (w_state == W_WAIT_B) begin
      case (w_sel)
        `SLAVE_ROM:   rom_bready   = 1'b1;
        `SLAVE_RAM:   ram_bready   = 1'b1;
        `SLAVE_TIMER: timer_bready = 1'b1;
        `SLAVE_WDT:   wdt_bready   = 1'b1;
        `SLAVE_UART:  uart_bready  = 1'b1;
        default:      ;
      endcase
    end
  end

  wire w_slave_awready = (w_sel == `SLAVE_ROM) ? rom_awready : (w_sel == `SLAVE_RAM) ? ram_awready :
                         (w_sel == `SLAVE_TIMER) ? timer_awready : (w_sel == `SLAVE_WDT) ? wdt_awready :
                         (w_sel == `SLAVE_UART) ? uart_awready : 1'b1;
  wire w_slave_wready  = (w_sel == `SLAVE_ROM) ? rom_wready : (w_sel == `SLAVE_RAM) ? ram_wready :
                         (w_sel == `SLAVE_TIMER) ? timer_wready : (w_sel == `SLAVE_WDT) ? wdt_wready :
                         (w_sel == `SLAVE_UART) ? uart_wready : 1'b1;
  wire w_slave_bvalid  = (w_sel == `SLAVE_ROM) ? rom_bvalid : (w_sel == `SLAVE_RAM) ? ram_bvalid :
                         (w_sel == `SLAVE_TIMER) ? timer_bvalid : (w_sel == `SLAVE_WDT) ? wdt_bvalid :
                         (w_sel == `SLAVE_UART) ? uart_bvalid : 1'b1;
  wire [1:0] w_slave_bresp = (w_sel == `SLAVE_ROM) ? rom_bresp : (w_sel == `SLAVE_RAM) ? ram_bresp :
                         (w_sel == `SLAVE_TIMER) ? timer_bresp : (w_sel == `SLAVE_WDT) ? wdt_bresp :
                         (w_sel == `SLAVE_UART) ? uart_bresp : `AXI_RESP_SLVERR;

  always @(posedge clk) begin
    if (rst) begin
      w_state    <= W_IDLE;
      w_have_aw  <= 1'b0;
      w_have_w   <= 1'b0;
      s_bvalid   <= 1'b0;
    end else begin
      case (w_state)
        W_IDLE: begin
          if (aw_fire) begin
            w_addr_lat <= s_awaddr;
            w_sel      <= decode_addr(s_awaddr);
          end
          if (w_fire) begin
            w_data_lat <= s_wdata;
            w_strb_lat <= s_wstrb;
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
          if (s_bvalid && s_bready) begin
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

  assign s_arready = (r_state == R_IDLE);

  always @* begin
    rom_arvalid   = 1'b0; rom_araddr   = r_addr_lat; rom_rready   = 1'b0;
    ram_arvalid   = 1'b0; ram_araddr   = r_addr_lat; ram_rready   = 1'b0;
    timer_arvalid = 1'b0; timer_araddr = r_addr_lat; timer_rready = 1'b0;
    wdt_arvalid   = 1'b0; wdt_araddr   = r_addr_lat; wdt_rready   = 1'b0;
    uart_arvalid  = 1'b0; uart_araddr  = r_addr_lat; uart_rready  = 1'b0;

    if (r_state == R_ISSUE) begin
      case (r_sel)
        `SLAVE_ROM:   rom_arvalid   = !r_issued_ar;
        `SLAVE_RAM:   ram_arvalid   = !r_issued_ar;
        `SLAVE_TIMER: timer_arvalid = !r_issued_ar;
        `SLAVE_WDT:   wdt_arvalid   = !r_issued_ar;
        `SLAVE_UART:  uart_arvalid  = !r_issued_ar;
        default:      ; // SLAVE_ERR
      endcase
    end else if (r_state == R_WAIT_R) begin
      case (r_sel)
        `SLAVE_ROM:   rom_rready   = 1'b1;
        `SLAVE_RAM:   ram_rready   = 1'b1;
        `SLAVE_TIMER: timer_rready = 1'b1;
        `SLAVE_WDT:   wdt_rready   = 1'b1;
        `SLAVE_UART:  uart_rready  = 1'b1;
        default:      ;
      endcase
    end
  end

  wire w_slave_arready_r = (r_sel == `SLAVE_ROM) ? rom_arready : (r_sel == `SLAVE_RAM) ? ram_arready :
                         (r_sel == `SLAVE_TIMER) ? timer_arready : (r_sel == `SLAVE_WDT) ? wdt_arready :
                         (r_sel == `SLAVE_UART) ? uart_arready : 1'b1;
  wire r_slave_rvalid    = (r_sel == `SLAVE_ROM) ? rom_rvalid : (r_sel == `SLAVE_RAM) ? ram_rvalid :
                         (r_sel == `SLAVE_TIMER) ? timer_rvalid : (r_sel == `SLAVE_WDT) ? wdt_rvalid :
                         (r_sel == `SLAVE_UART) ? uart_rvalid : 1'b1;
  wire [31:0] r_slave_rdata = (r_sel == `SLAVE_ROM) ? rom_rdata : (r_sel == `SLAVE_RAM) ? ram_rdata :
                         (r_sel == `SLAVE_TIMER) ? timer_rdata : (r_sel == `SLAVE_WDT) ? wdt_rdata :
                         (r_sel == `SLAVE_UART) ? uart_rdata : 32'h0;
  wire [1:0]  r_slave_rresp = (r_sel == `SLAVE_ROM) ? rom_rresp : (r_sel == `SLAVE_RAM) ? ram_rresp :
                         (r_sel == `SLAVE_TIMER) ? timer_rresp : (r_sel == `SLAVE_WDT) ? wdt_rresp :
                         (r_sel == `SLAVE_UART) ? uart_rresp : `AXI_RESP_SLVERR;

  always @(posedge clk) begin
    if (rst) begin
      r_state  <= R_IDLE;
      s_rvalid <= 1'b0;
    end else begin
      case (r_state)
        R_IDLE: begin
          if (s_arvalid) begin
            r_addr_lat  <= s_araddr;
            r_sel       <= decode_addr(s_araddr);
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
          if (s_rvalid && s_rready) begin
            s_rvalid <= 1'b0;
            r_state  <= R_IDLE;
          end
        end

        default: r_state <= R_IDLE;
      endcase
    end
  end

endmodule

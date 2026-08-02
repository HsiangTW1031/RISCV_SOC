`include "axi_lite.vh"

// SPI master — shift-register based, all 4 CPOL/CPHA modes, configurable
// clock divider. Single in-flight byte per transfer (no queue — firmware
// polls STATUS.busy or waits for the irq pulse before starting another).
//
// Register map (byte offsets):
//   0x0 CTRL   (r/w) — bit[0] START (write 1 to begin a transfer; ignored
//                      if already busy — no queue, see above). bit[1]
//                      CPOL, bit[2] CPHA — latched at the moment of START,
//                      so change them before writing START=1.
//   0x4 DIVIDER (r/w) — half SCLK period, in core clock cycles (>=1).
//   0x8 TXDATA (r/w)  — byte to shift out, latched at START.
//   0xC RXDATA (ro)   — byte shifted in, valid once DONE is set.
//   0x10 STATUS (r/w) — bit[0] BUSY (read-only bit); bit[1] DONE (sticky,
//                       write-1-to-clear).
//
// `irq` is a single-cycle pulse on transfer completion — a level-held
// signal here would hit the exact same PicoRV32 LATCHED_IRQ re-latching
// hazard documented in timer.v's header comment, so DONE stays a separate
// sticky status bit and irq only pulses.
//
// Edge convention (CPOL=0 idle low, CPOL=1 idle high): the "leading" edge
// of each bit period is the transition away from idle, the "trailing"
// edge is the transition back toward idle. CPHA=0 captures on the leading
// edge and shifts/changes on the trailing edge (so the first bit must
// already be valid on MOSI before SCLK ever moves — handled below by
// presetting mosi at START); CPHA=1 changes on the leading edge and
// captures on the trailing edge, EXCEPT the very first leading edge
// (edge_cnt==0) doesn't shift — see is_shift_edge below for why.
//
// `mosi` is a genuinely registered output (updated via nonblocking
// assignment at START and at each shift edge), not derived by a plain
// `assign mosi = tx_shift[7]`. Either works correctly here since fake_spi_
// slave.v samples on the same core clk rather than being purely reactive
// to sclk's edge, but a registered mosi is the more broadly correct
// choice for any downstream sampler.
module spi_master (
    input  wire        clk,
    input  wire        rst,

    input  wire        s_awvalid, output wire s_awready, input wire [31:0] s_awaddr,
    input  wire        s_wvalid,  output wire s_wready,  input wire [31:0] s_wdata, input wire [3:0] s_wstrb,
    output reg          s_bvalid,  input wire  s_bready,  output reg [1:0] s_bresp,
    input  wire        s_arvalid, output wire s_arready, input wire [31:0] s_araddr,
    output reg          s_rvalid,  input wire  s_rready,  output reg [31:0] s_rdata, output reg [1:0] s_rresp,

    output reg          sclk,
    output reg          mosi,
    input  wire         miso,
    output reg          cs_n,
    output wire         irq
);
  // NB: REG_STATUS is 0x10 — needs 5 bits, not 4, hence the wider offset
  // field below (unlike timer/watchdog, which only ever needed 4 bits).
  localparam REG_CTRL    = 5'h00;
  localparam REG_DIVIDER = 5'h04;
  localparam REG_TXDATA  = 5'h08;
  localparam REG_RXDATA  = 5'h0C;
  localparam REG_STATUS  = 5'h10;

  localparam IDLE = 1'b0;
  localparam RUN  = 1'b1;

  reg        state;
  reg        cpol_r, cpha_r;
  reg [31:0] divider_reg;
  reg [31:0] div_cnt;
  reg [4:0]  edge_cnt;    // 0..16 (16 edges = 8 bits x 2)
  reg [6:0]  tx_shift; // holds only the 7 remaining bits after the first
                       // (bit 7 goes straight from txdata_reg to mosi at
                       // START, so tx_shift never needs to carry it)
  reg [7:0]  rx_shift;
  reg [7:0]  rxdata_reg;
  reg        busy, done;
  reg        irq_pulse;

  assign irq  = irq_pulse;

  wire is_leading_edge = ~edge_cnt[0];                        // even index
  // Standard SPI CPHA semantics: CPHA=0 captures on the leading edge and
  // changes/shifts on the trailing edge; CPHA=1 changes/shifts on the
  // leading edge and captures on the trailing edge. The one wrinkle for
  // CPHA=1: edge_cnt==0 (the very first leading edge) must NOT shift —
  // tx_shift already holds the untouched original byte at that point
  // (loaded at START, before any edges), so bit 7 is already correctly
  // sitting in mosi; shifting there too would skip straight to bit 6 and
  // lose bit 7 entirely. From the second leading edge (edge_cnt==2) on,
  // shifting is exactly what reveals each next bit in time for its
  // trailing-edge capture.
  wire is_sample_edge = cpha_r ? ~is_leading_edge : is_leading_edge;
  wire is_shift_edge  = cpha_r ? (is_leading_edge && edge_cnt != 5'd0) : ~is_leading_edge;

  assign s_awready = 1'b1;
  assign s_wready  = 1'b1;
  assign s_arready = 1'b1;

  wire [4:0] aw_offset = s_awaddr[4:0];
  wire [4:0] ar_offset = s_araddr[4:0];
  wire       do_write  = s_awvalid && s_wvalid;
  wire       do_start  = do_write && (aw_offset == REG_CTRL) && s_wdata[0] && !busy;

  always @(posedge clk) begin
    if (rst) begin
      state       <= IDLE;
      sclk        <= 1'b0;
      cs_n        <= 1'b1;
      busy        <= 1'b0;
      done        <= 1'b0;
      irq_pulse   <= 1'b0;
      divider_reg <= 32'd2;
    end else begin
      irq_pulse <= 1'b0; // default: single-cycle pulse unless re-asserted below

      if (do_write && aw_offset == REG_DIVIDER)
        divider_reg <= (s_wdata == 32'd0) ? 32'd1 : s_wdata; // guard against a 0 divider hanging the FSM

      if (do_write && aw_offset == REG_STATUS && s_wdata[1])
        done <= 1'b0; // write-1-to-clear DONE

      case (state)
        IDLE: begin
          cs_n <= 1'b1;
          if (do_start) begin
            cpol_r      <= s_wdata[1];
            cpha_r      <= s_wdata[2];
            tx_shift    <= txdata_reg[6:0];
            mosi        <= txdata_reg[7];
            cs_n        <= 1'b0;
            sclk        <= s_wdata[1]; // idle level = CPOL
            edge_cnt    <= 5'd0;
            div_cnt     <= 32'd0;
            busy        <= 1'b1;
            done        <= 1'b0;
            state       <= RUN;
          end
        end

        RUN: begin
          if (div_cnt == divider_reg - 1) begin
            div_cnt <= 32'd0;
            if (edge_cnt == 5'd16) begin
              cs_n       <= 1'b1;
              busy       <= 1'b0;
              done       <= 1'b1;
              irq_pulse  <= 1'b1;
              rxdata_reg <= rx_shift;
              state      <= IDLE;
            end else begin
              sclk <= ~sclk;
              if (is_sample_edge)
                rx_shift <= {rx_shift[6:0], miso};
              if (is_shift_edge) begin
                tx_shift <= {tx_shift[6:0], 1'b0};
                mosi     <= tx_shift[6];
              end
              edge_cnt <= edge_cnt + 5'd1;
            end
          end else begin
            div_cnt <= div_cnt + 32'd1;
          end
        end
      endcase

      // ---- AXI write response ----
      if (do_write) begin
        s_bresp  <= `AXI_RESP_OKAY;
        s_bvalid <= 1'b1;
      end else begin
        s_bvalid <= 1'b0;
      end

      // ---- AXI read ----
      if (s_arvalid) begin
        case (ar_offset)
          REG_CTRL:    s_rdata <= {29'b0, cpha_r, cpol_r, 1'b0};
          REG_DIVIDER: s_rdata <= divider_reg;
          REG_TXDATA:  s_rdata <= {24'b0, txdata_reg};
          REG_RXDATA:  s_rdata <= {24'b0, rxdata_reg};
          REG_STATUS:  s_rdata <= {30'b0, done, busy};
          default:     s_rdata <= 32'b0;
        endcase
        s_rresp  <= `AXI_RESP_OKAY;
        s_rvalid <= 1'b1;
      end else begin
        s_rvalid <= 1'b0;
      end
    end
  end

  // TXDATA is a plain read/write register, latched into tx_shift at START.
  reg [7:0] txdata_reg;
  always @(posedge clk) begin
    if (rst) txdata_reg <= 8'h0;
    else if (do_write && aw_offset == REG_TXDATA) txdata_reg <= s_wdata[7:0];
  end
endmodule

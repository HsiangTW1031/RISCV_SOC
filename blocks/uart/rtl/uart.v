`include "axi_lite.vh"

// UART — Phase 1 scope: TX only (RX + FIFO + configurable baud land in
// Phase 3). 8 data bits, no parity, 1 stop bit, LSB first, idle-high line.
//
// Register map (byte offsets within the UART's AXI window):
//   0x0 TXDATA  (write-only) — bits [7:0] = byte to transmit. Ignored if a
//               transmission is already in progress (no FIFO yet — firmware
//               must poll STATUS.busy before writing, documented behavior).
//   0x4 STATUS  (read-only)  — bit[0] = tx_busy.
//
// CLKS_PER_BIT sets the bit period in clock cycles (clk_freq / baud_rate);
// default of 4 is simulation-friendly, not a real baud rate — override it
// for anything driving real timing.
module uart #(
    parameter CLKS_PER_BIT = 4
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire        s_awvalid, output wire s_awready, input wire [31:0] s_awaddr,
    input  wire        s_wvalid,  output wire s_wready,  input wire [31:0] s_wdata, input wire [3:0] s_wstrb,
    output reg          s_bvalid,  input wire  s_bready,  output reg [1:0] s_bresp,
    input  wire        s_arvalid, output wire s_arready, input wire [31:0] s_araddr,
    output reg          s_rvalid,  input wire  s_rready,  output reg [31:0] s_rdata, output reg [1:0] s_rresp,

    output reg          tx
);
  localparam REG_TXDATA = 4'h0;
  localparam REG_STATUS = 4'h4;

  localparam TX_IDLE  = 2'd0;
  localparam TX_START = 2'd1;
  localparam TX_DATA  = 2'd2;
  localparam TX_STOP  = 2'd3;

  reg [1:0] tx_state;
  reg [2:0] bit_idx;
  reg [7:0] tx_shift;
  reg [7:0] clk_cnt;
  wire      tx_busy = (tx_state != TX_IDLE);

  reg       do_start_tx;
  reg [7:0] start_byte;

  always @(posedge clk) begin
    if (!resetn) begin
      tx_state <= TX_IDLE;
      tx       <= 1'b1;
      clk_cnt  <= 8'd0;
      bit_idx  <= 3'd0;
    end else begin
      case (tx_state)
        TX_IDLE: begin
          tx <= 1'b1;
          if (do_start_tx) begin
            tx_shift <= start_byte;
            tx_state <= TX_START;
            clk_cnt  <= 8'd0;
          end
        end

        TX_START: begin
          tx <= 1'b0;
          if (clk_cnt == CLKS_PER_BIT - 1) begin
            clk_cnt  <= 8'd0;
            bit_idx  <= 3'd0;
            tx_state <= TX_DATA;
          end else begin
            clk_cnt <= clk_cnt + 8'd1;
          end
        end

        TX_DATA: begin
          tx <= tx_shift[bit_idx];
          if (clk_cnt == CLKS_PER_BIT - 1) begin
            clk_cnt <= 8'd0;
            if (bit_idx == 3'd7)
              tx_state <= TX_STOP;
            else
              bit_idx <= bit_idx + 3'd1;
          end else begin
            clk_cnt <= clk_cnt + 8'd1;
          end
        end

        TX_STOP: begin
          tx <= 1'b1;
          if (clk_cnt == CLKS_PER_BIT - 1) begin
            clk_cnt  <= 8'd0;
            tx_state <= TX_IDLE;
          end else begin
            clk_cnt <= clk_cnt + 8'd1;
          end
        end

        default: tx_state <= TX_IDLE;
      endcase
    end
  end

  // ---- AXI4-Lite register interface ----
  assign s_awready = 1'b1;
  assign s_wready  = 1'b1;
  assign s_arready = 1'b1;

  wire [3:0] aw_offset = s_awaddr[3:0];
  wire [3:0] ar_offset = s_araddr[3:0];

  always @(posedge clk) begin
    if (!resetn) begin
      s_bvalid    <= 1'b0;
      s_rvalid    <= 1'b0;
      do_start_tx <= 1'b0;
    end else begin
      do_start_tx <= 1'b0; // single-cycle pulse unless re-asserted below

      if (s_awvalid && s_wvalid) begin
        if (aw_offset == REG_TXDATA && !tx_busy) begin
          start_byte  <= s_wdata[7:0];
          do_start_tx <= 1'b1;
        end
        s_bresp  <= `AXI_RESP_OKAY;
        s_bvalid <= 1'b1;
      end else begin
        s_bvalid <= 1'b0;
      end

      if (s_arvalid) begin
        if (ar_offset == REG_STATUS)
          s_rdata <= {31'b0, tx_busy};
        else
          s_rdata <= 32'b0;
        s_rresp  <= `AXI_RESP_OKAY;
        s_rvalid <= 1'b1;
      end else begin
        s_rvalid <= 1'b0;
      end
    end
  end
endmodule

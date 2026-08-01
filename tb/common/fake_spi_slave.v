// Behavioral SPI slave for validating spi_master.v — not synthesizable,
// lives in tb/common alongside the other test-only fake slaves.
//
// CPOL/CPHA are runtime inputs (driven directly by the testbench before
// each transfer), so a single build can exercise all 4 modes. Loads
// `preload` on CS falling edge and shifts it out MSB-first while
// simultaneously shifting in whatever the master sends on MOSI, using the
// identical edge convention as spi_master.v's header comment: CPHA=0
// captures on the leading edge and shifts on the trailing edge; CPHA=1
// changes/shifts on the leading edge and captures on the trailing edge,
// except the very first leading edge (edge_cnt==0), which must not shift
// — tx_shift still holds the untouched preload byte at that point, so bit
// 7 is already correctly sitting on miso without needing a shift.
module fake_spi_slave (
    input  wire        clk,
    input  wire        sclk,
    input  wire        mosi,
    output reg         miso,
    input  wire        cs_n,
    input  wire        cpol,
    input  wire        cpha,
    input  wire [7:0]  preload,
    output reg  [7:0]  received,
    output reg         xfer_done
);
  reg [7:0] tx_shift;
  reg [4:0] edge_cnt;
  reg       sclk_prev;
  reg       cs_n_prev;

  always @(posedge clk) begin
    if (cs_n_prev && !cs_n) begin
      // CS just asserted: preload for this transfer. MSB must already be
      // valid on miso before SCLK moves, in both CPHA modes (mirrors
      // spi_master.v's mosi preset at START).
      tx_shift  <= preload;
      edge_cnt  <= 5'd0;
      xfer_done <= 1'b0;
      miso      <= preload[7];
      sclk_prev <= cpol;
    end else if (!cs_n && sclk != sclk_prev) begin
      if (sclk != cpol) begin
        // leading edge (just moved away from idle)
        if (!cpha) received <= {received[6:0], mosi};
        if (cpha && edge_cnt != 5'd0) begin
          tx_shift <= {tx_shift[6:0], 1'b0};
          miso     <= tx_shift[6];
        end
      end else begin
        // trailing edge (just moved back to idle)
        if (cpha) received <= {received[6:0], mosi};
        if (!cpha) begin
          tx_shift <= {tx_shift[6:0], 1'b0};
          miso     <= tx_shift[6];
        end
      end
      edge_cnt <= edge_cnt + 5'd1;
      if (edge_cnt == 5'd15) xfer_done <= 1'b1;
      sclk_prev <= sclk;
    end
    cs_n_prev <= cs_n;
  end
endmodule

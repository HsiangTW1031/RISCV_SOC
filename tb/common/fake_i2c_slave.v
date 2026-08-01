// Behavioral I2C slave for validating i2c_master.v — not synthesizable,
// lives in tb/common alongside the other test-only fake devices.
//
// Watches scl/sda transitions every core clk cycle (edge detection via
// prev-value regs, same style as fake_spi_slave.v) rather than trying to
// track the master's internal divider — this works because the master
// only ever changes scl/sda at its own tick boundaries, so every real
// transition is visible for at least one full clk cycle.
//
// ACKs only the configured `my_addr` (7-bit); any other address is left to
// float (NACK, since there's a pullup on sda in the testbench). Supports
// exactly one data byte per transaction (matches i2c_master.v's own
// single-byte convention): a write stores the byte into `rx_byte`, a read
// shifts `tx_byte` out MSB-first, then the master's own NACK+STOP ends the
// transfer. No clock stretching (slave never holds scl low), matching the
// scope cut in i2c_master.v.
//
// IMPORTANT timing rule (the one real bug found debugging this model):
// sda may only ever CHANGE while scl is LOW. Releasing (or changing) an
// ack/data drive at the scl_rising edge itself is wrong -- scl is already
// high by the time that edge is observed, so the change looks exactly
// like a STOP condition (sda rises while scl stays high) and aborts the
// transfer instantly. Every drive change below happens on scl_falling,
// never on scl_rising; scl_rising is used only to sample/decide.
module fake_i2c_slave (
    input  wire        clk,
    input  wire        scl,
    inout  wire         sda,
    input  wire [6:0]  my_addr,
    input  wire [7:0]  tx_byte,     // byte offered back to the master on a read
    output reg  [7:0]  rx_byte,     // byte captured from the master on a write
    output reg         got_write,
    output reg         got_read,
    output reg         xfer_done
);
  localparam IDLE       = 3'd0;
  localparam ADDR       = 3'd1;
  localparam ADDR_ACK   = 3'd2;
  localparam WDATA      = 3'd3;
  localparam WDATA_ACK  = 3'd4;
  localparam RDATA      = 3'd5;
  localparam RDATA_ACK  = 3'd6;
  localparam WAIT_STOP  = 3'd7; // ack already driven; hold until scl falls again, then release

  reg [2:0] state;
  reg [2:0] bit_idx;
  reg [7:0] shift_reg;
  reg       matched, rw;
  reg       sda_drive_low;
  reg       scl_prev, sda_prev;

  assign sda = sda_drive_low ? 1'b0 : 1'bz;

  wire sda_val      = (sda === 1'b0) ? 1'b0 : 1'b1; // treat 'z' (released, pulled up) as 1
  wire scl_rising   = !scl_prev && scl;
  wire scl_falling  = scl_prev && !scl;
  wire start_cond   = scl_prev && scl && sda_prev && !sda_val;
  wire stop_cond    = scl_prev && scl && !sda_prev && sda_val;

  always @(posedge clk) begin
    if (start_cond) begin
      state         <= ADDR;
      bit_idx       <= 3'd7;
      shift_reg     <= 8'h0;
      sda_drive_low <= 1'b0;
      got_write     <= 1'b0;
      got_read      <= 1'b0;
      xfer_done     <= 1'b0;
    end else if (stop_cond) begin
      state         <= IDLE;
      sda_drive_low <= 1'b0;
      xfer_done     <= 1'b1;
    end else begin
      case (state)
        IDLE: sda_drive_low <= 1'b0;

        ADDR: begin
          if (scl_rising) begin
            shift_reg <= {shift_reg[6:0], sda_val};
            if (bit_idx == 3'd0) begin
              matched <= ({shift_reg[6:0], sda_val}[7:1] == my_addr);
              rw      <= sda_val;
              state   <= ADDR_ACK;
            end else begin
              bit_idx <= bit_idx - 3'd1;
            end
          end
        end

        // Drive the ack bit on its low phase (scl_falling) and HOLD it
        // through the whole high/sampled phase -- do not touch sda at
        // scl_rising. The next state's own first scl_falling is what
        // changes the drive (WDATA releases; RDATA re-drives its own
        // MSB; not-matched never drove anything to begin with).
        ADDR_ACK: begin
          if (scl_falling) sda_drive_low <= matched;
          if (scl_rising) begin
            bit_idx   <= 3'd7;
            shift_reg <= tx_byte; // preloaded now so RDATA's first falling edge already has it
            if (matched) state <= rw ? RDATA : WDATA;
            else         state <= IDLE; // not addressed: ignore rest of the transfer
          end
        end

        WDATA: begin
          if (scl_falling) sda_drive_low <= 1'b0; // release the address ack; slave only receives here
          if (scl_rising) begin
            shift_reg <= {shift_reg[6:0], sda_val};
            if (bit_idx == 3'd0) state <= WDATA_ACK;
            else bit_idx <= bit_idx - 3'd1;
          end
        end

        WDATA_ACK: begin
          if (scl_falling) begin
            sda_drive_low <= 1'b1; // always ACK the data byte (single-byte convention)
            rx_byte       <= shift_reg;
            got_write     <= 1'b1;
            state         <= WAIT_STOP;
          end
        end

        // Ack already asserted; release only once scl falls again (the
        // master's own STOP-prep edge), never at scl_rising.
        WAIT_STOP: begin
          if (scl_falling) sda_drive_low <= 1'b0;
        end

        RDATA: begin
          if (scl_falling) sda_drive_low <= ~shift_reg[7]; // always the current MSB
          if (scl_rising) begin
            if (bit_idx == 3'd0) begin
              got_read <= 1'b1;
              state    <= RDATA_ACK;
            end else begin
              shift_reg <= {shift_reg[6:0], 1'b0};
              bit_idx   <= bit_idx - 3'd1;
            end
          end
        end

        // Master drives the final ack/nack; slave just releases sda and
        // waits (a single-byte read always ends in the master's NACK+STOP).
        RDATA_ACK: begin
          if (scl_falling) sda_drive_low <= 1'b0;
        end

        default: state <= IDLE;
      endcase
    end

    scl_prev <= scl;
    sda_prev <= sda_val;
  end
endmodule

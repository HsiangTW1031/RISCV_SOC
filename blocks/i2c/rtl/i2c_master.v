`include "axi_lite.vh"

// I2C master — single-byte transactions (write one byte or read one byte),
// 7-bit addressing, open-drain SDA/SCL. No clock stretching support (a
// deliberate scope cut — the slave is assumed to never hold SCL low; see
// docs/phase_plan.md) and no multi-byte burst (single in-flight byte per
// transfer, same "no queue" convention as uart.v/spi_master.v).
//
// Register map (byte offsets):
//   0x0 CTRL   (r/w) — bit[0] START (write 1 to begin; ignored if busy).
//                      bit[1] RW (0=write, 1=read), latched at START.
//   0x4 ADDR   (r/w) — bits[6:0] 7-bit slave address, latched at START.
//   0x8 TXDATA (r/w) — byte to write, latched at START (write transfers
//                      only).
//   0xC RXDATA (ro)  — byte read back, valid once DONE is set (read
//                      transfers only).
//   0x10 STATUS (r/w) — bit[0] BUSY (read-only); bit[1] DONE (sticky,
//                       write-1-to-clear); bit[2] NACK (sticky, write-1-
//                       to-clear — set if the slave didn't ACK the address
//                       or, for a write, the data byte).
//   0x14 DIVIDER (r/w) — half SCL period, in core clock cycles (>=1),
//                        same convention as spi_master.v's DIVIDER.
//
// `irq` is a single-cycle pulse on transfer completion — see timer.v's
// header comment for why a level-held signal would risk a spurious second
// PicoRV32 ISR entry.
//
// SDA/SCL are modeled open-drain: this module only ever drives them low
// or releases them (1'bz); an external pull-up (or the fake slave's own
// pull-up modeling in the testbench) is what makes a released line read
// back high.
module i2c_master (
    input  wire        clk,
    input  wire        resetn,

    input  wire        s_awvalid, output wire s_awready, input wire [31:0] s_awaddr,
    input  wire        s_wvalid,  output wire s_wready,  input wire [31:0] s_wdata, input wire [3:0] s_wstrb,
    output reg          s_bvalid,  input wire  s_bready,  output reg [1:0] s_bresp,
    input  wire        s_arvalid, output wire s_arready, input wire [31:0] s_araddr,
    output reg          s_rvalid,  input wire  s_rready,  output reg [31:0] s_rdata, output reg [1:0] s_rresp,

    output reg          scl,
    inout  wire         sda,
    output wire         irq
);
  localparam REG_CTRL    = 5'h00;
  localparam REG_ADDR    = 5'h04;
  localparam REG_TXDATA  = 5'h08;
  localparam REG_RXDATA  = 5'h0C;
  localparam REG_STATUS  = 5'h10;
  localparam REG_DIVIDER = 5'h14;

  localparam ST_IDLE      = 4'd0;
  localparam ST_START     = 4'd1;  // SDA falls while SCL still high
  localparam ST_ADDR      = 4'd2;  // shift out 7-bit addr + RW (8 bits)
  localparam ST_ADDR_ACK  = 4'd3;
  localparam ST_WDATA     = 4'd4;  // shift out the data byte (write only)
  localparam ST_WDATA_ACK = 4'd5;
  localparam ST_RDATA     = 4'd6;  // shift in the data byte (read only)
  localparam ST_RDATA_ACK = 4'd7;  // master drives NACK (single-byte read)
  localparam ST_STOP      = 4'd8;  // SDA rises while SCL high

  reg [3:0]  state;
  reg [31:0] divider_reg;
  reg [31:0] div_cnt;
  reg        phase;          // 0 = SCL low (change SDA), 1 = SCL high (stable/sample)
  reg [2:0]  bit_idx;        // 7 downto 0, MSB first
  reg [7:0]  addr_rw;        // {addr[6:0], rw}
  reg [7:0]  tx_shift;
  reg [7:0]  rx_shift;
  reg [7:0]  rxdata_reg;
  reg        rw_r;
  reg        sda_drive_low;  // 1 = actively pull SDA low, 0 = release
  reg        busy, done, nack;
  reg        irq_pulse;

  assign sda = sda_drive_low ? 1'b0 : 1'bz;
  assign irq = irq_pulse;

  assign s_awready = 1'b1;
  assign s_wready  = 1'b1;
  assign s_arready = 1'b1;

  wire [4:0] aw_offset = s_awaddr[4:0];
  wire [4:0] ar_offset = s_araddr[4:0];
  wire       do_write  = s_awvalid && s_wvalid;
  wire       do_start  = do_write && (aw_offset == REG_CTRL) && s_wdata[0] && !busy;

  // Advances once every `divider_reg` cycles; returns 1'b1 on the tick
  // where a phase boundary is crossed.
  wire tick = (div_cnt == divider_reg - 1);

  always @(posedge clk) begin
    if (!resetn) begin
      state         <= ST_IDLE;
      scl            <= 1'b1;
      sda_drive_low  <= 1'b0;
      busy           <= 1'b0;
      done           <= 1'b0;
      nack           <= 1'b0;
      irq_pulse      <= 1'b0;
      divider_reg    <= 32'd4;
    end else begin
      irq_pulse <= 1'b0;

      if (do_write && aw_offset == REG_DIVIDER)
        divider_reg <= (s_wdata == 32'd0) ? 32'd1 : s_wdata; // guard against a 0 divider hanging the FSM

      if (do_write && aw_offset == REG_STATUS) begin
        if (s_wdata[1]) done <= 1'b0;
        if (s_wdata[2]) nack <= 1'b0;
      end

      case (state)
        ST_IDLE: begin
          scl           <= 1'b1;
          sda_drive_low <= 1'b0;
          if (do_start) begin
            rw_r        <= s_wdata[1];
            addr_rw     <= {addr_reg[6:0], s_wdata[1]};
            tx_shift    <= txdata_reg;
            busy        <= 1'b1;
            done        <= 1'b0;
            nack        <= 1'b0;
            div_cnt     <= 32'd0;
            phase       <= 1'b0;
            state       <= ST_START;
          end
        end

        // Two sub-steps so SDA's fall and SCL's fall land in different
        // cycles: phase0 pulls SDA low while SCL is STILL high (this is
        // the actual, observable start condition); only on the next tick
        // does SCL drop to prepare for bit 7 of the address. Doing both in
        // the same cycle (as an earlier version of this FSM did) makes SDA
        // and SCL fall simultaneously, which no observer can distinguish
        // from bus noise -- the fake slave's start_cond detection (SDA
        // falls while SCL_prev/SCL both read 1) would never fire.
        ST_START: begin
          if (tick) begin
            div_cnt <= 32'd0;
            if (phase == 1'b0) begin
              sda_drive_low <= 1'b1; // SDA falls, SCL still high -> start condition
              phase         <= 1'b1;
            end else begin
              scl     <= 1'b0;
              bit_idx <= 3'd7;
              phase   <= 1'b0;
              state   <= ST_ADDR;
            end
          end else div_cnt <= div_cnt + 32'd1;
        end

        ST_ADDR: begin
          if (tick) begin
            div_cnt <= 32'd0;
            if (phase == 1'b0) begin
              sda_drive_low <= ~addr_rw[bit_idx]; // drive 0 -> pull low; drive 1 -> release
              scl           <= 1'b0;
              phase         <= 1'b1;
            end else begin
              scl <= 1'b1; // SCL high: bit is stable, "sampled" by the slave
              phase <= 1'b0; // either way, the next bit/ACK period starts fresh at phase0
              if (bit_idx == 3'd0) begin
                state <= ST_ADDR_ACK;
              end else begin
                bit_idx <= bit_idx - 3'd1;
              end
            end
          end else div_cnt <= div_cnt + 32'd1;
        end

        ST_ADDR_ACK: begin
          if (tick) begin
            div_cnt <= 32'd0;
            if (phase == 1'b0) begin
              sda_drive_low <= 1'b0; // release SDA so the slave can ACK
              scl           <= 1'b0;
              phase         <= 1'b1;
            end else begin
              scl   <= 1'b1;
              phase <= 1'b0; // next state always starts a fresh bit/ACK period at phase0
              if (sda === 1'b1) nack <= 1'b1; // no slave pulled it low: NACK
              if (sda === 1'b1) begin
                state <= ST_STOP; // abort the transfer, still issue a clean STOP
              end else if (rw_r) begin
                bit_idx <= 3'd7;
                state   <= ST_RDATA;
              end else begin
                bit_idx <= 3'd7;
                state   <= ST_WDATA;
              end
            end
          end else div_cnt <= div_cnt + 32'd1;
        end

        ST_WDATA: begin
          if (tick) begin
            div_cnt <= 32'd0;
            if (phase == 1'b0) begin
              sda_drive_low <= ~tx_shift[bit_idx];
              scl           <= 1'b0;
              phase         <= 1'b1;
            end else begin
              scl   <= 1'b1;
              phase <= 1'b0;
              if (bit_idx == 3'd0) state <= ST_WDATA_ACK;
              else bit_idx <= bit_idx - 3'd1;
            end
          end else div_cnt <= div_cnt + 32'd1;
        end

        ST_WDATA_ACK: begin
          if (tick) begin
            div_cnt <= 32'd0;
            if (phase == 1'b0) begin
              sda_drive_low <= 1'b0;
              scl           <= 1'b0;
              phase         <= 1'b1;
            end else begin
              scl   <= 1'b1;
              phase <= 1'b0;
              if (sda === 1'b1) nack <= 1'b1;
              state <= ST_STOP;
            end
          end else div_cnt <= div_cnt + 32'd1;
        end

        ST_RDATA: begin
          if (tick) begin
            div_cnt <= 32'd0;
            if (phase == 1'b0) begin
              sda_drive_low <= 1'b0; // release: slave drives SDA for a read
              scl           <= 1'b0;
              phase         <= 1'b1;
            end else begin
              scl      <= 1'b1;
              phase    <= 1'b0;
              rx_shift <= {rx_shift[6:0], (sda === 1'b1)};
              if (bit_idx == 3'd0) state <= ST_RDATA_ACK;
              else bit_idx <= bit_idx - 3'd1;
            end
          end else div_cnt <= div_cnt + 32'd1;
        end

        // Single-byte read: master always NACKs (tells the slave "no more
        // bytes"), then STOPs.
        ST_RDATA_ACK: begin
          if (tick) begin
            div_cnt <= 32'd0;
            if (phase == 1'b0) begin
              sda_drive_low <= 1'b0; // NACK = release SDA (pullup takes it high); single-byte read never ACKs
              scl           <= 1'b0;
              phase         <= 1'b1;
            end else begin
              scl        <= 1'b1;
              phase      <= 1'b0;
              rxdata_reg <= rx_shift;
              state      <= ST_STOP;
            end
          end else div_cnt <= div_cnt + 32'd1;
        end

        // SDA rises while SCL is high (the actual stop condition).
        ST_STOP: begin
          if (tick) begin
            div_cnt <= 32'd0;
            if (phase == 1'b0) begin
              sda_drive_low <= 1'b1; // ensure SDA is low first
              scl           <= 1'b0;
              phase         <= 1'b1;
            end else if (phase == 1'b1 && scl == 1'b0) begin
              scl <= 1'b1; // SCL back high, SDA still low
            end else begin
              sda_drive_low <= 1'b0; // release -> SDA rises while SCL high: STOP
              busy          <= 1'b0;
              done          <= 1'b1;
              irq_pulse     <= 1'b1;
              state         <= ST_IDLE;
            end
          end else div_cnt <= div_cnt + 32'd1;
        end

        default: state <= ST_IDLE;
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
          REG_CTRL:   s_rdata <= {30'b0, rw_r, 1'b0};
          REG_ADDR:   s_rdata <= {25'b0, addr_reg};
          REG_TXDATA: s_rdata <= {24'b0, txdata_reg};
          REG_RXDATA: s_rdata <= {24'b0, rxdata_reg};
          REG_STATUS: s_rdata <= {29'b0, nack, done, busy};
          REG_DIVIDER: s_rdata <= divider_reg;
          default:    s_rdata <= 32'b0;
        endcase
        s_rresp  <= `AXI_RESP_OKAY;
        s_rvalid <= 1'b1;
      end else begin
        s_rvalid <= 1'b0;
      end
    end
  end

  // ADDR/TXDATA are plain read/write registers, latched into the working
  // regs (addr_rw/tx_shift) at START.
  reg [6:0] addr_reg;
  reg [7:0] txdata_reg;
  always @(posedge clk) begin
    if (!resetn) begin
      addr_reg   <= 7'h0;
      txdata_reg <= 8'h0;
    end else begin
      if (do_write && aw_offset == REG_ADDR)   addr_reg   <= s_wdata[6:0];
      if (do_write && aw_offset == REG_TXDATA) txdata_reg <= s_wdata[7:0];
    end
  end
endmodule

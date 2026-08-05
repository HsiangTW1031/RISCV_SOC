`include "axi_lite.vh"

// AES-128 AXI4-Lite peripheral: register interface wrapping aes_chain.v
// (Phase 6: ECB/CBC/CTR mode-of-operation wrapper around the unmodified
// Phase 4 aes_core.v, iterative, ~21 cycles/block per ECB primitive call).
// Single in-flight block per transfer, same "no queue" convention as
// every other peripheral in this project: a START while busy is ignored.
//
// Register map (byte offsets):
//   0x00 CTRL   (r/w) — bit[0] START (write 1 to process ONE block using
//                       the current IV/counter state; ignored if busy).
//                       bit[1] ENCDEC (0=encrypt, 1=decrypt), latched at
//                       START. bits[3:2] MODE (00=ECB, 01=CBC, 10=CTR),
//                       latched at START. bit[4] LOAD_IV (write 1 to
//                       latch IV0-3 as the running IV/counter, at the
//                       start of a new message -- ignored if busy).
//   0x04 STATUS (r/w) — bit[0] BUSY (read-only); bit[1] DONE (sticky,
//                       write-1-to-clear).
//   0x10 KEY0   (WO)  — key bytes [0:3]  (MSB word). } write-only: unlike
//   0x14 KEY1   (WO)  — key bytes [4:7]                every other R/W
//   0x18 KEY2   (WO)  — key bytes [8:11]                register in this
//   0x1C KEY3   (WO)  — key bytes [12:15] (LSB word)  } project, reads
//                       back as 0 -- a real secure core should never let
//                       software (or a debugger) read the key back out of
//                       a register. See docs/specs/aes_notes.md.
//   0x20 DATA0  (r/w) — plaintext/ciphertext-in bytes [0:3]  (MSB word)
//   0x24 DATA1  (r/w) — bytes [4:7]
//   0x28 DATA2  (r/w) — bytes [8:11]
//   0x2C DATA3  (r/w) — bytes [12:15] (LSB word)
//   0x30 RESULT0 (RO) — ciphertext/plaintext-out bytes [0:3]  (MSB word)
//   0x34 RESULT1 (RO) — bytes [4:7]
//   0x38 RESULT2 (RO) — bytes [8:11]
//   0x3C RESULT3 (RO) — bytes [12:15] (LSB word), valid once DONE is set
//   0x40 IV0    (r/w) — IV/counter bytes [0:3]  (MSB word). Not secret
//   0x44 IV1    (r/w) — bytes [4:7]              (unlike KEY), so plain
//   0x48 IV2    (r/w) — bytes [8:11]              R/W is fine; also
//   0x4C IV3    (r/w) — bytes [12:15] (LSB word)   readable to see the
//                       chain's current state (e.g. mid-message CTR value)
//
// Byte order: DATA0/RESULT0/KEY0/IV0 hold the MOST significant 4 bytes of
// the 128-bit block (bytes 0-3 in FIPS-197's column-major state layout),
// so a test vector's hex words can be copied straight across in order --
// see aes_core.v's header comment for the underlying byte convention.
//
// `irq` is a single-cycle pulse on block completion, same LATCHED_IRQ
// rationale as every other peripheral here (see timer.v's header comment).
module aes (
    input  wire        clk,
    input  wire        resetn,

    input  wire        s_awvalid, output wire s_awready, input wire [31:0] s_awaddr,
    input  wire        s_wvalid,  output wire s_wready,  input wire [31:0] s_wdata, input wire [3:0] s_wstrb,
    output reg          s_bvalid,  input wire  s_bready,  output reg [1:0] s_bresp,
    input  wire        s_arvalid, output wire s_arready, input wire [31:0] s_araddr,
    output reg          s_rvalid,  input wire  s_rready,  output reg [31:0] s_rdata, output reg [1:0] s_rresp,

    output wire         irq
);
  // NB: these need 7 bits, not 6 -- REG_IV3=0x4C doesn't fit in 6 bits
  // (a real bug caught here: `6'h40` truncates to 0, colliding with
  // REG_CTRL's offset, exactly the same class of mistake as spi_master.v's
  // REG_STATUS in Phase 3).
  localparam REG_CTRL    = 7'h00;
  localparam REG_STATUS  = 7'h04;
  localparam REG_KEY0    = 7'h10;
  localparam REG_KEY1    = 7'h14;
  localparam REG_KEY2    = 7'h18;
  localparam REG_KEY3    = 7'h1C;
  localparam REG_DATA0   = 7'h20;
  localparam REG_DATA1   = 7'h24;
  localparam REG_DATA2   = 7'h28;
  localparam REG_DATA3   = 7'h2C;
  localparam REG_RESULT0 = 7'h30;
  localparam REG_RESULT1 = 7'h34;
  localparam REG_RESULT2 = 7'h38;
  localparam REG_RESULT3 = 7'h3C;
  localparam REG_IV0     = 7'h40;
  localparam REG_IV1     = 7'h44;
  localparam REG_IV2     = 7'h48;
  localparam REG_IV3     = 7'h4C;

  reg [127:0] key_reg;
  reg [127:0] data_reg;
  reg [127:0] iv_reg;
  reg         encdec_reg;
  reg  [1:0]  mode_reg;
  reg         status_done;
  reg         irq_pulse;

  wire        core_busy, core_done;
  wire [127:0] core_data_out;

  assign irq = irq_pulse;

  assign s_awready = 1'b1;
  assign s_wready  = 1'b1;
  assign s_arready = 1'b1;

  wire [6:0] aw_offset = s_awaddr[6:0];
  wire [6:0] ar_offset = s_araddr[6:0];
  wire       do_write   = s_awvalid && s_wvalid;
  wire       do_start    = do_write && (aw_offset == REG_CTRL) && s_wdata[0] && !core_busy;
  wire       do_load_iv  = do_write && (aw_offset == REG_CTRL) && s_wdata[4] && !core_busy;

  aes_chain u_chain (
      .clk(clk), .resetn(resetn),
      .load_iv(do_load_iv), .iv_in(iv_reg),
      .start(do_start),
      .encdec(s_wdata[1]),
      .mode(s_wdata[3:2]),
      .key_in(key_reg),
      .data_in(data_reg),
      .busy(core_busy),
      .done(core_done),
      .data_out(core_data_out),
      .iv_out(iv_reg_next)
  );
  wire [127:0] iv_reg_next;

  always @(posedge clk) begin
    if (!resetn) begin
      key_reg     <= 128'h0;
      data_reg    <= 128'h0;
      iv_reg      <= 128'h0;
      status_done <= 1'b0;
      irq_pulse   <= 1'b0;
    end else begin
      irq_pulse <= core_done; // single-cycle pulse, mirrors core_done exactly

      if (core_done) status_done <= 1'b1;
      if (do_write && aw_offset == REG_STATUS && s_wdata[1]) status_done <= 1'b0;

      // iv_reg mirrors aes_chain's own internal running IV/counter, so a
      // firmware readback of IV0-3 sees the post-block chaining state
      // (and a fresh REG_IV write still lands for the *next* load_iv).
      if (core_done) iv_reg <= iv_reg_next;

      if (do_write) begin
        case (aw_offset)
          REG_KEY0:  key_reg[127:96] <= s_wdata;
          REG_KEY1:  key_reg[95:64]  <= s_wdata;
          REG_KEY2:  key_reg[63:32]  <= s_wdata;
          REG_KEY3:  key_reg[31:0]   <= s_wdata;
          REG_DATA0: data_reg[127:96] <= s_wdata;
          REG_DATA1: data_reg[95:64]  <= s_wdata;
          REG_DATA2: data_reg[63:32]  <= s_wdata;
          REG_DATA3: data_reg[31:0]   <= s_wdata;
          REG_IV0:   iv_reg[127:96]  <= s_wdata;
          REG_IV1:   iv_reg[95:64]   <= s_wdata;
          REG_IV2:   iv_reg[63:32]   <= s_wdata;
          REG_IV3:   iv_reg[31:0]    <= s_wdata;
          default: ; // CTRL/STATUS handled above; RESULT*/unknown: no register to write
        endcase
        s_bresp  <= `AXI_RESP_OKAY;
        s_bvalid <= 1'b1;
      end else begin
        s_bvalid <= 1'b0;
      end

      if (s_arvalid) begin
        case (ar_offset)
          REG_CTRL:    s_rdata <= {27'b0, mode_reg, encdec_reg, 1'b0};
          REG_STATUS:  s_rdata <= {30'b0, status_done, core_busy};
          REG_RESULT0: s_rdata <= core_data_out[127:96];
          REG_RESULT1: s_rdata <= core_data_out[95:64];
          REG_RESULT2: s_rdata <= core_data_out[63:32];
          REG_RESULT3: s_rdata <= core_data_out[31:0];
          REG_DATA0:   s_rdata <= data_reg[127:96];
          REG_DATA1:   s_rdata <= data_reg[95:64];
          REG_DATA2:   s_rdata <= data_reg[63:32];
          REG_DATA3:   s_rdata <= data_reg[31:0];
          REG_IV0:     s_rdata <= iv_reg[127:96];
          REG_IV1:     s_rdata <= iv_reg[95:64];
          REG_IV2:     s_rdata <= iv_reg[63:32];
          REG_IV3:     s_rdata <= iv_reg[31:0];
          default:     s_rdata <= 32'b0; // KEY*: write-only, always reads 0
        endcase
        s_rresp  <= `AXI_RESP_OKAY;
        s_rvalid <= 1'b1;
      end else begin
        s_rvalid <= 1'b0;
      end
    end
  end

  // mode_reg/encdec_reg are latched at START (mirroring what aes_chain.v
  // itself latches internally), purely so CTRL reads back the most
  // recently started operation's direction/mode.
  always @(posedge clk) begin
    if (!resetn) begin
      encdec_reg <= 1'b0;
      mode_reg   <= 2'b0;
    end else if (do_start) begin
      encdec_reg <= s_wdata[1];
      mode_reg   <= s_wdata[3:2];
    end
  end
endmodule

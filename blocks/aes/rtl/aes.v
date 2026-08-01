`include "axi_lite.vh"

// AES-128 AXI4-Lite peripheral: register interface wrapping aes_core.v
// (encrypt+decrypt, iterative, ~21 cycles/block -- see aes_core.v's header
// comment). Single in-flight block per transfer, same "no queue"
// convention as every other peripheral in this project: a START while
// busy is ignored.
//
// Register map (byte offsets):
//   0x00 CTRL   (r/w) — bit[0] START (write 1 to begin; ignored if busy).
//                       bit[1] ENCDEC (0=encrypt, 1=decrypt), latched at
//                       START.
//   0x04 STATUS (r/w) — bit[0] BUSY (read-only); bit[1] DONE (sticky,
//                       write-1-to-clear).
//   0x10 KEY0   (WO)  — key bytes [0:3]  (MSB word). } write-only: unlike
//   0x14 KEY1   (WO)  — key bytes [4:7]                every other R/W
//   0x18 KEY2   (WO)  — key bytes [8:11]                register in this
//   0x1C KEY3   (WO)  — key bytes [12:15] (LSB word)  } project, reads
//                       back as 0 -- a real secure core should never let
//                       software (or a debugger) read the key back out of
//                       a register. See docs/aes_report.md.
//   0x20 DATA0  (r/w) — plaintext/ciphertext-in bytes [0:3]  (MSB word)
//   0x24 DATA1  (r/w) — bytes [4:7]
//   0x28 DATA2  (r/w) — bytes [8:11]
//   0x2C DATA3  (r/w) — bytes [12:15] (LSB word)
//   0x30 RESULT0 (RO) — ciphertext/plaintext-out bytes [0:3]  (MSB word)
//   0x34 RESULT1 (RO) — bytes [4:7]
//   0x38 RESULT2 (RO) — bytes [8:11]
//   0x3C RESULT3 (RO) — bytes [12:15] (LSB word), valid once DONE is set
//
// Byte order: DATA0/RESULT0/KEY0 hold the MOST significant 4 bytes of the
// 128-bit block (bytes 0-3 in FIPS-197's column-major state layout), so a
// FIPS-197 test vector's hex words can be copied straight across in order
// -- see aes_core.v's header comment for the underlying byte convention.
//
// `irq` is a single-cycle pulse on block completion, same LATCHED_IRQ
// rationale as every other peripheral here (see timer.v's header comment).
module aes (
    input  wire        clk,
    input  wire        rst,

    input  wire        s_awvalid, output wire s_awready, input wire [31:0] s_awaddr,
    input  wire        s_wvalid,  output wire s_wready,  input wire [31:0] s_wdata, input wire [3:0] s_wstrb,
    output reg          s_bvalid,  input wire  s_bready,  output reg [1:0] s_bresp,
    input  wire        s_arvalid, output wire s_arready, input wire [31:0] s_araddr,
    output reg          s_rvalid,  input wire  s_rready,  output reg [31:0] s_rdata, output reg [1:0] s_rresp,

    output wire         irq
);
  localparam REG_CTRL    = 6'h00;
  localparam REG_STATUS  = 6'h04;
  localparam REG_KEY0    = 6'h10;
  localparam REG_KEY1    = 6'h14;
  localparam REG_KEY2    = 6'h18;
  localparam REG_KEY3    = 6'h1C;
  localparam REG_DATA0   = 6'h20;
  localparam REG_DATA1   = 6'h24;
  localparam REG_DATA2   = 6'h28;
  localparam REG_DATA3   = 6'h2C;
  localparam REG_RESULT0 = 6'h30;
  localparam REG_RESULT1 = 6'h34;
  localparam REG_RESULT2 = 6'h38;
  localparam REG_RESULT3 = 6'h3C;

  reg [127:0] key_reg;
  reg [127:0] data_reg;
  reg         encdec_reg;
  reg         status_done;
  reg         irq_pulse;

  wire        core_busy, core_done;
  wire [127:0] core_data_out;

  assign irq = irq_pulse;

  assign s_awready = 1'b1;
  assign s_wready  = 1'b1;
  assign s_arready = 1'b1;

  wire [5:0] aw_offset = s_awaddr[5:0];
  wire [5:0] ar_offset = s_araddr[5:0];
  wire       do_write  = s_awvalid && s_wvalid;
  wire       do_start  = do_write && (aw_offset == REG_CTRL) && s_wdata[0] && !core_busy;

  aes_core u_core (
      .clk(clk), .rst(rst),
      .start(do_start),
      .encdec(s_wdata[1]),
      .key_in(key_reg),
      .data_in(data_reg),
      .busy(core_busy),
      .done(core_done),
      .data_out(core_data_out)
  );

  always @(posedge clk) begin
    if (rst) begin
      key_reg     <= 128'h0;
      data_reg    <= 128'h0;
      status_done <= 1'b0;
      irq_pulse   <= 1'b0;
    end else begin
      irq_pulse <= core_done; // single-cycle pulse, mirrors core_done exactly

      if (core_done) status_done <= 1'b1;
      if (do_write && aw_offset == REG_STATUS && s_wdata[1]) status_done <= 1'b0;

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
          default: ; // CTRL/STATUS handled above; RESULT*/unknown: no register to write
        endcase
        s_bresp  <= `AXI_RESP_OKAY;
        s_bvalid <= 1'b1;
      end else begin
        s_bvalid <= 1'b0;
      end

      if (s_arvalid) begin
        case (ar_offset)
          REG_CTRL:    s_rdata <= {30'b0, encdec_reg, 1'b0};
          REG_STATUS:  s_rdata <= {30'b0, status_done, core_busy};
          REG_RESULT0: s_rdata <= core_data_out[127:96];
          REG_RESULT1: s_rdata <= core_data_out[95:64];
          REG_RESULT2: s_rdata <= core_data_out[63:32];
          REG_RESULT3: s_rdata <= core_data_out[31:0];
          REG_DATA0:   s_rdata <= data_reg[127:96];
          REG_DATA1:   s_rdata <= data_reg[95:64];
          REG_DATA2:   s_rdata <= data_reg[63:32];
          REG_DATA3:   s_rdata <= data_reg[31:0];
          default:     s_rdata <= 32'b0; // KEY*: write-only, always reads 0
        endcase
        s_rresp  <= `AXI_RESP_OKAY;
        s_rvalid <= 1'b1;
      end else begin
        s_rvalid <= 1'b0;
      end
    end
  end

  // encdec_reg is latched at START (mirrors what aes_core.v itself latches
  // internally), purely so CTRL reads back the direction of the
  // most-recently-started operation.
  always @(posedge clk) begin
    if (rst) encdec_reg <= 1'b0;
    else if (do_start) encdec_reg <= s_wdata[1];
  end
endmodule

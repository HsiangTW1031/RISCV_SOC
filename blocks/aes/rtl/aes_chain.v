// AES-128 mode-of-operation wrapper around the unmodified Phase 4
// aes_core.v (single-block ECB primitive) -- adds CBC and CTR chaining
// entirely as IV/counter bookkeeping + XOR logic around that primitive,
// per NIST SP 800-38A. aes_core.v itself is reused as-is; this module is
// the only place mode-of-operation behavior lives.
//
// MODE encoding: 2'b00 = ECB (single block, no chaining -- data_in goes
// straight through aes_core), 2'b01 = CBC, 2'b10 = CTR.
//
// Usage for a multi-block message: pulse `load_iv` once (with the
// message's actual IV/nonce on `iv_in`) before the first block, then
// pulse `start` once per block thereafter -- the running IV/counter state
// (`iv_reg`, exposed on `iv_out`) auto-advances after each block
// completes, so neither firmware nor a driving DMA engine has to compute
// the next IV itself.
//
// CBC (NIST SP 800-38A 6.2):
//   encrypt: C_i = AES_encrypt(P_i XOR C_{i-1}), C_0 := IV
//   decrypt: P_i = AES_decrypt(C_i) XOR C_{i-1}, C_0 := IV
//   Both directions feed the *ciphertext* block back in as the next IV --
//   for encrypt that's aes_core's own output; for decrypt it's this
//   block's *input* (data_in_reg, captured at `start`), not its output.
//
// CTR (NIST SP 800-38A 6.5): keystream_i = AES_encrypt(counter_i),
//   output = data_in XOR keystream_i, counter_{i+1} = counter_i + 1.
//   Both directions are the identical operation (XOR is its own inverse)
//   and always run aes_core in the ENCRYPT direction to generate the
//   keystream, regardless of the chain's own encdec setting.
module aes_chain (
    input  wire         clk,
    input  wire         resetn,

    input  wire         load_iv,     // pulse: latch iv_in as the running IV/counter (start of a new message)
    input  wire [127:0] iv_in,

    input  wire         start,       // pulse: process ONE block using the CURRENT iv/counter state
    input  wire         encdec,      // 0=encrypt, 1=decrypt; latched at start (ignored in CTR mode's core call)
    input  wire [1:0]   mode,        // 0=ECB, 1=CBC, 2=CTR; latched at start
    input  wire [127:0] key_in,
    input  wire [127:0] data_in,

    output wire         busy,
    output wire         done,        // single-cycle pulse
    output wire [127:0] data_out,
    output wire [127:0] iv_out       // current IV/counter state (read-back/debug)
);
  localparam MODE_ECB = 2'd0;
  localparam MODE_CBC = 2'd1;
  localparam MODE_CTR = 2'd2;

  localparam ST_IDLE  = 2'd0;
  localparam ST_CORE  = 2'd1; // waiting for aes_core

  reg  [1:0]   state;
  reg  [1:0]   mode_reg;
  reg          encdec_reg;
  reg  [127:0] data_in_reg;
  reg  [127:0] iv_reg;
  reg  [127:0] data_out_reg;
  reg          done_reg;

  // NB: these two must key off the LIVE `mode`/`encdec` input ports, not
  // `mode_reg`/`encdec_reg` -- they're only ever meaningful at the exact
  // edge `core_start` fires (aes_core latches data_in/encdec on that same
  // edge and never reads them again), which is the SAME edge that latches
  // mode_reg/encdec_reg themselves; reading the *_reg versions here would
  // see their stale, not-yet-updated value from the previous operation
  // (caught by simulation: the very first CBC block was silently encrypted
  // as if mode_reg were still its reset value, i.e. plain ECB, giving the
  // right-looking-but-wrong NIST ECB test vector instead of the CBC one).
  wire core_start   = (state == ST_IDLE) && start;
  wire core_encdec  = (mode == MODE_CTR) ? 1'b0 : encdec;
  wire [127:0] core_data_in =
      (mode == MODE_CBC && !encdec) ? (data_in ^ iv_reg) : // CBC encrypt: XOR with running IV first
      (mode == MODE_CTR)            ? iv_reg              : // CTR: encrypt the counter
                                        data_in;             // ECB, and CBC decrypt: ciphertext goes straight in

  wire        core_busy, core_done;
  wire [127:0] core_data_out;

  aes_core u_core (
      .clk(clk), .resetn(resetn),
      .start(core_start), .encdec(core_encdec),
      .key_in(key_in), .data_in(core_data_in),
      .busy(core_busy), .done(core_done), .data_out(core_data_out)
  );

  assign busy     = (state != ST_IDLE);
  assign done     = done_reg;
  assign data_out = data_out_reg;
  assign iv_out   = iv_reg;

  always @(posedge clk) begin
    if (!resetn) begin
      state    <= ST_IDLE;
      done_reg <= 1'b0;
      iv_reg   <= 128'h0;
    end else begin
      done_reg <= 1'b0;

      if (load_iv) iv_reg <= iv_in;

      case (state)
        ST_IDLE: begin
          if (start) begin
            mode_reg    <= mode;
            encdec_reg  <= encdec;
            data_in_reg <= data_in;
            state       <= ST_CORE;
          end
        end

        ST_CORE: begin
          if (core_done) begin
            case (mode_reg)
              MODE_CBC: begin
                if (!encdec_reg) begin
                  data_out_reg <= core_data_out;
                  iv_reg       <= core_data_out;      // encrypt: next IV = this ciphertext
                end else begin
                  data_out_reg <= core_data_out ^ iv_reg;
                  iv_reg       <= data_in_reg;         // decrypt: next IV = this (input) ciphertext
                end
              end
              MODE_CTR: begin
                data_out_reg <= data_in_reg ^ core_data_out; // core_data_out is the keystream
                iv_reg       <= iv_reg + 128'd1;
              end
              default: begin // ECB
                data_out_reg <= core_data_out;
              end
            endcase
            done_reg <= 1'b1;
            state    <= ST_IDLE;
          end
        end

        default: state <= ST_IDLE;
      endcase
    end
  end
endmodule

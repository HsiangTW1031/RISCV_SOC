// AES-128 iterative core (encrypt + decrypt), FIPS-197. One round per
// clock cycle; a block operation is:
//   10 cycles: key expansion (aes_key_expand.v runs its own sequential
//              schedule; both directions need all 11 round keys up front
//              -- decrypt starts from rk10, which can't be produced
//              without first walking the schedule all the way there)
//   1 cycle:   initial AddRoundKey (rk0 for encrypt, rk10 for decrypt)
//   9 cycles:  "middle" rounds
//   1 cycle:   final round (no MixColumns/InvMixColumns)
// ~21 cycles/block total. This is deliberately not pipelined or unrolled
// across rounds or overlapped with key expansion -- the point of this
// core is a small, auditable, single-round-datapath-reused-every-cycle
// design; see docs/specs/aes_notes.md for the area/latency tradeoff writeup.
//
// State byte order: bit [127:120] of a 128-bit word is byte 0, down to
// bit [7:0] as byte 15, in FIPS-197's column-major layout (byte i sits at
// state row i%4, column i/4). This matches copying a FIPS-197 test vector's
// hex bytes left-to-right straight into the vector's top bits, and is also
// exactly how aes.v exposes DATA0..DATA3 to the AXI-Lite bus (DATA0 =
// bits[127:96] = bytes 0-3, etc.) -- see aes.v's header comment.
//
// Middle-round transform order per FIPS-197:
//   encrypt: SubBytes -> ShiftRows -> MixColumns -> AddRoundKey
//   decrypt: InvShiftRows -> InvSubBytes -> AddRoundKey -> InvMixColumns
// (this is the straightforward Inverse Cipher from FIPS-197 5.3, not the
// reordered "Equivalent Inverse Cipher" -- simpler to follow directly
// against the spec, at the cost of decrypt not sharing literally the same
// round structure as encrypt.)
module aes_core (
    input  wire         clk,
    input  wire         resetn,

    input  wire         start,       // pulse: begin one block operation
    input  wire         encdec,      // 0 = encrypt, 1 = decrypt; latched at start
    input  wire [127:0] key_in,
    input  wire [127:0] data_in,     // plaintext (encrypt) or ciphertext (decrypt)

    output reg          busy,
    output reg          done,        // single-cycle pulse when data_out is valid
    output reg  [127:0] data_out
);
`include "aes_pkg.vh"

  localparam ST_IDLE   = 2'd0;
  localparam ST_KEYEXP = 2'd1;
  localparam ST_ROUND  = 2'd2;
  localparam ST_FINAL  = 2'd3;

  reg [1:0]   state;
  reg         encdec_reg;
  reg [3:0]   rnum;       // round-key index currently selected
  reg [127:0] data_reg;

  wire          ke_start = (state == ST_IDLE) && start;
  wire          ke_done;
  wire [1407:0] round_keys;

  aes_key_expand u_key_expand (
      .clk(clk), .resetn(resetn),
      .start(ke_start),
      .key_in(key_in),
      .done(ke_done),
      .round_keys(round_keys)
  );

  wire [127:0] rk_sel = round_keys[128*rnum +: 128];

  // ---- byte/column helpers ----
  function [7:0] byte_at;
    input [127:0] s;
    input [3:0]   i;
    begin
      byte_at = s[(15-i)*8 +: 8];
    end
  endfunction

  function [127:0] aes_sub_bytes;
    input [127:0] s;
    begin
      aes_sub_bytes = {
        aes_sbox_fwd(byte_at(s,0)),  aes_sbox_fwd(byte_at(s,1)),  aes_sbox_fwd(byte_at(s,2)),  aes_sbox_fwd(byte_at(s,3)),
        aes_sbox_fwd(byte_at(s,4)),  aes_sbox_fwd(byte_at(s,5)),  aes_sbox_fwd(byte_at(s,6)),  aes_sbox_fwd(byte_at(s,7)),
        aes_sbox_fwd(byte_at(s,8)),  aes_sbox_fwd(byte_at(s,9)),  aes_sbox_fwd(byte_at(s,10)), aes_sbox_fwd(byte_at(s,11)),
        aes_sbox_fwd(byte_at(s,12)), aes_sbox_fwd(byte_at(s,13)), aes_sbox_fwd(byte_at(s,14)), aes_sbox_fwd(byte_at(s,15))
      };
    end
  endfunction

  function [127:0] aes_inv_sub_bytes;
    input [127:0] s;
    begin
      aes_inv_sub_bytes = {
        aes_sbox_inv(byte_at(s,0)),  aes_sbox_inv(byte_at(s,1)),  aes_sbox_inv(byte_at(s,2)),  aes_sbox_inv(byte_at(s,3)),
        aes_sbox_inv(byte_at(s,4)),  aes_sbox_inv(byte_at(s,5)),  aes_sbox_inv(byte_at(s,6)),  aes_sbox_inv(byte_at(s,7)),
        aes_sbox_inv(byte_at(s,8)),  aes_sbox_inv(byte_at(s,9)),  aes_sbox_inv(byte_at(s,10)), aes_sbox_inv(byte_at(s,11)),
        aes_sbox_inv(byte_at(s,12)), aes_sbox_inv(byte_at(s,13)), aes_sbox_inv(byte_at(s,14)), aes_sbox_inv(byte_at(s,15))
      };
    end
  endfunction

  // ShiftRows: out_byte[i] = in_byte[fwd[i]], fwd derived from
  // s'(r,c) = s(r, (c+r) mod 4) -- see docs/specs/aes_notes.md for the
  // derivation script; not hand-computed from the (c+r) mod 4 formula
  // directly to avoid an off-by-one slipping in.
  function [127:0] aes_shift_rows;
    input [127:0] s;
    begin
      aes_shift_rows = {
        byte_at(s,0),  byte_at(s,5),  byte_at(s,10), byte_at(s,15),
        byte_at(s,4),  byte_at(s,9),  byte_at(s,14), byte_at(s,3),
        byte_at(s,8),  byte_at(s,13), byte_at(s,2),  byte_at(s,7),
        byte_at(s,12), byte_at(s,1),  byte_at(s,6),  byte_at(s,11)
      };
    end
  endfunction

  function [127:0] aes_inv_shift_rows;
    input [127:0] s;
    begin
      aes_inv_shift_rows = {
        byte_at(s,0),  byte_at(s,13), byte_at(s,10), byte_at(s,7),
        byte_at(s,4),  byte_at(s,1),  byte_at(s,14), byte_at(s,11),
        byte_at(s,8),  byte_at(s,5),  byte_at(s,2),  byte_at(s,15),
        byte_at(s,12), byte_at(s,9),  byte_at(s,6),  byte_at(s,3)
      };
    end
  endfunction

  function [31:0] aes_mix_column;
    input [7:0] s0, s1, s2, s3;
    begin
      aes_mix_column = {
        aes_gmul2(s0) ^ aes_gmul3(s1) ^ s2 ^ s3,
        s0 ^ aes_gmul2(s1) ^ aes_gmul3(s2) ^ s3,
        s0 ^ s1 ^ aes_gmul2(s2) ^ aes_gmul3(s3),
        aes_gmul3(s0) ^ s1 ^ s2 ^ aes_gmul2(s3)
      };
    end
  endfunction

  function [31:0] aes_inv_mix_column;
    input [7:0] s0, s1, s2, s3;
    begin
      aes_inv_mix_column = {
        aes_gmul14(s0) ^ aes_gmul11(s1) ^ aes_gmul13(s2) ^ aes_gmul9(s3),
        aes_gmul9(s0)  ^ aes_gmul14(s1) ^ aes_gmul11(s2) ^ aes_gmul13(s3),
        aes_gmul13(s0) ^ aes_gmul9(s1)  ^ aes_gmul14(s2) ^ aes_gmul11(s3),
        aes_gmul11(s0) ^ aes_gmul13(s1) ^ aes_gmul9(s2)  ^ aes_gmul14(s3)
      };
    end
  endfunction

  function [127:0] aes_mix_columns;
    input [127:0] s;
    begin
      aes_mix_columns = {
        aes_mix_column(byte_at(s,0),  byte_at(s,1),  byte_at(s,2),  byte_at(s,3)),
        aes_mix_column(byte_at(s,4),  byte_at(s,5),  byte_at(s,6),  byte_at(s,7)),
        aes_mix_column(byte_at(s,8),  byte_at(s,9),  byte_at(s,10), byte_at(s,11)),
        aes_mix_column(byte_at(s,12), byte_at(s,13), byte_at(s,14), byte_at(s,15))
      };
    end
  endfunction

  function [127:0] aes_inv_mix_columns;
    input [127:0] s;
    begin
      aes_inv_mix_columns = {
        aes_inv_mix_column(byte_at(s,0),  byte_at(s,1),  byte_at(s,2),  byte_at(s,3)),
        aes_inv_mix_column(byte_at(s,4),  byte_at(s,5),  byte_at(s,6),  byte_at(s,7)),
        aes_inv_mix_column(byte_at(s,8),  byte_at(s,9),  byte_at(s,10), byte_at(s,11)),
        aes_inv_mix_column(byte_at(s,12), byte_at(s,13), byte_at(s,14), byte_at(s,15))
      };
    end
  endfunction

  // ---- combinational round transforms (see header comment for order) ----
  wire [127:0] sub_shift_enc = aes_shift_rows(aes_sub_bytes(data_reg));
  wire [127:0] enc_round_next = aes_mix_columns(sub_shift_enc) ^ rk_sel;
  wire [127:0] enc_final_next = sub_shift_enc ^ rk_sel;

  wire [127:0] sub_shift_dec = aes_inv_sub_bytes(aes_inv_shift_rows(data_reg));
  wire [127:0] dec_round_next = aes_inv_mix_columns(sub_shift_dec ^ rk_sel);
  wire [127:0] dec_final_next = sub_shift_dec ^ rk_sel;

  always @(posedge clk) begin
    if (!resetn) begin
      state <= ST_IDLE;
      busy  <= 1'b0;
      done  <= 1'b0;
    end else begin
      done <= 1'b0;

      case (state)
        ST_IDLE: begin
          busy <= 1'b0;
          if (start) begin
            encdec_reg <= encdec;
            data_reg   <= data_in;
            busy       <= 1'b1;
            state      <= ST_KEYEXP;
          end
        end

        ST_KEYEXP: begin
          if (ke_done) begin
            if (encdec_reg) begin // decrypt: start from rk10
              data_reg <= data_reg ^ round_keys[128*10 +: 128];
              rnum     <= 4'd9;
            end else begin // encrypt: start from rk0
              data_reg <= data_reg ^ round_keys[128*0 +: 128];
              rnum     <= 4'd1;
            end
            state <= ST_ROUND;
          end
        end

        ST_ROUND: begin
          if (!encdec_reg) begin // encrypt: rounds 1..9 ascending
            data_reg <= enc_round_next;
            if (rnum == 4'd9) begin
              rnum  <= 4'd10;
              state <= ST_FINAL;
            end else begin
              rnum <= rnum + 4'd1;
            end
          end else begin // decrypt: rounds 9..1 descending
            data_reg <= dec_round_next;
            if (rnum == 4'd1) begin
              rnum  <= 4'd0;
              state <= ST_FINAL;
            end else begin
              rnum <= rnum - 4'd1;
            end
          end
        end

        ST_FINAL: begin
          data_out <= encdec_reg ? dec_final_next : enc_final_next;
          busy     <= 1'b0;
          done     <= 1'b1;
          state    <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end
endmodule

// AES-128 key expansion (FIPS-197 5.2), iterative: one new round key per
// clock cycle, matching the "iterative, resource-shared" spirit of the
// round datapath in aes_core.v (a fully unrolled/combinational key
// schedule would be trivial to write but would dominate the area report
// in a way inconsistent with that story, so this deliberately stays a
// 10-cycle sequential process instead of one big combinational chain).
//
// Since Nk=4 (AES-128), every new round key's first word gets the
// RotWord/SubWord/XOR-Rcon treatment, and the other three words are a
// straight XOR chain from the previous round key -- there's no extra
// SubWord in the middle words (that only happens for Nk=8 / AES-256,
// which this core doesn't implement):
//
//   new_w0 = w0 ^ SubWord(RotWord(w3)) ^ (Rcon[r] << 24)
//   new_w1 = new_w0 ^ w1
//   new_w2 = new_w1 ^ w2
//   new_w3 = new_w2 ^ w3
//
// All 11 round keys (rk0 = the original key, rk1..rk10 = expanded) are
// computed once at `start` and held in a small register file so the
// cipher core can walk them forwards (encrypt) or backwards (decrypt)
// without recomputing anything mid-operation -- decrypt in particular
// needs rk10 before it can do anything, so partial/on-the-fly expansion
// doesn't work for that direction anyway.
module aes_key_expand (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [127:0] key_in,
    output reg          done,        // single-cycle pulse when round_keys is valid
    output wire [1407:0] round_keys  // round_keys[128*i +: 128] = rk[i], rk[0] = original key
);
`include "aes_pkg.vh"

  localparam ST_IDLE   = 1'b0;
  localparam ST_EXPAND = 1'b1;

  reg        state;
  reg [3:0]  round_idx;  // which round key we're about to PRODUCE (1..10)
  reg [127:0] rk [0:10];

  assign round_keys = {rk[10], rk[9], rk[8], rk[7], rk[6], rk[5], rk[4], rk[3], rk[2], rk[1], rk[0]};

  function [7:0] rcon_byte;
    input [3:0] r; // 1..10
    begin
      case (r)
        4'd1:  rcon_byte = 8'h01;
        4'd2:  rcon_byte = 8'h02;
        4'd3:  rcon_byte = 8'h04;
        4'd4:  rcon_byte = 8'h08;
        4'd5:  rcon_byte = 8'h10;
        4'd6:  rcon_byte = 8'h20;
        4'd7:  rcon_byte = 8'h40;
        4'd8:  rcon_byte = 8'h80;
        4'd9:  rcon_byte = 8'h1b;
        4'd10: rcon_byte = 8'h36;
        default: rcon_byte = 8'h00;
      endcase
    end
  endfunction

  function [31:0] sub_word;
    input [31:0] w;
    begin
      sub_word = {aes_sbox_fwd(w[31:24]), aes_sbox_fwd(w[23:16]), aes_sbox_fwd(w[15:8]), aes_sbox_fwd(w[7:0])};
    end
  endfunction

  function [31:0] rot_word;
    input [31:0] w;
    begin
      rot_word = {w[23:0], w[31:24]};
    end
  endfunction

  // combinational: the next round key derived from rk[round_idx-1]'s four
  // words, for the round about to be produced (round_idx)
  wire [31:0] prev_w0 = rk[round_idx-4'd1][127:96];
  wire [31:0] prev_w1 = rk[round_idx-4'd1][95:64];
  wire [31:0] prev_w2 = rk[round_idx-4'd1][63:32];
  wire [31:0] prev_w3 = rk[round_idx-4'd1][31:0];

  wire [31:0] new_w0 = prev_w0 ^ sub_word(rot_word(prev_w3)) ^ {rcon_byte(round_idx), 24'h0};
  wire [31:0] new_w1 = new_w0 ^ prev_w1;
  wire [31:0] new_w2 = new_w1 ^ prev_w2;
  wire [31:0] new_w3 = new_w2 ^ prev_w3;

  always @(posedge clk) begin
    if (rst) begin
      state     <= ST_IDLE;
      round_idx <= 4'd0;
      done      <= 1'b0;
    end else begin
      done <= 1'b0;
      case (state)
        ST_IDLE: begin
          if (start) begin
            rk[0]     <= key_in;
            round_idx <= 4'd1;
            state     <= ST_EXPAND;
          end
        end

        ST_EXPAND: begin
          rk[round_idx] <= {new_w0, new_w1, new_w2, new_w3};
          if (round_idx == 4'd10) begin
            done  <= 1'b1;
            state <= ST_IDLE;
          end else begin
            round_idx <= round_idx + 4'd1;
          end
        end

        default: state <= ST_IDLE;
      endcase
    end
  end
endmodule

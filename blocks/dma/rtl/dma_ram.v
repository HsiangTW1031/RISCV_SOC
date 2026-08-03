`include "axi4.vh"
`include "axi_lite.vh"

// A small scratch memory with a genuine AXI4 (burst-capable) slave port --
// the DMA engine's private target, entirely separate from the main
// 128KB SRAM/AXI4-Lite crossbar path (this project's crossbar is
// AXI4-Lite only and has no burst support; rather than rearchitect the
// whole crossbar to add bursts for every master, the DMA gets its own
// dedicated burst-capable memory -- see docs/specs/dma.md for the
// rationale). 2048 words (8KB): plenty for a source region + destination
// region for exercising multi-block DMA+AES streaming.
//
// Single-outstanding per channel (one burst in flight at a time per
// direction), always-ready at the start of a burst (AWREADY/ARREADY are
// asserted whenever idle), INCR bursts only, fixed 4-byte beats -- see
// rtl/include/axi4.vh for the documented scope cut (no FIXED/WRAP burst
// types, no narrow transfers).
module dma_ram #(
    parameter SIZE_WORDS = 2048
) (
    input  wire        clk,
    input  wire        resetn,

    // ---- AXI4 write address ----
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_awaddr,
    input  wire [`AXI4_LEN_WIDTH-1:0]   s_awlen,
    input  wire [`AXI4_SIZE_WIDTH-1:0]  s_awsize,
    input  wire [`AXI4_BURST_WIDTH-1:0] s_awburst,

    // ---- AXI4 write data ----
    input  wire        s_wvalid,
    output wire        s_wready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wlast,

    // ---- AXI4 write response ----
    output reg         s_bvalid,
    input  wire        s_bready,
    output reg  [1:0]  s_bresp,

    // ---- AXI4 read address ----
    input  wire        s_arvalid,
    output wire        s_arready,
    input  wire [31:0] s_araddr,
    input  wire [`AXI4_LEN_WIDTH-1:0]   s_arlen,
    input  wire [`AXI4_SIZE_WIDTH-1:0]  s_arsize,
    input  wire [`AXI4_BURST_WIDTH-1:0] s_arburst,

    // ---- AXI4 read data ----
    output reg         s_rvalid,
    input  wire        s_rready,
    output reg  [31:0] s_rdata,
    output reg  [1:0]  s_rresp,
    output reg         s_rlast
);
  localparam ADDR_BITS = $clog2(SIZE_WORDS);

  reg [31:0] mem [0:SIZE_WORDS-1];

  // =====================================================================
  // WRITE PATH
  // =====================================================================
  localparam W_IDLE  = 1'b0;
  localparam W_BURST = 1'b1;

  reg                  w_state;
  reg [ADDR_BITS-1:0]  w_word_idx;
  reg [`AXI4_LEN_WIDTH-1:0] w_beats_left;

  assign s_awready = (w_state == W_IDLE);
  assign s_wready  = (w_state == W_BURST);

  always @(posedge clk) begin
    if (!resetn) begin
      w_state  <= W_IDLE;
      s_bvalid <= 1'b0;
    end else begin
      case (w_state)
        W_IDLE: begin
          if (s_awvalid) begin
            w_word_idx   <= s_awaddr[ADDR_BITS+1:2];
            w_beats_left <= s_awlen;
            w_state      <= W_BURST;
          end
        end

        W_BURST: begin
          if (s_wvalid) begin
            if (s_wstrb[0]) mem[w_word_idx][7:0]   <= s_wdata[7:0];
            if (s_wstrb[1]) mem[w_word_idx][15:8]  <= s_wdata[15:8];
            if (s_wstrb[2]) mem[w_word_idx][23:16] <= s_wdata[23:16];
            if (s_wstrb[3]) mem[w_word_idx][31:24] <= s_wdata[31:24];
            w_word_idx <= w_word_idx + 1'b1;
            if (s_wlast) begin
              s_bresp  <= `AXI_RESP_OKAY;
              s_bvalid <= 1'b1;
              w_state  <= W_IDLE;
            end else begin
              w_beats_left <= w_beats_left - 1'b1;
            end
          end
        end
        default: w_state <= W_IDLE;
      endcase

      if (s_bvalid && s_bready) s_bvalid <= 1'b0;
    end
  end

  // =====================================================================
  // READ PATH
  // =====================================================================
  localparam R_IDLE  = 1'b0;
  localparam R_BURST = 1'b1;

  reg                  r_state;
  reg [ADDR_BITS-1:0]  r_word_idx;
  reg [`AXI4_LEN_WIDTH-1:0] r_beats_left;

  assign s_arready = (r_state == R_IDLE);

  always @(posedge clk) begin
    if (!resetn) begin
      r_state  <= R_IDLE;
      s_rvalid <= 1'b0;
    end else begin
      case (r_state)
        R_IDLE: begin
          s_rvalid <= 1'b0;
          if (s_arvalid) begin
            r_word_idx   <= s_araddr[ADDR_BITS+1:2];
            r_beats_left <= s_arlen;
            r_state      <= R_BURST;
          end
        end

        R_BURST: begin
          if (!s_rvalid || s_rready) begin
            s_rdata  <= mem[r_word_idx];
            s_rresp  <= `AXI_RESP_OKAY;
            s_rlast  <= (r_beats_left == 0);
            s_rvalid <= 1'b1;
            if (r_beats_left == 0) begin
              r_state <= R_IDLE;
            end else begin
              r_word_idx   <= r_word_idx + 1'b1;
              r_beats_left <= r_beats_left - 1'b1;
            end
          end
        end
        default: r_state <= R_IDLE;
      endcase
    end
  end
endmodule

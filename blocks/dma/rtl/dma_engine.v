`include "axi_lite.vh"
`include "axi4.vh"

// DMA engine: streams LEN 128-bit blocks from SRC_ADDR to DST_ADDR through
// an internally-instantiated aes_chain.v (Phase 6, ECB/CBC/CTR), entirely
// without CPU involvement per block -- firmware sets up the registers,
// writes START once, and polls (or waits on `irq`) for the whole multi-
// block operation to finish. The AXI4 burst master port talks directly
// to dma_ram.v (see that module's header for why the burst data path is
// architecturally separate from the AXI4-Lite crossbar); the AXI4-Lite
// slave control port is what's wired into the main crossbar as a normal
// peripheral, so firmware can configure/trigger this like anything else.
//
// Per block: burst-read 4 beats (128 bits) from SRC_ADDR+i*16, run it
// through aes_chain (which owns the running IV/counter across the whole
// LEN-block message), burst-write the 4-beat result to DST_ADDR+i*16,
// advance to the next block. AXI4 burst length is fixed at 4 beats
// (AWLEN/ARLEN=3) per block -- one burst per 128-bit block, not one giant
// burst for the whole message (keeps the internal buffering to a single
// 128-bit register instead of needing a message-sized FIFO).
//
// Register map (byte offsets):
//   0x00 CTRL    (r/w) — bit[0] START (begin the whole LEN-block
//                        operation; ignored if busy). bit[1] ENCDEC
//                        (0=encrypt,1=decrypt). bits[3:2] MODE (00=ECB,
//                        01=CBC, 10=CTR). Latched at START.
//   0x04 STATUS  (r/w) — bit[0] BUSY (RO); bit[1] DONE (sticky, w1c).
//   0x08 SRC_ADDR (r/w) — byte address in dma_ram for block 0's source.
//   0x0C DST_ADDR (r/w) — byte address in dma_ram for block 0's dest.
//   0x10 LEN     (r/w) — number of 128-bit blocks to process (>=1).
//   0x14 KEY0    (WO)  — key bytes [0:3] (MSB word), like aes.v's KEY0-3.
//   0x18 KEY1    (WO)  — bytes [4:7]
//   0x1C KEY2    (WO)  — bytes [8:11]
//   0x20 KEY3    (WO)  — bytes [12:15] (LSB word)
//   0x24 IV0     (r/w) — initial IV/counter bytes [0:3] (MSB word);
//   0x28 IV1     (r/w) — bytes [4:7]                      latched into
//   0x2C IV2     (r/w) — bytes [8:11]                     aes_chain via
//   0x30 IV3     (r/w) — bytes [12:15] (LSB word)          load_iv at START.
//
// `irq` is a single-cycle pulse on the WHOLE operation's completion (not
// per-block), same LATCHED_IRQ rationale as every other peripheral here.
module dma_engine (
    input  wire        clk,
    input  wire        rst,

    // ---- AXI4-Lite slave: CPU control port ----
    input  wire        s_awvalid, output wire s_awready, input wire [31:0] s_awaddr,
    input  wire        s_wvalid,  output wire s_wready,  input wire [31:0] s_wdata, input wire [3:0] s_wstrb,
    output reg          s_bvalid,  input wire  s_bready,  output reg [1:0] s_bresp,
    input  wire        s_arvalid, output wire s_arready, input wire [31:0] s_araddr,
    output reg          s_rvalid,  input wire  s_rready,  output reg [31:0] s_rdata, output reg [1:0] s_rresp,

    // ---- AXI4 master: burst port to dma_ram ----
    output reg          m_awvalid, input wire m_awready, output reg [31:0] m_awaddr,
    output reg [`AXI4_LEN_WIDTH-1:0] m_awlen, output reg [`AXI4_SIZE_WIDTH-1:0] m_awsize, output reg [`AXI4_BURST_WIDTH-1:0] m_awburst,
    output reg          m_wvalid,  input wire m_wready,  output reg [31:0] m_wdata, output reg [3:0] m_wstrb, output reg m_wlast,
    input  wire         m_bvalid,  output reg m_bready,  input wire [1:0] m_bresp,
    output reg          m_arvalid, input wire m_arready, output reg [31:0] m_araddr,
    output reg [`AXI4_LEN_WIDTH-1:0] m_arlen, output reg [`AXI4_SIZE_WIDTH-1:0] m_arsize, output reg [`AXI4_BURST_WIDTH-1:0] m_arburst,
    input  wire         m_rvalid,  output reg m_rready,  input wire [31:0] m_rdata, input wire [1:0] m_rresp, input wire m_rlast,

    output wire         irq
);
  localparam REG_CTRL     = 7'h00;
  localparam REG_STATUS   = 7'h04;
  localparam REG_SRC_ADDR = 7'h08;
  localparam REG_DST_ADDR = 7'h0C;
  localparam REG_LEN      = 7'h10;
  localparam REG_KEY0     = 7'h14;
  localparam REG_KEY1     = 7'h18;
  localparam REG_KEY2     = 7'h1C;
  localparam REG_KEY3     = 7'h20;
  localparam REG_IV0      = 7'h24;
  localparam REG_IV1      = 7'h28;
  localparam REG_IV2      = 7'h2C;
  localparam REG_IV3      = 7'h30;

  // ---- CPU-facing config registers ----
  reg [31:0]  src_addr_reg, dst_addr_reg, len_reg;
  reg [127:0] key_reg, iv_reg;
  reg         status_busy, status_done;
  reg         irq_pulse;
  reg [1:0]   ctrl_mode;
  reg         ctrl_encdec;

  assign irq = irq_pulse;

  assign s_awready = 1'b1;
  assign s_wready  = 1'b1;
  assign s_arready = 1'b1;

  wire [6:0] aw_offset = s_awaddr[6:0];
  wire [6:0] ar_offset = s_araddr[6:0];
  wire       do_write  = s_awvalid && s_wvalid;
  wire       do_start  = do_write && (aw_offset == REG_CTRL) && s_wdata[0] && !status_busy;

  // =====================================================================
  // Engine FSM: per-block read-burst -> aes_chain -> write-burst
  // =====================================================================
  localparam ST_IDLE     = 4'd0;
  localparam ST_RD_ADDR  = 4'd1;
  localparam ST_RD_DATA  = 4'd2;
  localparam ST_AES_GO   = 4'd3;
  localparam ST_AES_WAIT = 4'd4;
  localparam ST_WR_ADDR  = 4'd5;
  localparam ST_WR_DATA  = 4'd6;
  localparam ST_WR_RESP  = 4'd7;
  localparam ST_DONE     = 4'd8;

  reg [3:0]   state;
  reg [31:0]  cur_src, cur_dst;
  reg [31:0]  blocks_left;
  reg [1:0]   beat_cnt;
  reg [127:0] rd_block, wr_block;
  reg         chain_load_iv, chain_start;

  wire        chain_busy, chain_done;
  wire [127:0] chain_data_out;

  // Driven combinationally from wr_block/beat_cnt (not registered with a
  // lag) so that on the very cycle the last beat is accepted, m_wlast is
  // already 1 *while* m_wvalid is still 1 -- registering these off of
  // beat_cnt one cycle behind the m_wvalid/m_wready check (as in an
  // earlier version of this FSM) meant m_wlast only became 1 the cycle
  // *after* m_wvalid had already dropped back to 0, so dma_ram's write
  // FSM never actually saw wlast=1 during a valid wvalid cycle and its
  // w_state got stuck in W_BURST forever after the first burst -- the
  // same same-cycle stale-register class of bug as aes_chain.v's
  // mode/encdec issue.
  always @(*) begin
    m_wdata = wr_block[127:96];
    m_wstrb = 4'hF; // always a full 4-byte word
    m_wlast = (beat_cnt == 2'd3);
  end

  aes_chain u_chain (
      .clk(clk), .rst(rst),
      .load_iv(chain_load_iv), .iv_in(iv_reg),
      .start(chain_start), .encdec(ctrl_encdec), .mode(ctrl_mode),
      .key_in(key_reg), .data_in(rd_block),
      .busy(chain_busy), .done(chain_done), .data_out(chain_data_out), .iv_out()
  );

  always @(posedge clk) begin
    if (rst) begin
      state         <= ST_IDLE;
      status_busy   <= 1'b0;
      irq_pulse     <= 1'b0;
      chain_load_iv <= 1'b0;
      chain_start   <= 1'b0;
      m_awvalid <= 1'b0; m_wvalid <= 1'b0; m_bready <= 1'b0;
      m_arvalid <= 1'b0; m_rready <= 1'b0;
    end else begin
      irq_pulse     <= 1'b0;
      chain_load_iv <= 1'b0;
      chain_start   <= 1'b0;

      case (state)
        ST_IDLE: begin
          if (do_start) begin
            cur_src       <= src_addr_reg;
            cur_dst       <= dst_addr_reg;
            blocks_left   <= len_reg;
            status_busy   <= 1'b1;
            chain_load_iv <= 1'b1;
            state         <= ST_RD_ADDR;
          end
        end

        ST_RD_ADDR: begin
          m_arvalid <= 1'b1;
          m_araddr  <= cur_src;
          m_arlen   <= 8'd3; // 4 beats = 128 bits
          m_arsize  <= `AXI4_SIZE_4B;
          m_arburst <= `AXI4_BURST_INCR;
          if (m_arvalid && m_arready) begin
            m_arvalid <= 1'b0;
            m_rready  <= 1'b1;
            beat_cnt  <= 2'd0;
            state     <= ST_RD_DATA;
          end
        end

        ST_RD_DATA: begin
          if (m_rvalid && m_rready) begin
            rd_block <= {rd_block[95:0], m_rdata}; // beat0 ends up as the MSB word after 4 shifts
            if (m_rlast) begin
              m_rready    <= 1'b0;
              chain_start <= 1'b1;
              state       <= ST_AES_GO;
            end
          end
        end

        ST_AES_GO: state <= ST_AES_WAIT; // one cycle for chain_start's pulse to register

        ST_AES_WAIT: begin
          if (chain_done) begin
            wr_block <= chain_data_out;
            state    <= ST_WR_ADDR;
          end
        end

        ST_WR_ADDR: begin
          m_awvalid <= 1'b1;
          m_awaddr  <= cur_dst;
          m_awlen   <= 8'd3;
          m_awsize  <= `AXI4_SIZE_4B;
          m_awburst <= `AXI4_BURST_INCR;
          if (m_awvalid && m_awready) begin
            m_awvalid <= 1'b0;
            m_wvalid  <= 1'b1;
            beat_cnt  <= 2'd0;
            state     <= ST_WR_DATA;
          end
        end

        ST_WR_DATA: begin
          if (m_wvalid && m_wready) begin
            wr_block <= {wr_block[95:0], 32'h0};
            if (beat_cnt == 2'd3) begin
              m_wvalid <= 1'b0;
              m_bready <= 1'b1;
              state    <= ST_WR_RESP;
            end else begin
              beat_cnt <= beat_cnt + 2'd1;
            end
          end
        end

        ST_WR_RESP: begin
          if (m_bvalid) begin
            m_bready <= 1'b0;
            if (blocks_left == 32'd1) begin
              state <= ST_DONE;
            end else begin
              cur_src     <= cur_src + 32'd16;
              cur_dst     <= cur_dst + 32'd16;
              blocks_left <= blocks_left - 32'd1;
              state       <= ST_RD_ADDR;
            end
          end
        end

        ST_DONE: begin
          status_busy <= 1'b0;
          status_done <= 1'b1;
          irq_pulse   <= 1'b1;
          state       <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

  // =====================================================================
  // CPU-facing AXI4-Lite register interface
  // =====================================================================
  always @(posedge clk) begin
    if (rst) begin
      src_addr_reg <= 32'h0;
      dst_addr_reg <= 32'h0;
      len_reg      <= 32'h0;
      key_reg      <= 128'h0;
      iv_reg       <= 128'h0;
      status_done  <= 1'b0;
      ctrl_mode    <= 2'b0;
      ctrl_encdec  <= 1'b0;
    end else begin
      if (do_write && aw_offset == REG_STATUS && s_wdata[1]) status_done <= 1'b0;
      if (do_start) begin
        ctrl_encdec <= s_wdata[1];
        ctrl_mode   <= s_wdata[3:2];
      end

      if (do_write) begin
        case (aw_offset)
          REG_SRC_ADDR: src_addr_reg <= s_wdata;
          REG_DST_ADDR: dst_addr_reg <= s_wdata;
          REG_LEN:      len_reg      <= s_wdata;
          REG_KEY0:     key_reg[127:96] <= s_wdata;
          REG_KEY1:     key_reg[95:64]  <= s_wdata;
          REG_KEY2:     key_reg[63:32]  <= s_wdata;
          REG_KEY3:     key_reg[31:0]   <= s_wdata;
          REG_IV0:      iv_reg[127:96]  <= s_wdata;
          REG_IV1:      iv_reg[95:64]   <= s_wdata;
          REG_IV2:      iv_reg[63:32]   <= s_wdata;
          REG_IV3:      iv_reg[31:0]    <= s_wdata;
          default: ;
        endcase
        s_bresp  <= `AXI_RESP_OKAY;
        s_bvalid <= 1'b1;
      end else begin
        s_bvalid <= 1'b0;
      end

      if (s_arvalid) begin
        case (ar_offset)
          REG_CTRL:     s_rdata <= {28'b0, ctrl_mode, ctrl_encdec, 1'b0};
          REG_STATUS:   s_rdata <= {30'b0, status_done, status_busy};
          REG_SRC_ADDR: s_rdata <= src_addr_reg;
          REG_DST_ADDR: s_rdata <= dst_addr_reg;
          REG_LEN:      s_rdata <= len_reg;
          REG_IV0:      s_rdata <= iv_reg[127:96];
          REG_IV1:      s_rdata <= iv_reg[95:64];
          REG_IV2:      s_rdata <= iv_reg[63:32];
          REG_IV3:      s_rdata <= iv_reg[31:0];
          default:      s_rdata <= 32'b0; // KEY*: write-only
        endcase
        s_rresp  <= `AXI_RESP_OKAY;
        s_rvalid <= 1'b1;
      end else begin
        s_rvalid <= 1'b0;
      end
    end
  end
endmodule

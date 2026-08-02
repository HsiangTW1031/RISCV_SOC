// Test-only harness: dma_engine + dma_ram, so the full AXI4 burst master
// -> AES chain -> AXI4 burst write path can be validated end-to-end
// before soc_top wiring. Not a synthesizable deliverable.
module dma_engine_testtop (
    input  wire        clk,
    input  wire        rst,

    input  wire        s_awvalid, output wire s_awready, input wire [31:0] s_awaddr,
    input  wire        s_wvalid,  output wire s_wready,  input wire [31:0] s_wdata, input wire [3:0] s_wstrb,
    output wire         s_bvalid,  input wire  s_bready,  output wire [1:0] s_bresp,
    input  wire        s_arvalid, output wire s_arready, input wire [31:0] s_araddr,
    output wire         s_rvalid,  input wire  s_rready,  output wire [31:0] s_rdata, output wire [1:0] s_rresp,

    // test-only direct access into dma_ram, so the C++ testbench can
    // preload source data and inspect destination data without needing
    // its own AXI4 burst master
    input  wire        ram_awvalid, output wire ram_awready, input wire [31:0] ram_awaddr,
    input  wire [7:0]  ram_awlen, input wire [2:0] ram_awsize, input wire [1:0] ram_awburst,
    input  wire        ram_wvalid, output wire ram_wready, input wire [31:0] ram_wdata, input wire [3:0] ram_wstrb, input wire ram_wlast,
    output wire         ram_bvalid, input wire ram_bready, output wire [1:0] ram_bresp,
    input  wire        ram_arvalid, output wire ram_arready, input wire [31:0] ram_araddr,
    input  wire [7:0]  ram_arlen, input wire [2:0] ram_arsize, input wire [1:0] ram_arburst,
    output wire         ram_rvalid, input wire ram_rready, output wire [31:0] ram_rdata, output wire [1:0] ram_rresp, output wire ram_rlast,

    output wire         irq
);
  // simple 2:1 mux between the DMA engine's own burst master and the
  // test-only direct port -- test-only port only used while the engine is
  // idle (test preloads memory before triggering the engine, and reads
  // results back after it's done), so no real arbitration needed.
  wire        eng_awvalid, eng_awready; wire [31:0] eng_awaddr;
  wire [7:0]  eng_awlen; wire [2:0] eng_awsize; wire [1:0] eng_awburst;
  wire        eng_wvalid, eng_wready; wire [31:0] eng_wdata; wire [3:0] eng_wstrb; wire eng_wlast;
  wire        eng_bvalid, eng_bready; wire [1:0] eng_bresp;
  wire        eng_arvalid, eng_arready; wire [31:0] eng_araddr;
  wire [7:0]  eng_arlen; wire [2:0] eng_arsize; wire [1:0] eng_arburst;
  wire        eng_rvalid, eng_rready; wire [31:0] eng_rdata; wire [1:0] eng_rresp; wire eng_rlast;

  dma_engine u_engine (
      .clk(clk), .rst(rst),
      .s_awvalid(s_awvalid), .s_awready(s_awready), .s_awaddr(s_awaddr),
      .s_wvalid(s_wvalid),   .s_wready(s_wready),   .s_wdata(s_wdata), .s_wstrb(s_wstrb),
      .s_bvalid(s_bvalid),   .s_bready(s_bready),   .s_bresp(s_bresp),
      .s_arvalid(s_arvalid), .s_arready(s_arready), .s_araddr(s_araddr),
      .s_rvalid(s_rvalid),   .s_rready(s_rready),   .s_rdata(s_rdata), .s_rresp(s_rresp),

      .m_awvalid(eng_awvalid), .m_awready(eng_awready), .m_awaddr(eng_awaddr), .m_awlen(eng_awlen), .m_awsize(eng_awsize), .m_awburst(eng_awburst),
      .m_wvalid(eng_wvalid),   .m_wready(eng_wready),   .m_wdata(eng_wdata), .m_wstrb(eng_wstrb), .m_wlast(eng_wlast),
      .m_bvalid(eng_bvalid),   .m_bready(eng_bready),   .m_bresp(eng_bresp),
      .m_arvalid(eng_arvalid), .m_arready(eng_arready), .m_araddr(eng_araddr), .m_arlen(eng_arlen), .m_arsize(eng_arsize), .m_arburst(eng_arburst),
      .m_rvalid(eng_rvalid),   .m_rready(eng_rready),   .m_rdata(eng_rdata), .m_rresp(eng_rresp), .m_rlast(eng_rlast),

      .irq(irq)
  );

  // test port wins whenever it's actively requesting; otherwise the
  // engine's own port passes through -- adequate for a test that never
  // drives both at once
  // held for the whole burst, not just the address-phase handshake cycle
  // -- ram_arvalid alone drops as soon as AR is accepted, well before the
  // read *data* phase (multiple beats + RLAST) finishes, which would
  // de-route the mux mid-burst; ram_rready stays asserted by the
  // testbench for the whole data phase, so OR it in too.
  wire use_test_port_w = ram_awvalid || ram_wvalid;
  wire use_test_port_r = ram_arvalid || ram_rready;

  wire        ram_s_awvalid = use_test_port_w ? ram_awvalid : eng_awvalid;
  wire [31:0] ram_s_awaddr  = use_test_port_w ? ram_awaddr  : eng_awaddr;
  wire [7:0]  ram_s_awlen   = use_test_port_w ? ram_awlen   : eng_awlen;
  wire [2:0]  ram_s_awsize  = use_test_port_w ? ram_awsize  : eng_awsize;
  wire [1:0]  ram_s_awburst = use_test_port_w ? ram_awburst : eng_awburst;
  wire        ram_s_wvalid  = use_test_port_w ? ram_wvalid  : eng_wvalid;
  wire [31:0] ram_s_wdata   = use_test_port_w ? ram_wdata   : eng_wdata;
  wire [3:0]  ram_s_wstrb   = use_test_port_w ? ram_wstrb   : eng_wstrb;
  wire        ram_s_wlast   = use_test_port_w ? ram_wlast   : eng_wlast;
  wire        ram_s_bready  = use_test_port_w ? ram_bready  : eng_bready;

  wire        ram_s_arvalid = use_test_port_r ? ram_arvalid : eng_arvalid;
  wire [31:0] ram_s_araddr  = use_test_port_r ? ram_araddr  : eng_araddr;
  wire [7:0]  ram_s_arlen   = use_test_port_r ? ram_arlen   : eng_arlen;
  wire [2:0]  ram_s_arsize  = use_test_port_r ? ram_arsize  : eng_arsize;
  wire [1:0]  ram_s_arburst = use_test_port_r ? ram_arburst : eng_arburst;
  wire        ram_s_rready  = use_test_port_r ? ram_rready  : eng_rready;

  wire ram_s_awready, ram_s_wready, ram_s_bvalid; wire [1:0] ram_s_bresp;
  wire ram_s_arready, ram_s_rvalid; wire [31:0] ram_s_rdata; wire [1:0] ram_s_rresp; wire ram_s_rlast;

  assign ram_awready = use_test_port_w ? ram_s_awready : 1'b0;
  assign ram_wready   = use_test_port_w ? ram_s_wready  : 1'b0;
  assign ram_bvalid   = use_test_port_w ? ram_s_bvalid  : 1'b0;
  assign ram_bresp    = ram_s_bresp;
  assign eng_awready = use_test_port_w ? 1'b0 : ram_s_awready;
  assign eng_wready  = use_test_port_w ? 1'b0 : ram_s_wready;
  assign eng_bvalid  = use_test_port_w ? 1'b0 : ram_s_bvalid;
  assign eng_bresp   = ram_s_bresp;

  assign ram_arready = use_test_port_r ? ram_s_arready : 1'b0;
  assign ram_rvalid   = use_test_port_r ? ram_s_rvalid  : 1'b0;
  assign ram_rdata    = ram_s_rdata;
  assign ram_rresp    = ram_s_rresp;
  assign ram_rlast    = ram_s_rlast;
  assign eng_arready = use_test_port_r ? 1'b0 : ram_s_arready;
  assign eng_rvalid  = use_test_port_r ? 1'b0 : ram_s_rvalid;
  assign eng_rdata   = ram_s_rdata;
  assign eng_rresp   = ram_s_rresp;
  assign eng_rlast   = ram_s_rlast;

  dma_ram u_ram (
      .clk(clk), .rst(rst),
      .s_awvalid(ram_s_awvalid), .s_awready(ram_s_awready), .s_awaddr(ram_s_awaddr),
      .s_awlen(ram_s_awlen), .s_awsize(ram_s_awsize), .s_awburst(ram_s_awburst),
      .s_wvalid(ram_s_wvalid), .s_wready(ram_s_wready), .s_wdata(ram_s_wdata), .s_wstrb(ram_s_wstrb), .s_wlast(ram_s_wlast),
      .s_bvalid(ram_s_bvalid), .s_bready(ram_s_bready), .s_bresp(ram_s_bresp),
      .s_arvalid(ram_s_arvalid), .s_arready(ram_s_arready), .s_araddr(ram_s_araddr),
      .s_arlen(ram_s_arlen), .s_arsize(ram_s_arsize), .s_arburst(ram_s_arburst),
      .s_rvalid(ram_s_rvalid), .s_rready(ram_s_rready), .s_rdata(ram_s_rdata), .s_rresp(ram_s_rresp), .s_rlast(ram_s_rlast)
  );
endmodule

// AXI4 (full, burst-capable) conventions -- used ONLY by the Phase 6 DMA
// engine's private burst path (dma_engine.v <-> dma_ram.v), completely
// separate from the AXI4-Lite crossbar used everywhere else in this
// project. Deliberate scope cut, documented here and in dma_ram.v's
// header: this subset only supports INCR bursts (the common case for
// sequential DMA transfers) at a fixed AxSIZE of 4 bytes/beat (this
// project is entirely 32-bit-word-oriented throughout) -- FIXED and WRAP
// burst types, and narrow/unaligned transfers, are not implemented.
`define AXI4_LEN_WIDTH   8   // AxLEN: burst length - 1 (0 = 1 beat ... 255 = 256 beats)
`define AXI4_SIZE_WIDTH  3   // AxSIZE: bytes per beat = 2^AxSIZE
`define AXI4_BURST_WIDTH 2   // AxBURST: burst type encoding width

`define AXI4_SIZE_4B     3'b010  // 2^2 = 4 bytes/beat -- this project's only size
`define AXI4_BURST_INCR  2'b01   // the only burst type generated/accepted here

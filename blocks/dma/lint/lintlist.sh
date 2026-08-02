# dma_engine nests aes_chain (and its own dependents); dma_ram is a
# separate top (a peer memory, not nested inside dma_engine)
lint_target dma dma_engine dma_engine \
  -I"$ROOT/rtl/include" -I"$ROOT/blocks/aes/rtl" \
  "$ROOT/blocks/aes/rtl/aes_key_expand.v" "$ROOT/blocks/aes/rtl/aes_core.v" \
  "$ROOT/blocks/aes/rtl/aes_chain.v" "$ROOT/blocks/dma/rtl/dma_engine.v"

lint_target dma dma_ram dma_ram \
  -I"$ROOT/rtl/include" "$ROOT/blocks/dma/rtl/dma_ram.v"

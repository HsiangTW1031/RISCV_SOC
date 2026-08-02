run_target dma_ram "$ROOT/blocks/dma/dv" dma_ram sim obj_dir_ram \
  -I"$ROOT/rtl/include" "$ROOT/blocks/dma/rtl/dma_ram.v" dma_ram_sim_main.cpp

run_target dma_engine "$ROOT/blocks/dma/dv" dma_engine_testtop sim obj_dir_engine \
  -I"$ROOT/rtl/include" -I"$ROOT/blocks/aes/rtl" -I"$ROOT/blocks/dma/rtl" \
  "$ROOT/blocks/dma/rtl/dma_ram.v" "$ROOT/blocks/dma/rtl/dma_engine.v" "$ROOT/blocks/aes/rtl/aes_key_expand.v" \
  "$ROOT/blocks/aes/rtl/aes_core.v" "$ROOT/blocks/aes/rtl/aes_chain.v" \
  "$ROOT/blocks/dma/dv/dma_engine_testtop.v" dma_engine_sim_main.cpp

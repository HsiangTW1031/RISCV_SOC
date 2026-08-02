run_target aes_key_expand "$ROOT/blocks/aes/dv" aes_key_expand keyexp_sim obj_dir_keyexp \
  -I"$ROOT/blocks/aes/rtl" "$ROOT/blocks/aes/rtl/aes_key_expand.v" key_expand_sim_main.cpp

run_target aes_core "$ROOT/blocks/aes/dv" aes_core core_sim obj_dir_core \
  -I"$ROOT/blocks/aes/rtl" "$ROOT/blocks/aes/rtl/aes_key_expand.v" "$ROOT/blocks/aes/rtl/aes_core.v" core_sim_main.cpp

run_target aes_chain "$ROOT/blocks/aes/dv" aes_chain chain_sim obj_dir_chain \
  -I"$ROOT/blocks/aes/rtl" "$ROOT/blocks/aes/rtl/aes_key_expand.v" "$ROOT/blocks/aes/rtl/aes_core.v" \
  "$ROOT/blocks/aes/rtl/aes_chain.v" chain_sim_main.cpp

run_target aes_axi_wrapper "$ROOT/blocks/aes/dv" aes sim obj_dir \
  -I"$ROOT/rtl/include" -I"$ROOT/blocks/aes/rtl" "$ROOT/blocks/aes/rtl/aes_key_expand.v" \
  "$ROOT/blocks/aes/rtl/aes_core.v" "$ROOT/blocks/aes/rtl/aes_chain.v" "$ROOT/blocks/aes/rtl/aes.v" sim_main.cpp

run_target aes_diff "$ROOT/blocks/aes/dv" aes diff_sim obj_dir_diff \
  -I"$ROOT/rtl/include" -I"$ROOT/blocks/aes/rtl" "$ROOT/blocks/aes/rtl/aes_key_expand.v" \
  "$ROOT/blocks/aes/rtl/aes_core.v" "$ROOT/blocks/aes/rtl/aes_chain.v" "$ROOT/blocks/aes/rtl/aes.v" diff_sim_main.cpp

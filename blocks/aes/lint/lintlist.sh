# full nested hierarchy (aes -> aes_chain -> aes_core -> aes_key_expand)
lint_target aes aes aes \
  -I"$ROOT/rtl/include" -I"$ROOT/blocks/aes/rtl" \
  "$ROOT/blocks/aes/rtl/aes_key_expand.v" "$ROOT/blocks/aes/rtl/aes_core.v" \
  "$ROOT/blocks/aes/rtl/aes_chain.v" "$ROOT/blocks/aes/rtl/aes.v"

#!/usr/bin/env python3
# Pads a flat binary to a multiple of 4 bytes with zero bytes. Needed
# because COMPRESSED_ISA=1 (RV32IMC) can emit 16-bit instructions, so a
# linked image's raw size isn't guaranteed to already be word-aligned, and
# makehex.py requires it to be.
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()

pad = (-len(data)) % 4
if pad:
    with open(path, "ab") as f:
        f.write(b"\x00" * pad)

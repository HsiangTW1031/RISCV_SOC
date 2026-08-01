TOOLCHAIN_PREFIX ?= riscv-none-elf-
CC      = $(TOOLCHAIN_PREFIX)gcc
OBJCOPY = $(TOOLCHAIN_PREFIX)objcopy

# RV32IMC matches soc_top.v's picorv32_axi instantiation (ENABLE_MUL=1,
# ENABLE_DIV=1, COMPRESSED_ISA=1).
CFLAGS  = -march=rv32imc -mabi=ilp32 -Os -ffreestanding -nostdlib -Wall -Wextra
LDFLAGS = -T linker.ld -nostdlib -Wl,--build-id=none -Wl,-Map=firmware.map

NWORDS = 16384   # 64KB boot ROM / 4 bytes per word — must match boot_rom.v

all: firmware.hex

firmware.elf: start.o main.o linker.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o firmware.elf start.o main.o

start.o: start.S custom_ops.S
	$(CC) $(CFLAGS) -c -o start.o start.S

main.o: main.c
	$(CC) $(CFLAGS) -c -o main.o main.c

# Only the ROM-resident sections: .text/.rodata/.data (.data's LMA is in ROM
# per linker.ld's "AT> ROM"). Deliberately excludes .bss and, more
# importantly, avoids objcopy spanning the huge address gap between ROM
# (0x0) and RAM (0x1000_0000) that a plain `objcopy -O binary` would try to
# span if any RAM-resident section were included.
firmware.bin: firmware.elf
	$(OBJCOPY) -O binary --only-section=.text --only-section=.rodata --only-section=.data firmware.elf firmware.bin
	python3 pad_to_word.py firmware.bin

firmware.hex: firmware.bin makehex.py
	python3 makehex.py firmware.bin $(NWORDS) > firmware.hex

clean:
	rm -f *.o firmware.elf firmware.bin firmware.hex firmware.map

.PHONY: all clean

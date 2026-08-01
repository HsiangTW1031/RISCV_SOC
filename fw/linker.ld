/* Matches rtl/include/addr_map.vh: ROM at 0x0 (64KB), RAM at 0x1000_0000
 * (128KB). NOTE: there is no startup code copying .data from ROM to RAM
 * (see fw/start.S) — fine while firmware has no initialized writable
 * globals, but the first firmware that adds any must add that copy loop
 * before relying on .data.
 */
MEMORY {
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
    RAM (rwx) : ORIGIN = 0x10000000, LENGTH = 128K
}

SECTIONS {
    .text : {
        *(.text.start)
        *(.text*)
    } > ROM

    .rodata : {
        *(.rodata*)
    } > ROM

    .data : {
        *(.data*)
    } > RAM AT> ROM

    .bss : {
        *(.bss*)
        *(COMMON)
    } > RAM

    /DISCARD/ : { *(.comment) *(.eh_frame*) *(.riscv.attributes) }
}

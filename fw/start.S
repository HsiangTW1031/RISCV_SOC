.section .text.start
.global _start
_start:
    li sp, 0x10020000   /* top of the 128KB RAM at 0x1000_0000 (STACKADDR) */
    call main
1:
    j 1b

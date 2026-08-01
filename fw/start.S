#include "custom_ops.S"

.section .text.start

// PROGADDR_RESET = 0x0, PROGADDR_IRQ = 0x10 (soc_top.v defaults) — reset_vec
// must fit in under 16 bytes so it doesn't collide with irq_vec.
.global _start
_start:
reset_vec:
    picorv32_maskirq_insn(zero, zero)   /* mask=0: nothing masked (reset default anyway; explicit for clarity) */
    j reset

.balign 16
irq_vec:
    /* Save every caller-saved GPR (ra, t0-t6, a0-a7) plus q0 (return PC) —
     * the interrupt can land anywhere, so anything the interrupted code
     * had live in a caller-saved register must come back untouched.
     * Callee-saved registers (s0-s11, sp) are the irq_handler C function's
     * own responsibility, same as any normal call.
     */
    addi sp, sp, -18*4
    sw   ra,  0*4(sp)
    sw   t0,  1*4(sp)
    sw   t1,  2*4(sp)
    sw   t2,  3*4(sp)
    sw   t3,  4*4(sp)
    sw   t4,  5*4(sp)
    sw   t5,  6*4(sp)
    sw   t6,  7*4(sp)
    sw   a0,  8*4(sp)
    sw   a1,  9*4(sp)
    sw   a2, 10*4(sp)
    sw   a3, 11*4(sp)
    sw   a4, 12*4(sp)
    sw   a5, 13*4(sp)
    sw   a6, 14*4(sp)
    sw   a7, 15*4(sp)

    /* Disable all further interrupts for the duration of this handler.
     * PicoRV32 does NOT do this automatically on IRQ entry — without it, a
     * still-high level-sensitive irq input (ours stays asserted until the
     * AXI write that clears it completes, a few cycles into the C
     * handler) causes the same logical event to be serviced more than
     * once, since the core keeps re-checking for pending irqs the whole
     * time. maskirq/mask-restore around the handler body is the standard
     * fix for that.
     */
    li   t1, -1
    picorv32_maskirq_insn(t0, t1)
    sw   t0, 17*4(sp)          /* stash the previous mask, restored at exit */

    picorv32_getq_insn(a0, q0)
    sw   a0, 16*4(sp)          /* stash return PC */
    picorv32_getq_insn(a0, q1)  /* a0 = irq bitmask -> arg0 of irq_handler */

    call irq_handler

    lw   a0, 16*4(sp)
    picorv32_setq_insn(q0, a0)  /* restore return PC into q0 for retirq */

    lw   t0, 17*4(sp)
    picorv32_maskirq_insn(zero, t0)  /* restore the previous mask */

    lw   ra,  0*4(sp)
    lw   t0,  1*4(sp)
    lw   t1,  2*4(sp)
    lw   t2,  3*4(sp)
    lw   t3,  4*4(sp)
    lw   t4,  5*4(sp)
    lw   t5,  6*4(sp)
    lw   t6,  7*4(sp)
    lw   a0,  8*4(sp)
    lw   a1,  9*4(sp)
    lw   a2, 10*4(sp)
    lw   a3, 11*4(sp)
    lw   a4, 12*4(sp)
    lw   a5, 13*4(sp)
    lw   a6, 14*4(sp)
    lw   a7, 15*4(sp)
    addi sp, sp, 18*4

    picorv32_retirq_insn()

reset:
    li sp, 0x10020000   /* top of the 128KB RAM at 0x1000_0000 (STACKADDR) */
    call main
1:
    j 1b

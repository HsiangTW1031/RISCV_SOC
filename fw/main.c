#define UART_TXDATA (*(volatile unsigned int *)0x40002000)
#define UART_STATUS (*(volatile unsigned int *)0x40002004)

#define TIMER_CTRL   (*(volatile unsigned int *)0x40000000)
#define TIMER_RELOAD (*(volatile unsigned int *)0x40000004)
#define TIMER_STATUS (*(volatile unsigned int *)0x4000000C)

#define WDT_CTRL    (*(volatile unsigned int *)0x40001000)
#define WDT_TIMEOUT (*(volatile unsigned int *)0x40001004)
#define WDT_KICK    (*(volatile unsigned int *)0x40001008)

#define TIMER_PERIOD 1000u    /* core clock cycles per timer tick */
#define WDT_TIMEOUT_CYCLES 5000u  /* 5x the timer period: kicking on every
                                     tick leaves a wide safety margin */
#define TARGET_TIMER_IRQS 5u

static void uart_putc(char c) {
    while (UART_STATUS & 1) {
        /* busy: no FIFO yet (Phase 1), so wait for the previous byte */
    }
    UART_TXDATA = (unsigned int)(unsigned char)c;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

static void uart_put_udec(unsigned int v) {
    char buf[10];
    int i = 0;
    if (v == 0) {
        uart_putc('0');
        return;
    }
    while (v > 0) {
        buf[i++] = (char)('0' + (v % 10));
        v /= 10;
    }
    while (i > 0) uart_putc(buf[--i]);
}

static volatile unsigned int timer_irq_count = 0;
static volatile unsigned int wdt_warning_count = 0;

/* Called from start.S's irq_vec. `irqs` is PicoRV32's irq bitmask
 * (bit3 = Timer EXPIRED, bit4 = Watchdog WARNING — see soc_top.v).
 */
void irq_handler(unsigned int irqs) {
    if (irqs & (1u << 3)) {
        TIMER_STATUS = 1;      /* write-1-to-clear EXPIRED */
        timer_irq_count++;
        WDT_KICK = 1;          /* feed the watchdog on every timer tick */

        /* Stop the source once we've counted enough, from inside the ISR
         * itself. Now that irq is a clean one-cycle pulse (see timer.v),
         * this isn't covering a race — main()'s busy-wait would already
         * land on exactly the right count — but disabling as soon as the
         * target is reached is still good practice: it saves needless
         * interrupts once the demo is done, and makes the "why does the
         * timer stop" story explicit.
         */
        if (timer_irq_count >= TARGET_TIMER_IRQS)
            TIMER_CTRL = 0;
    }
    if (irqs & (1u << 4)) {
        /* Shouldn't happen given the kick cadence above, but handle it
         * gracefully rather than leaving the bit set forever.
         */
        wdt_warning_count++;
    }
}

int main(void) {
    uart_puts("Hello World\n");

    TIMER_RELOAD = TIMER_PERIOD;
    TIMER_CTRL = 1;   /* enable: also (re)loads COUNT from RELOAD */

    WDT_TIMEOUT = WDT_TIMEOUT_CYCLES;
    WDT_CTRL = 1;     /* enable: also (re)loads the watchdog counter */

    while (timer_irq_count < TARGET_TIMER_IRQS) {
        /* nothing to do — everything happens in irq_handler() */
    }

    uart_puts("Timer IRQs: ");
    uart_put_udec(timer_irq_count);
    uart_puts("\n");

    while (1) {
        /* keep kicking forever via the timer ISR so the watchdog never
         * fires after we're done reporting */
    }
    return 0;
}

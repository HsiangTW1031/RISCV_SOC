#define UART_TXDATA (*(volatile unsigned int *)0x40002000)
#define UART_STATUS (*(volatile unsigned int *)0x40002004)

static void uart_putc(char c) {
    while (UART_STATUS & 1) {
        /* busy: no FIFO yet (Phase 1), so wait for the previous byte */
    }
    UART_TXDATA = (unsigned int)(unsigned char)c;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

int main(void) {
    uart_puts("Hello World\n");
    while (1) {
        /* nothing else to do yet — Phase 1 goal is just this message */
    }
    return 0;
}

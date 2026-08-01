// Shared AXI4-Lite address map for RISCV_SOC.
// Included by axi_lite_xbar.v (decode) and any firmware-side header generator.
// Keep this file as the single source of truth for base addresses / sizes —
// see docs/phase_plan.md "Memory map".

// ---- region select: addr[31:28] ----
`define ADDR_REGION_ROM   4'h0   // 0x0000_0000, 64KB
`define ADDR_REGION_RAM   4'h1   // 0x1000_0000, 128KB
`define ADDR_REGION_PERIPH 4'h4  // 0x4000_0000, 4KB windows, sub-decoded below

// ---- peripheral sub-select within the 0x4000_xxxx region: addr[15:12] ----
`define ADDR_PERIPH_TIMER 4'h0   // 0x4000_0000
`define ADDR_PERIPH_WDT   4'h1   // 0x4000_1000
`define ADDR_PERIPH_UART  4'h2   // 0x4000_2000
`define ADDR_PERIPH_I2C   4'h3   // 0x4000_3000
`define ADDR_PERIPH_SPI   4'h4   // 0x4000_4000
`define ADDR_PERIPH_AES   4'h5   // 0x4000_5000

// ---- slave index numbering, used by axi_lite_xbar's internal mux ----
`define SLAVE_ROM   0
`define SLAVE_RAM   1
`define SLAVE_TIMER 2
`define SLAVE_WDT   3
`define SLAVE_UART  4
`define SLAVE_I2C   5
`define SLAVE_SPI   6
`define SLAVE_AES   7
`define SLAVE_ERR   8   // default/error slave: unmapped addresses -> SLVERR
`define NUM_SLAVES  9

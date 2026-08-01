# Memory Map

Single source of truth 是 `rtl/include/addr_map.vh`——這份文件只是把它翻成人看得懂的表格,實作以該檔案為準。

## 1. 頂層區域（`addr[31:28]`）

| Region | Base | Size | 說明 |
|---|---|---|---|
| ROM | `0x0000_0000` | 64KB | `boot_rom`,`$readmemh` 載入 firmware |
| RAM | `0x1000_0000` | 128KB | `sram`,一般讀寫資料/stack |
| PERIPH | `0x4000_0000` | 每個周邊 4KB window | 下一層再依 `addr[15:12]` 細分,見下表 |
| （其他) | - | - | 未映射,crossbar 直接回 SLVERR |

## 2. 周邊子位址（`0x4000_xxxx`,依 `addr[15:12]`）

| Offset | Base Address | 周邊 | Crossbar Slave Index |
|---|---|---|---|
| `0x0` | `0x4000_0000` | Timer | `SLAVE_TIMER` = 2 |
| `0x1` | `0x4000_1000` | Watchdog | `SLAVE_WDT` = 3 |
| `0x2` | `0x4000_2000` | UART | `SLAVE_UART` = 4 |
| `0x3` | `0x4000_3000` | I2C | `SLAVE_I2C` = 5 |
| `0x4` | `0x4000_4000` | SPI | `SLAVE_SPI` = 6 |
| `0x5` | `0x4000_5000` | AES | `SLAVE_AES` = 7 |
| `0x6` | `0x4000_6000` | DMA 控制埠 | `SLAVE_DMA` = 8 |
| `0x7`-`0xF` | `0x4000_7000`-`0x4000_F000` | （未使用) | `SLAVE_ERR` = 9,SLVERR |

`SLAVE_ROM`=0、`SLAVE_RAM`=1 是頂層區域直接對應,不透過周邊子位址這層解碼。

每個周邊 base address 底下的實際暫存器 offset（CTRL/STATUS/DATA...)見各自的 `docs/specs/*.md`。

## 3. DMA 的第二塊記憶體空間

DMA 的 AXI4 burst master 走的是**完全獨立於上面這張表**的位址空間——`dma_ram.v` 是一塊 8KB（2048 words)、只有 DMA engine 自己能存取的私有記憶體,不接這個 crossbar,所以它的位址（`dma_engine` 暫存器裡的 `SRC_ADDR`/`DST_ADDR`,byte address,範圍 `0x0000`-`0x1FFF`)跟上面主要的 AXI4-Lite 位址空間是兩個獨立的命名空間,不會互相碰撞,但也不能拿主位址空間的位址去存取它。細節與取捨理由見 `docs/specs/dma.md` 第 1 節。

## 4. IRQ bit map

見 `docs/architecture.md` 第 4 節（單一 `irq` bus,bit 0-2 是 PicoRV32 內建 trap,bit 3-8 依序是 Timer/WDT/I2C/SPI/AES/DMA)。

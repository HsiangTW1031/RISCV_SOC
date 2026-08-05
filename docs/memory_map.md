# Memory Map

Single source of truth 是 `rtl/include/addr_map.vh`——這份文件只是把它翻成人看得懂的表格,實作以該檔案為準。

## 1. 頂層區域（`addr[31:28]`）

| Region | Base | Size | 說明 |
|---|---|---|---|
| ROM | `0x0000_0000` | 64KB | `boot_rom`,`$readmemh` 載入 firmware |
| RAM | `0x1000_0000` | 128KB | `sram`,一般讀寫資料/stack |
| PERIPH | `0x4000_0000` | 每個周邊 4KB window | 下一層再依 `addr[15:12]` 細分,見下表 |
| （其他) | - | - | 未映射,crossbar 直接回 `DECERR`(v2.2.0 前是 `SLVERR`,見 §2 說明) |

## 2. 周邊子位址（`0x4000_xxxx`,依 `addr[15:12]`）

**這張表只列真正有自己 RTL 模組的周邊**——`decode_addr()` 對沒列在這裡的 offset 一律回 `SLAVE_ERR`(crossbar 自己回 `DECERR`,不是某個「周邊」的行為,不該跟下面這幾個真正的硬體模組放在同一張表裡,詳見下方 §2.1)。

| Offset | Base Address | 周邊 | Crossbar Slave Index |
|---|---|---|---|
| `0x0` | `0x4000_0000` | Timer | `SLAVE_TIMER` = 2 |
| `0x1` | `0x4000_1000` | Watchdog | `SLAVE_WDT` = 3 |
| `0x2` | `0x4000_2000` | UART | `SLAVE_UART` = 4 |
| `0x3` | `0x4000_3000` | I2C | `SLAVE_I2C` = 5 |
| `0x4` | `0x4000_4000` | SPI | `SLAVE_SPI` = 6 |
| `0x5` | `0x4000_5000` | AES | `SLAVE_AES` = 7 |
| `0x6` | `0x4000_6000` | DMA 控制埠 | `SLAVE_DMA` = 8 |

`SLAVE_ROM`=0、`SLAVE_RAM`=1 是頂層區域直接對應,不透過周邊子位址這層解碼。

每個周邊 base address 底下的實際暫存器 offset（CTRL/STATUS/DATA...)見各自的 `docs/specs/*.md`。

### 2.1 `0x7`:crossbar 自己的診斷 CSR window(v2.2.0,不是周邊)

`0x4000_7000` 這個 offset 由 `axi_lite_xbar` 自己直接回應,**不路由到任何 slave 模組**——跟真正的周邊是完全不同層級的東西,故意單獨列出來,不跟上面那張表混在一起。

| Offset | Address | 名稱 | 說明 |
|---|---|---|---|
| `0x0` | `0x4000_7000` | `LAST_DECERR_WADDR` | 唯讀,最近一次寫入 miss(decode 失敗)的位址 |
| `0x4` | `0x4000_7004` | `LAST_DECERR_RADDR` | 唯讀,最近一次讀取 miss 的位址 |
| 其他 | `0x4000_7008`-`0x4000_7FFF` | (alias) | 這個 4KB window 只解碼 `addr[2]`,其餘位元忽略——任何其他 offset 都會 alias 回上面兩個暫存器其中一個,不是額外定義的暫存器 |

- **寫入這個 window 一律 `SLVERR`**(不是 `DECERR`)——這個位址是真的、有效的(crossbar 自己的位址),只是唯讀,寫入被拒絕,跟 `boot_rom` 拒絕寫入是同一套邏輯,不是「找不到 slave」。
- 每次真的發生 decode miss(讀或寫都算),crossbar 會把觸發的位址鎖存進對應的暫存器,同時拉一個 cycle 的 `decerr_irq`(接進 `soc_top.v` 的 `irq_bus` bit 9,見 `docs/architecture.md` 第 4 節)。
- **為什麼需要這個**:PicoRV32 在這個專案裡完全不檢查 `BRESP`/`RRESP`(見 `docs/architecture.md` 已知限制),所以匯流排上真的發生 `DECERR` 也不會被 CPU 自己發現——這個 CSR + 中斷,是讓 decode miss 這件事對韌體變成「可觀察」的唯一路徑,不用一直 polling。細節見 `axi_lite_xbar.v` 的 module header 註解。

### 2.2 為什麼從 `SLVERR` 改成 `DECERR`(v2.2.0)

嚴格照 AMBA/AXI4 規範,四種 response code 的定義是:`OKAY`(成功)、`EXOKAY`(exclusive access 成功)、`SLVERR`(位址有找到對應的 slave,但那個 slave 自己回報錯誤,例如寫入唯讀暫存器)、`DECERR`(interconnect 自己找不到任何 slave)。這個專案從 Phase 1 開始,「crossbar 找不到 slave」這個情況一律回 `SLVERR`,沒有正確區分這兩種語意不同的錯誤——`DECERR` 從沒被真正用過。v2.2.0 修正了這個落差:crossbar 自己的 decode-miss 路徑改回真正的 `DECERR`,而任何「位址有效、但操作本身不合法」的情況(例如上面 §2.1 寫入 CSR window,或 `boot_rom` 拒絕寫入)繼續用 `SLVERR`,兩者不再混用。實務上影響不大(PicoRV32 完全不檢查 response code,這個專案裡也沒有任何周邊自己會回真正的 `SLVERR`),但符合規範對之後接真正的 AXI verification IP、或換一顆真的會檢查 response 的 CPU 都更安全。

## 3. DMA 的第二塊記憶體空間

DMA 的 AXI4 burst master 走的是**完全獨立於上面這張表**的位址空間——`dma_ram.v` 是一塊 8KB（2048 words)、只有 DMA engine 自己能存取的私有記憶體,不接這個 crossbar,所以它的位址（`dma_engine` 暫存器裡的 `SRC_ADDR`/`DST_ADDR`,byte address,範圍 `0x0000`-`0x1FFF`)跟上面主要的 AXI4-Lite 位址空間是兩個獨立的命名空間,不會互相碰撞,但也不能拿主位址空間的位址去存取它。細節與取捨理由見 `docs/specs/dma.md` 第 1 節。

## 4. IRQ bit map

見 `docs/architecture.md` 第 4 節（單一 `irq` bus,bit 0-2 是 PicoRV32 內建 trap,bit 3-8 依序是 Timer/WDT/I2C/SPI/AES/DMA)。

# Performance

所有數字都是實際跑出來的（合成/STA 或模擬量測),不是估算。方法論見各節。

## 1. 整體 SoC 的 STA 結果與 Fmax

`blocks/soc_top/syn/synth.ys` + `blocks/soc_top/sta/sta.tcl`,Nangate45 開放製程庫。

三塊純記憶體陣列（`boot_rom` 64KB、`sram` 128KB、`dma_ram` 8KB)換成 blackbox stub（`blocks/soc_top/syn/mem_blackboxes.v`)——真實 ASIC flow 裡這些會是硬 IP SRAM macro,不是真的拿 flip-flop 湊出來的,讓 Yosys 把一個 32K-word 的陣列展開成百萬顆 flip-flop 既不真實也慢到不划算。除了這三塊,**PicoRV32、手刻 crossbar、每個周邊的控制/資料路徑、AES core + CBC/CTR chaining、DMA engine 全部都是真的合成**——這是為什麼下面這個 Fmax 數字反映的是真正的邏輯關鍵路徑,不是被記憶體模型撐大的假象。

- **Chip area**（Nangate45 單位):130337.1,其中 sequential elements 佔 36.5%(47566.9)
- **Cell count**:79128 個 standard cell instance
- **關鍵路徑**:2.0ns 時脈假設下 WNS = -9.02ns,實際關鍵路徑延遲 **10.966ns**
- **關鍵路徑位置**:`u_aes/u_chain/u_core/u_key_expand`——AES 的 key expansion 組合邏輯,跟 Phase 4 單獨合成 `aes_core`(見 `docs/aes_report.md`,10.153ns、Fmax≈98.5MHz)幾乎是同一個瓶頸,只是被放進完整 SoC 後的 fanout/context 讓它慢了一點點——這個一致性本身就是交叉驗證,說明兩次合成量到的是同一個真實瓶頸,不是雜訊。

**Fmax ≈ 1 / 10.966ns ≈ 91.2 MHz**

## 2. AES 加密吞吐量

`aes_core` 的 iterative datapath 是 21 cycles/block（10 cycles key expansion + 1 initial AddRoundKey + 9 middle rounds + 1 final round,見 `docs/specs/aes.md`),128-bit = 16 bytes/block。

在整體 SoC 的 Fmax(91.2 MHz,cycle time ≈ 10.966ns)下:

- 每個 block:21 × 10.966ns ≈ **230.3ns**
- 吞吐量:16 bytes / 230.3ns ≈ **69.5 MB/s**

這是純 AES core 本身(CPU 逐 word 寫暫存器驅動)的數字,不含 DMA 的 burst overhead——DMA 版本見下一節。

## 3. DMA 吞吐量(含 burst overhead)

在 `blocks/dma/dv/dma_engine_sim_main.cpp` 裡直接量測:每次 `run_dma()` 呼叫,從 CTRL.START 寫入到觀察到 STATUS.DONE 為止,實際經過幾個 cycle(透過對 `tick_half` 呼叫次數計數,精確到 cycle,不是估計)。CBC encrypt/CTR/CBC decrypt 三組操作,每組 4 個 block,量到的結果一致:

- **156 cycles / 4 blocks = 39.0 cycles/block**(平均,含 burst 讀 4 拍 + AES 21 cycles + burst 寫 4 拍 + 狀態機切換 overhead + 軟體 polling STATUS 暫存器本身的 bus cycle)

在 Fmax 下:

- 每個 block:39 × 10.966ns ≈ **427.7ns**
- 吞吐量:16 bytes / 427.7ns ≈ **37.4 MB/s**

比純 AES core 慢,原因很直接:每個 block 多花了 8 拍 burst（讀 4 + 寫 4)加上 FSM 狀態切換的固定 overhead,換來的是**這整段時間 CPU 完全不用碰任何一個 word**——這正是 DMA 存在的意義,用吞吐量換 CPU 週期。

## 4. 中斷延遲(實測)

方法:直接從 `blocks/soc_top/dv/wave.vcd`(已有的完整波形,`--trace` 深度 99)量測 `soc_top.timer_irq` 訊號拉起,到 PicoRV32 內部 `irq_active` 暫存器(真正進入 ISR 的那一拍)拉起之間的 cycle 數,橫跨整個 soc_top regression 裡 5 次真實觸發的 Timer 中斷全部量過,不是只看一次:

| 事件 # | 延遲(cycles) |
|---|---|
| 1 | 9 |
| 2 | 14 |
| 3 | 6 |
| 4 | 11 |
| 5 | 3 |

**Min 3、Max 14、平均 8.6 cycles。**

這個範圍不是量測誤差——PicoRV32 必須先讓「當下正在執行的指令」完成才能進 IRQ,不同指令的剩餘週期數本來就不同(單週期指令 vs. 分支/多週期指令),所以延遲本來就會隨當下執行到哪條指令而變動,這是這顆核心 IRQ 機制的真實特性,不是不確定性雜訊。

## 5. 典型迴圈週期數

`blocks/soc_top/dv/sim_main.cpp` 的完整 regression(reset → boot firmware → 5 次真實 Timer 中斷,每次間隔 firmware 設定的 `TIMER_PERIOD=1000` cycles → 把 "Hello World\nTimer IRQs: 5\n" 全部經由 bit-banged UART 送完為止),總共:

**8907 cycles**

拆解:
- 5 × `TIMER_PERIOD`(1000 cycles)= 5000 cycles 是韌體自己設定的計時器間隔,佔了大頭
- 5 次中斷各自的 ISR 進入延遲(見上一節,平均 8.6 cycles)
- 其餘 ~3800 cycles 是開機時的指令執行 + 26 個字元透過 UART(`CLKS_PER_BIT=4`,測試環境刻意調快的 bit 時間,不代表真實 baud rate)序列傳輸所需的時間——UART 是 bit-banged、逐 bit 送出,天生比其他匯流排慢很多,這也是為什麼它在整個時序裡佔比最大。

## 6. 方法論註記

- STA 的 SDC 假設所有輸入/輸出的 I/O delay 是 0(見 `blocks/soc_top/constraints/soc_top.sdc`)——這個專案裡每個模組的 AXI 訊號在邊界都已經是暫存器輸出,所以量到的關鍵路徑是這個 SoC 真正的內部邏輯路徑,不是任意的 I/O budget 假設。
- 中斷延遲跟 DMA cycle count 都是從**真正跑起來的模擬**直接量測(VCD 波形分析、C++ testbench 裡的 cycle counter),不是從 RTL 推算或假設。

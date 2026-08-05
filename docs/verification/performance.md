# Performance

所有數字都是實際跑出來的（合成/STA 或模擬量測),不是估算。方法論見各節。

## 1. 整體 SoC 的 STA 結果與 Fmax

`blocks/soc_top/syn/synth.ys` + `blocks/soc_top/sta/sta.tcl`,Nangate45 開放製程庫。

三塊純記憶體陣列（`boot_rom` 64KB、`sram` 128KB、`dma_ram` 8KB)換成 blackbox stub（`blocks/soc_top/syn/mem_blackboxes.v`)——真實 ASIC flow 裡這些會是硬 IP SRAM macro,不是真的拿 flip-flop 湊出來的,讓 Yosys 把一個 32K-word 的陣列展開成百萬顆 flip-flop 既不真實也慢到不划算。除了這三塊,**PicoRV32、手刻 crossbar、每個周邊的控制/資料路徑、AES core + CBC/CTR chaining、DMA engine 全部都是真的合成**——這是為什麼下面這個 Fmax 數字反映的是真正的邏輯關鍵路徑,不是被記憶體模型撐大的假象。

- **Chip area**（Nangate45 單位):136510.1,其中 sequential elements 佔 35.14%(47968.0)——比 v2.1.0 gate-sizing 完成時(135530.2)多了 0.7%,是 v2.2.0 新增 `axi_lite_xbar` 診斷 CSR(兩個 32-bit 唯讀暫存器 + `decerr_irq` 相關邏輯)增加的真實邏輯,不是異常;比 active-low reset retrofit 剛完成時(129373.6)累計多了 5.5%,原因見下面的 sizing 說明
- **Cell count**:85893 個 standard cell instance(flatten 後統計;比 retrofit 剛完成時的 78446 多,同樣是新增的 buffer/放大後 cell)
- **關鍵路徑**:2.0ns 時脈假設下 WNS = -0.92ns,實際關鍵路徑延遲 **2.881ns**
- **關鍵路徑位置**:`u_aes/u_chain` 內部(AES CBC/CTR chaining 邏輯)

**Fmax ≈ 1 / 2.881ns ≈ 347.1 MHz**

**這個數字經過兩個階段才到這裡,完整記錄如下**:

1. **active-low reset retrofit 剛完成時的規律**(已在上一版記錄過,細節見 `docs/project_retrospective.md`):retrofit 前關鍵路徑一直是 `u_aes/u_chain/u_core/u_key_expand`(AES key expansion,10.966ns、Fmax≈91.2MHz)。Retrofit 只把 reset 訊號的命名和極性做了鏡像等價的轉換,沒有動到 PicoRV32 任何一行程式碼,但重新合成後關鍵路徑整個換位置換到 PicoRV32 內部,新的瓶頸比原本的 AES 瓶頸還慢(14.821ns,Fmax≈67.5MHz)。
2. **根因追查後找到的真正原因**:`blocks/soc_top/syn/synth.ys` 原本的 `abc -liberty $NANGATE45_LIB` 呼叫**從來沒有帶 `-constr`**——查證 Yosys 的 `abc` pass 說明才發現,abc 內建的預設 script 只有在給了 `-constr`(driving cell/load 假設)之後,才會執行 `buffer`/`upsize`/`dnsize` 這幾個真正做 gate sizing 的 pass;沒有 `-constr` 的話,不管加不加 `-D`(delay target)都只做純面積導向的技術對應,完全不會針對任何一條路徑做尺寸調整。也就是說:從專案一開始,這個 SoC 的合成流程就從未真正做過 timing-driven sizing,retrofit 只是把這個一直存在的盲點暴露出來而已,不是 retrofit 本身造成的新缺陷。
   - **先試過、被否決的方向**:把 hierarchy 攤平(`synth -top soc_top -flatten`)讓 abc 用單一全域網表跑,結果是反效果(關鍵路徑 14.821ns→38.364ns)——abc 的 heuristic 在單一 ~127K cell 的巨大平面網表上表現反而比按 submodule 分開跑更差,所以維持現有的非攤平 hierarchy 是刻意的選擇,不是漏做。
   - **實際生效的做法**:保留 per-module hierarchy,新增 `blocks/soc_top/syn/constr.txt`(`set_driving_cell BUF_X1` + `set_load 10.0`,標準的假設值,重點是「有 -constr」而不是這兩個數字本身)並加上 `-D 10000`,啟用 abc 的 sizing pass。
   - **用 slow corner library 而非 typical 做 sizing 判斷**:`dfflibmap`/`abc` 這兩行改成吃 `$NANGATE45_SLOW_LIB` 而不是 `$NANGATE45_LIB`——因為 Yosys/abc 沒有真正的 MMMC(Multi-Mode Multi-Corner)最佳化能力,只能在單一 corner 的時序模型下做 sizing 決策;用 slow corner(worst-case setup)當作 sizing 依據,決策會偏保守,比用 typical corner sizing 更接近真實 signoff flow「對 setup 最壞情況做最佳化」的做法。（最終報告面積/typical Fmax 時仍然用 `$NANGATE45_LIB` 算,因為 cell 面積本身不隨 corner 改變,只有 sizing 決策的依據不同。）

結果:典型 corner 關鍵路徑從 14.821ns 降到 2.881ns,關鍵路徑位置也從 PicoRV32 換回 AES chain,而且比 retrofit 之前的 AES 瓶頸(10.966ns)還快很多——**不只補回 retrofit 掉的頻率,還比原本(未 retrofit)的版本更好**,代價是 chip area 多了 4.76%。用 best-effort LEC(`equiv_simple`)驗證過沒有引入新的邏輯偏差(見 `docs/verification/lec_methodology.md`),19 個 regression target 全過、135 個 lint finding 不變。

## 2. AES 加密吞吐量

`aes_core` 的 iterative datapath 是 21 cycles/block（10 cycles key expansion + 1 initial AddRoundKey + 9 middle rounds + 1 final round,見 `docs/specs/aes.md`),128-bit = 16 bytes/block。

在整體 SoC 目前的 Fmax(第 1 節,347.1 MHz,cycle time ≈ 2.881ns)下(這個數字會隨著第 1 節記錄的 Fmax 演進而變動,是同一套「cycles/block 是量出來的,乘上當時真正的 STA cycle time」算法,不是重新估算方法論):

- 每個 block:21 × 2.881ns ≈ **60.5ns**
- 吞吐量:16 bytes / 60.5ns ≈ **264.5 MB/s**

這是純 AES core 本身(CPU 逐 word 寫暫存器驅動)的數字,不含 DMA 的 burst overhead——DMA 版本見下一節。

## 3. DMA 吞吐量(含 burst overhead)

在 `blocks/dma/dv/dma_engine_sim_main.cpp` 裡直接量測:每次 `run_dma()` 呼叫,從 CTRL.START 寫入到觀察到 STATUS.DONE 為止,實際經過幾個 cycle(透過對 `tick_half` 呼叫次數計數,精確到 cycle,不是估計)。CBC encrypt/CTR/CBC decrypt 三組操作,每組 4 個 block,量到的結果一致:

- **156 cycles / 4 blocks = 39.0 cycles/block**(平均,含 burst 讀 4 拍 + AES 21 cycles + burst 寫 4 拍 + 狀態機切換 overhead + 軟體 polling STATUS 暫存器本身的 bus cycle)

在目前的 Fmax(347.1 MHz,cycle time ≈ 2.881ns)下:

- 每個 block:39 × 2.881ns ≈ **112.4ns**
- 吞吐量:16 bytes / 112.4ns ≈ **142.4 MB/s**

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

## 7. Multi-corner STA(setup at slow corner、hold at fast corner)

第 1 節的 347.1MHz(retrofit 剛完成、還沒補 sizing 的階段是 67.5MHz;更早的 retrofit 前是 91.2MHz)是**單一 typical corner**下量到的數字——真正的 signoff 應該要同時查 setup(worst-case,通常在 slow corner)跟 hold(worst-case,通常在 fast corner),只看 typical 只能當初步估算,不是簽核依據。`blocks/{aes,soc_top}/sta/sta_mcmm.tcl` 補上這一步:同一份 netlist,分別用 OpenSTA 自帶的 Nangate45 slow/fast corner library(跟合成用的 `NangateOpenCellLibrary_typical.lib` 驗證過是同一個 cell family,239/241 顆 cell 完全一致,只差一顆跟邏輯無關的物理 tap cell `TAPCELL_X1`)重新算一次:

| | Setup(slow corner,max delay) | Hold(fast corner,min delay) |
|---|---|---|
| **soc_top** | 關鍵路徑 10.288ns(`u_aes/u_chain` 內部)→ **slow corner Fmax ≈ 97.2MHz** | 全設計 0 個 hold 違規(TNS = 0.00) |
| **aes_core**(獨立合成,這次的 sizing 改動只動了 `blocks/soc_top/syn/synth.ys`,不影響這裡) | 關鍵路徑 38.399ns → **slow corner Fmax ≈ 26.0MHz** | 全設計 0 個 hold 違規(TNS = 0.00) |

Setup 用的 SDC 時脈週期(2.0ns/500MHz)本來就是刻意設定得比實際能達到的頻率更緊(見 `constraints/*.sdc` 註解)——目的是讓 `report_checks` 直接印出關鍵路徑的真實 data arrival time,再自己算 Fmax,不是為了衝一個特定頻率,所以 setup 報告顯示大量違規是預期中的,不代表真的有時序問題;唯一有意義的數字是 data arrival time 換算出來的 slow-corner Fmax,這才是兩個 corner 一起看才拿得到的、比第 1 節保守的真實數字。Hold 完全乾淨(fast corner 下 TNS 剛好 0.00,沒有任何一個 endpoint 違規)——加上第 1 節的 sizing 改動之後重新確認過,hold 依然完全沒有被 sizing 拖垮,原始報告存在 `reports/sign_off/timing/sta_mcmm.txt`。

**`soc_top` 這次的 slow corner Fmax(97.2MHz)比 retrofit 前(43.128ns/≈23.2MHz)、retrofit 剛完成時(51.837ns/19.3MHz)都好很多**——第 1 節提到的 sizing 改動(`abc -constr` + slow corner library)在三個 corner 上都是全面改善,不是只針對 typical corner 調參數湊出來的數字。`aes_core` 獨立合成的數字完全沒變,因為這次的改動範圍刻意只限縮在 `blocks/soc_top/syn/synth.ys`。

## 8. Signoff 範圍界限(刻意的取捨,不是漏掉)

這個專案的 signoff 停在:**RTL → logic synthesis(Yosys)→ gate-level netlist → STA(setup+hold,typical+slow+fast 三個 corner)→ 對 RTL 的 formal equivalence check + gate-level simulation**。以下明確**不做**,是刻意的範圍界限,不是忘記:

- **Place & Route、DRC/LVS、parasitic extraction 等物理實現**——這個專案沒有目標製程的實體 PDK 授權,也沒有真正流片的計畫,做這一步對這個規模的 side project 沒有實質意義。
- **DFT(scan chain insertion、ATPG)**——這是真正流片、需要在生產線上做良率測試的晶片才需要的東西,跟前一項是同一個理由:沒有流片,就沒有「测試良率」這個問題要解決。
- **Power signoff(UPF、多電壓域、clock gating 分析)**——這個設計是單一時脈域、沒有低功耗設計意圖(沒有多電壓域、沒有 power gating),power signoff 沒有對應的設計決策可以驗證。

這條線畫在「gate-level netlist 的邏輯跟時序都驗證過,對得上 RTL」這裡——再往下的每一步都是「怎麼把這個已經驗證過的邏輯,實際做成一塊矽」的問題,不是「這個設計對不對」的問題。

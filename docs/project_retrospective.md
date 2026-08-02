# Project Retrospective：Phase 0 - Phase 7

這份文件記錄整個 RISCV_SOC 專案每個 phase 實際做了什麼、中間踩到哪些真實的 bug、怎麼定位根因、怎麼修的。目的是留一份誠實、可以拿去講給面試官聽的開發紀錄——不是「一路順利做完」的美化版本，而是「這裡卡住了,這樣想錯了,後來怎麼發現的」。

每個 bug 的完整技術細節（暫存器層級、code 片段)也散落在各自的 `docs/specs/*.md` 裡；這份文件的重點是把散落各處的教訓串成一條時間線,並額外指出幾個貫穿多個 phase、重複出現的錯誤模式。

## 貫穿全專案、重複出現的錯誤模式

在細看每個 phase 之前,先點出兩個在**不只一個 phase**裡各自獨立踩到、模式完全一樣的錯誤——因為這種「同一類錯誤重複發生」本身就是這份 retrospective 最值得記住的教訓:

### 錯誤模式 A：暫存器 offset 在窄位元欄位裡被截斷

- **SPI**(Phase 3):`REG_STATUS` 用 `4'h10` 表示,但 offset 欄位只宣告 4-bit 寬(最大 `4'hF`),`4'h10` 直接截斷成 `4'h0`,跟 `REG_CTRL` 撞位址。
- **AES**(Phase 6):加入 CBC/CTR 的 IV 暫存器後,`REG_IV0 = 6'h40` 用 6-bit 欄位表示(最大 `6'h3F`),一樣被截斷成 0,跟 `REG_CTRL` 撞位址。

兩次都是同一個根本原因:**新增暫存器、offset 數字變大時,忘記回頭檢查原本宣告的欄位寬度夠不夠**。修法也一樣:把欄位寬度往上調(SPI 從 4-bit 調到 5-bit,AES 從 6-bit 調到 7-bit)。第二次踩到這個坑時,已經在 code comment 裡明講「這是跟 SPI 那次一樣的錯誤」——即使如此還是真的又踩了一次,說明這類「數字剛好在某個位元寬度邊界附近」的錯誤,光靠「記得有這個教訓」不足以完全避免,得靠工具（例如 lint 規則檢查 offset 常數與宣告欄位寬度的一致性)才能根治。

### 錯誤模式 B：組合邏輯用了「還沒在這一拍更新」的暫存器

- **AES chain**(Phase 6):`core_data_in`/`core_encdec` 原本從 `mode_reg`/`encdec_reg` 算,但這兩個暫存器是在**同一個 edge**被 nonblocking assignment 鎖存的,導致 `aes_core` 真正需要這個值的那一拍,讀到的還是舊值。
- **DMA engine**(Phase 6):`m_wdata`/`m_wstrb`/`m_wlast` 原本用 nonblocking assignment、依賴前一拍的 `beat_cnt` 計算,但用來判斷「這一拍有沒有被接受」的 `if (m_wvalid && m_wready)` 卻是讀當下已經鎖存好的值——兩者之間差一拍,造成資料錯位、`wlast` 訊號永遠對不上真正的最後一拍。

這兩次的根本模式完全一樣:**當某個訊號「只在特定的那一個 edge 才有意義」,卻去讀一個用 nonblocking assignment、要等到下一拍才更新的暫存器**,就會讀到舊值。修法也是同一套:改成直接從「當下」真正即時的訊號(input port,或組合邏輯)算,而不是從會延遲一拍才更新的 register 算。

---

## Phase 0：專案骨架

建立目錄結構、`docs/phase_plan.md`、vendored 進 PicoRV32(`rtl/core/picorv32.v`,原封不動,`VENDORED_SOURCE.md` 記錄來源)。沒有 RTL 邏輯,純粹是骨架。

## Phase 1：AXI4-Lite crossbar(單 master)、ROM/RAM/UART、SoC 第一次跑起韌體

手刻 `axi_lite_xbar.v`(這個專案的核心差異化元件,不是 vendor 來的)。`boot_rom.v`(64KB,`$readmemh` 載入)、`sram.v`(128KB)、`uart.v`(TX-only)。第一次讓 PicoRV32 透過真正的 AXI4-Lite 交易跑一支韌體、印出字串到 UART。

已知限制(從這個 phase 開始就存在,一路留到現在):`picorv32_axi` 這個 adapter 完全沒接 BRESP/RRESP pin,不檢查 SLVERR。這是刻意記錄下來、不是遺漏。

## Phase 2：Timer + Watchdog,第一次接上真正的中斷

`timer.v`(down-counter,auto-reload)、`watchdog.v`(WARNING + reset-request 兩段式)。這個 phase 第一次讓 PicoRV32 走真正的 `getq`/`setq`/`retirq` ISR 路徑處理中斷。

### 真實 bug：`irq` 該是 pulse 還是 level

一開始的直覺是讓 `irq` 訊號維持在高電位,直到軟體清除對應的 STATUS bit 為止(level-sensitive,語意上感覺比較直觀:「中斷還沒被處理完就應該一直喊」)。但 PicoRV32 的 `LATCHED_IRQ` 機制是**每個 clock cycle 都把 `irq` 輸入 OR 進內部的 pending register**,`maskirq` 只決定 pending bit 能不能觸發 ISR 進入,並不會阻止它被重新 latch。如果 `irq` 是 level,ISR 執行到一半、還沒把 STATUS 清乾淨時,這個 bit 早就已經被重新 latch 一次——unmask 後保證會多觸發一次不該有的 ISR。

修法:把 `irq` 一律改成**單一 cycle 的 pulse**,在 STATUS 真正被設定的那一拍才拉一個 cycle 高、下一拍自動降回低。這個決定後來延續到專案裡**每一個**周邊(I2C、SPI、AES、DMA 全部一樣的慣例),`wdog_reset_req` 是唯一的例外——它本來就該是持續到下次 kick 為止的 level 訊號(因為它的用途是餵給下游真正的 reset 產生電路,不是拿去接 PicoRV32 的 irq bus)。

## Phase 3：I2C + SPI,第一次做雙向/開洩極介面

`i2c_master.v`(byte 層級,不支援 clock stretching、不支援多 byte burst)、`spi_master.v`(支援全部 4 種 CPOL/CPHA)。這個 phase 也是第一次需要自己維護「假的從屬裝置」(`fake_i2c_slave.v`、`fake_spi_slave.v`)才能驗證,因為 I2C/SPI 天生是需要另一端配合才能測的介面。

### 真實 bug 1：SPI 暫存器 offset 截斷(見上方「錯誤模式 A」)

`REG_STATUS = 4'h10` 在 4-bit 欄位裡被截斷成 0,跟 `REG_CTRL` 撞位址。修法:整個模組所有 offset localparam 改宣告成 5-bit。

### 真實 bug 2：SPI CPHA=1 模式漏收 MSB

CPHA=1 理論上是「leading edge 換下一個 bit,trailing edge 取樣」,但第一次實作時完全照這個規則走,結果收到的資料固定是 `sent << 1`——永遠漏掉最高位元(MSB)。花了不少功夫用 `$display` 追每個 edge 實際的 `mosi`/`sclk` 值才定位到根因:一開始懷疑是 zero-delay 模擬的 race condition,後來才確認是 edge 邏輯本身漏了一個特例——shift register 在 START 當下就已經載入了完整、未經處理的原始 byte,第一個 leading edge 時 bit 7 早就正確地擺在該擺的位置上,這時候如果還照「leading edge 就 shift」的規則再 shift 一次,反而會跳過 bit 7、直接把 bit 6 送出去。修法:`edge_cnt==0` 時例外處理,不在第一個 leading edge shift。

### 真實 bug 3：I2C START condition 一拍做兩件事

一開始把「SDA 下降」跟「SCL 下降」放在同一個 clock edge 一起做。問題是:任何外部觀察者都沒辦法把「SDA、SCL 同時變化」跟純粹的雜訊區分開來——I2C 規範定義的 START condition 明確要求 SCL 維持高電位、SDA 才下降,slave 端的偵測邏輯永遠等不到這個條件成立。修法:拆成兩個獨立的 tick,第一拍只拉低 SDA(SCL 仍為高,這才是真正可被觀察到的 start condition),下一拍才讓 SCL 落下。

### 真實 bug 4：I2C ACK/NACK 釋放時機點錯邊

假 slave 端原本把 ACK/NACK 的釋放動作放在 `scl_rising`(SCL 剛變高、準備被 master 取樣的那一刻)。結果 SDA 剛好在 SCL 仍為高電位時上升——這跟 STOP condition 的定義一模一樣,master 端把它誤判成一次 STOP,交易被瞬間中止。修法:把釋放動作移到 `scl_falling`,讓 ACK/NACK 的值撐過整個 SCL 高電位期間,只在下一次 SCL 落下時才允許改變。

## Phase 4：AES-128,從第一原理重新推導

`aes_key_expand.v`(key schedule)、`aes_core.v`(iterative round datapath,~21 cycles/block)、`aes.v`(AXI-Lite 暫存器包裝)、`aes_pkg.vh`(共用的 S-box/GF(2^8) 函式)。

這個 phase 的重點不是「踩到什麼 bug」,而是**驗證方法論本身**:S-box 表不是從網路上抄現成的表,而是寫一支獨立的 Python 腳本,從 GF(2^8) 的乘法反元素(reduction polynomial `x^8+x^4+x^3+x+1`)加上仿射變換,重新算出全部 256 個值,再拿 FIPS-197 公開的已知值交叉驗證。整個模組用四層獨立方法驗證:key expansion 單元測試(FIPS-197 App. A.1)、core 直接測試(App. B + C.1)、AXI-Lite 介面測試、以及一個**從零獨立寫的 C++ 軟體參考模型**跑 500 組隨機明文/金鑰的 differential test。這個「先驗證推導過程本身,再拿獨立實作互相比對」的方法論,後來被沿用到 Phase 6 的 CBC/CTR 驗證(NIST SP 800-38A 向量也是先寫 Python 腳本算過一輪才動手寫 RTL)。

Nangate45 合成+STA(僅 `aes_core`,不含 AXI wrapper):Fmax ≈ 98.5MHz,關鍵路徑在 key expansion 的組合邏輯——這個數字後來在 Phase 7 整顆 SoC 合成時得到交叉驗證(見下方 Phase 7)。

## Phase 5：JTAG debug bridge,crossbar 升級成真正的 2-master

`jtag_tap.v`(IEEE 1149.1 16-state FSM)、`jtag_dtm.v`(IR/DR 暫存器)、`jtag_axi_bridge.v`(唯一橫跨 tck/clk 兩個 clock domain 的模組,自己擁有 CDC)。`axi_lite_xbar.v` 從單 master 升級成 2-master(CPU=s0、JTAG=s1)fixed-priority 仲裁。

### 真實 bug 1：CDC 用 level 訊號同步,漏接短 pulse

一開始用「同步 BUSY 這個 level 訊號」的方式做 clk→tck 的跨時鐘域,邏輯上乍看合理。但這個專案裡 `tck` 刻意設成比 `clk` 慢很多(模擬真實 JTAG probe 的情境),一次 AXI-Lite 交易(只要幾個 clk cycle)整個 BUSY-high 的區間,可能完全落在兩個 tck edge 之間——tck 側永遠採樣不到這個訊號曾經變化過。修法:雙方各自維護一個 toggle bit,比較兩邊 toggle 是否不同來判斷「有沒有發生過一次交易」,這個做法不管兩個 clock 週期比例是多少都不會漏接,因為它偵測的是「有沒有翻轉過」而不是「當下是不是高電位」。

### 真實 bug 2：crossbar 仲裁的 grant 在交易途中被偷走

原本 `w_open`(「現在可以重新仲裁」的條件)只檢查 `!w_have_aw && !w_have_w`。但當某個 master 的 AW 和 W 剛好同一拍一起被接受時,crossbar 進入 `W_ISSUE` 的同一個 transition 也會把這兩個旗標重置回 0——導致 `w_open` 在已經進入 `W_ISSUE` 的下一拍,又暫時被讀成「true」。如果這一拍剛好另一個 master 也在要求,grant 就會被中途搶走,原本那筆已經在飛的交易,回應最後被送回錯的 master,另一邊則永遠等不到回應。這個 bug 只有在「兩個 master 真的同時競爭、而且剛好卡在那個過渡拍」才會觸發——`axi_lite_xbar` 自己的單元測試(用假 slave,沒有真正的雙 master 同時競爭場景)沒抓到,是在 `soc_top` 整合測試(CPU 持續在背景寫 stack、JTAG 同時嘗試寫入)才浮現。修法:讓 `w_open` 明確多檢查一個 `w_state==W_IDLE` 條件。這個發現本身也是一個教訓:**單元測試驗證的是模組自己聲稱的行為,但某些 timing bug 只有在真正的系統整合、多個真實 master 同時競爭時才會出現**——這正是為什麼專案從這個 phase 開始,每次新增周邊都會在 `soc_top` 層級再跑一次整合回歸,不是只信任 block 自己的單元測試。

## Phase 6：AES CBC/CTR chaining + AXI4 burst DMA engine(選配延伸)

`aes_chain.v`(包住 Phase 4 的 `aes_core.v` 不動,加上 CBC/CTR mode-of-operation)、`dma_engine.v` + `dma_ram.v`(真正的 AXI4 burst master,讓 DMA 直接串流資料過 AES,CPU 零介入)、`rtl/include/axi4.vh`(AXI4 burst 欄位定義)。DMA 的控制埠接進 crossbar 成為第 9 個 slave,但它自己的 AXI4 burst 資料路徑刻意**不**接 crossbar,直接點對點接一塊私有的 `dma_ram.v`(架構理由見 `docs/specs/dma.md` 第 1 節)。

### 真實 bug 1：`aes_chain` 用了還沒更新的 mode/encdec 暫存器(見上方「錯誤模式 B」)

`core_data_in`/`core_encdec` 原本從 `mode_reg`/`encdec_reg` 算,這兩個暫存器卻是在**同一個 edge**被鎖存的,導致 `aes_core` 真正需要這個值的那一拍讀到舊值(reset 預設值,也就是 ECB)。表現出來的症狀是:CBC 模式的第一個 block,實際被當成純 ECB 加密——確認方式是拿 `$display` 印出 `core_data_out`,發現它跟 NIST 官方**ECB**測試向量(`3ad77bb40d7a3660a89ecaf32466ef97`)完全一致,而不是預期的 CBC 密文,才確認問題出在「用了錯誤模式」而不是資料路徑本身算錯。修法:改成直接從即時的 `mode`/`encdec` input port 算,而不是從會延遲一拍的 `_reg` 版本算。

### 真實 bug 2：AES register offset 又截斷了一次(見上方「錯誤模式 A」)

加入 IV0-3 暫存器後,`REG_IV0 = 6'h40` 在 6-bit 欄位裡被截斷成 0,跟 `REG_CTRL` 撞位址——跟 Phase 3 的 SPI bug 是同一類錯誤,連 code comment 都寫了「這是跟 SPI 那次一樣的錯誤」才發現的。修法:整個模組所有 offset 欄位從 6-bit 加寬到 7-bit。

### 真實 bug 3：DMA engine 寫入 burst 的 `wlast` 永遠對不上真正的最後一拍(見上方「錯誤模式 B」)

`dma_engine.v` 的 `ST_WR_DATA` 狀態裡,`m_wdata`/`m_wstrb`/`m_wlast` 原本用 nonblocking assignment、依照「當下的 `beat_cnt`」計算,但拿來判斷「這一拍是否真的被 slave 接受」的 `if (m_wvalid && m_wready)`,讀的卻是**已經鎖存好、屬於上一拍計算結果**的 `m_wvalid`——這兩者之間存在一拍的落差:FSM 以為第一個 beat 已經送出,但那一拍匯流排上真正跑的資料其實是「上一次 burst 殘留的舊值」,而 `wlast` 訊號在真正該拉高的那一拍,`m_wvalid` 卻已經被同一拍的邏輯提前拉低——導致 `dma_ram.v` 的寫入端 FSM **永遠沒有在一個 `wvalid=1` 的合法拍看到 `wlast=1`**,狀態機因此卡在 `W_BURST` 永遠出不來,後續每一個 block 的第二次 write burst 都會卡死。

除錯過程:先加了兩層暫時性的 `$display`(FSM 狀態變化追蹤 + `ST_WR_ADDR` 進入點追蹤),發現「第一個 block 的完整讀寫循環會走完,但第二個 block 的 write 階段 `m_awready` 永遠拉不起來」。順著這條線索,直接去看 `dma_ram.v` 的寫入端狀態機,才發現它其實卡在 `W_BURST`——第一個 burst 根本沒有正常結束過。再逐拍手動推導 `m_wvalid`/`m_wdata`/`m_wlast` 在每個 cycle 的實際值,才抓到「資料計算的時序」跟「握手判斷的時序」之間那一拍的落差。

修法:把 `m_wdata`/`m_wstrb`/`m_wlast` 改成**組合邏輯**(直接從 `wr_block`/`beat_cnt` 算,不經過暫存器延遲),這樣當 `beat_cnt` 到達最後一拍、`m_wvalid` 仍為 1 的那個當下,`m_wlast` 也同一拍就是 1——徹底消除「資料時序」跟「握手時序」之間的落差。

### 真實 bug 4:測試專用的 mux 用 `arvalid` 當「有沒有在讀」的判斷依據,但讀資料階段跟位址交握階段時間點不同

修完上面那個 bug 後,`dma_engine_sim`(端到端測試)的結果仍然是「操作有跑完,但讀回來的資料全部錯」。直接在 `dma_ram.v` 的寫入路徑加 `$display` 印出「實際寫進哪個 word index、寫了什麼值」,結果證實:**寫進去的資料其實完全正確**(4 個 block 的密文都精準對上 NIST 向量)。既然寫入端沒有問題,那 bug 一定出在讀回來驗證用的路徑——也就是 `dma_engine_testtop.v` 這個測試專用的 harness,它讓 C++ 測試碼可以在 DMA engine 閒置時,直接戳 `dma_ram.v` 做預載/讀回驗證。

問題出在:`use_test_port_r = ram_arvalid`——這個 mux 只在**位址交握**的那一拍(C++ 端设 `ram_arvalid=1` 的瞬間)才把讀取通道切給測試埠,但一個 burst 的**資料階段**(4 拍資料 + 最後的 `rlast`)是在位址交握**之後**才發生的,而 C++ 端的 `ram_arvalid` 早在位址交握完成的那一拍就被寫回 0 了——導致整個資料階段 mux 都切回了 DMA engine 自己的讀取通道(當時是閒置的),讀取通道的 `rvalid` 因此被強制拉成 0,C++ 端的讀取迴圈因為看不到任何 `rvalid`,只能收集到一小段殘缺/空的資料就提前結束,`std::vector` 存取超出實際大小的索引造成未定義行為,湊巧顯示出「所有讀回結果都一樣、且第一個 word 剛好等於某個舊資料」這種容易誤導人的假象。

修法:把測試埠的路由判斷條件改成 `ram_arvalid || ram_rready`——`ram_rready` 是 C++ 端在整個讀取資料階段都會持續拉高的訊號(直到看到 `rlast` 才放開),用它來延續整個 burst 期間的路由,而不是只看轉瞬即逝的位址交握訊號。這個修法完全對應寫入路徑本來就用 `ram_awvalid || ram_wvalid`(`ram_wvalid` 同樣是資料階段持續拉高的訊號)這個已經正確的寫法——讀取路徑一開始漏掉了這個對稱性。

這個 bug 值得特別記錄的地方在於:它是**測試 harness 本身的 bug**,不是 RTL 的 bug——這個專案從 Phase 3(假 slave)開始就一直有「測試碼本身也可能寫錯」的警覺,這次剛好是另一個具體例證:一開始看到「資料全部不對」,直覺會先懷疑是 RTL 邏輯錯了,但先去 RTL 內部(`dma_ram.v` 的實際寫入)加 trace 確認資料本身無誤之後,才正確地把懷疑範圍收斂到測試 harness 本身。

## Phase 7：文件與 Sign-off

`docs/architecture.md`、`docs/memory_map.md`、`docs/verification_summary.md`、`docs/performance.md`;整顆 SoC 的 Yosys 合成 + OpenSTA timing(`blocks/soc_top/syn/`、`blocks/soc_top/sta/`);`scripts/run_regression.sh` 一次跑完全部 18 個測試 binary。

### 真實 bug：`scripts/run_regression.sh` 第一次跑,就抓到一個潛伏的 watchdog 測試 bug

在把每個 block 的測試整合進同一支 regression 腳本、確保每一個都是**乾淨重新編譯**(不是沿用可能已經過時的 build 產物)之後,`watchdog` 測試意外地失敗了 2 個 check——但目錄裡舊的、還沒被清掉的 `wdt_sim` binary 卻是綠的。追下去發現:`blocks/watchdog/sim/sim_main.cpp` 裡寫死的 `WARN_MARGIN = 3`,跟 `watchdog.v` 實際的 default parameter `WARN_MARGIN = 4` 對不上——而且 `watchdog.v` 的這個 default 值從 Phase 2 第一次 commit 開始就一直是 4,`docs/specs/watchdog.md` 裡也一直寫著「預設 4」,兩邊唯一不一致的地方就是這個測試裡寫死的常數。也就是說:**這個測試常數從一開始就是錯的**,只是舊的 `wdt_sim` binary 剛好是在某次意外用對數字的情況下建出來的,之後這個常數被改錯、卻沒人重新乾淨編譯過,binary 就一直「看起來是綠的」,實際上早就跟原始碼脫鉤了。

這正是「維護一支能一次性乾淨重跑全部測試的 regression 腳本」存在的意義:它抓到的不是「這次改動引入的新 bug」,而是「原始碼其實已經跟已建置的驗證結果不一致、只是沒人重新跑過驗證」這種悄悄發生的腐化(rot)。修法很單純:把測試常數改成 4,重新編譯,全綠。

### 效能數據的驗證方法論註記

Phase 7 的效能數據(`docs/performance.md`)全部來自**真正跑起來的量測**,不是估算:
- Fmax 來自對整顆 SoC(記憶體陣列以 blackbox 處理)做真正的 Yosys 合成 + OpenSTA timing analysis,不是只合成單一模組後外推。
- DMA 的 cycles/block 數字來自在 C++ testbench 裡對 `tick_half` 呼叫次數做精確計數,不是理論值。
- 中斷延遲(3-14 cycles,平均 8.6)是直接寫一支 scope-aware 的 VCD parser,對 `blocks/soc_top/sim/wave.vcd` 這份已經存在的完整波形做後處理量出來的——過程中也踩到一個小坑:一開始猜測需要透過 Verilator 的內部 hierarchy signal 存取 PicoRV32 深層的 `irq_active` 暫存器,但 Verilator 預設不會把這類內部訊號暴露成可以直接存取的 C++ member,與其冒險用 `--public` 之類的旗標重新編譯、或用不穩定的內部命名去猜 C++ member 名稱,不如**直接解析既有的 VCD 波形檔**——`soc_top_sim` 本來就已經用 `--trace` 深度 99 產生完整波形,VCD 格式本身很單純(`$scope`/`$var`/`$upscope` 定義 hierarchy,後面是逐拍的訊號變化),不需要額外的 Python 套件也能寫出一支可靠的最小化 parser。

## Phase 7 後續補強:補上獨立的 lint pass,抓到真正的 dead code

Phase 7 完成、簽核之後,原本的判斷是「整顆 SoC 都合成得出來了,而且每次 build 都會附帶跑一輪 Verilator 內建 lint,再花時間跑一次獨立、有自己 report 的 `--lint-only` pass 意義不大」。但後來重新想了一下:整個專案每一次 build(包含 `scripts/run_regression.sh`)都固定加了 `-Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM`——這兩個 flag 剛好就是專門抓「訊號/parameter 宣告了但沒人用」的警告,一直被關掉,等於這整條路徑上,真正的死碼從來沒被檢查過。

實際拿掉這兩個 flag、對整顆 SoC 跑一次 `--lint-only`,抓到 4 處真正的死碼:

1. **`jtag_axi_bridge.v`**:`rw_reg` 有被賦值(`rw_reg <= rw_tck`),但 FSM 實際判斷用的是即時的 `rw_tck`,`rw_reg` 從頭到尾沒人讀過。
2. **`jtag_dtm.v`**:`tap_state` 接了 `jtag_tap` 的 state 輸出,但 `jtag_dtm` 全部判斷都是用明確的 pulse 訊號(`capture_dr`/`shift_dr`/`update_dr`...),這條線完全沒用到。
3. **`aes_chain.v`**:`ST_DONE` 這個 FSM 狀態常數宣告了,但 `state` 只在 `ST_IDLE`/`ST_CORE` 兩個狀態之間切換,`ST_DONE` 從來沒被真正進入過——像是早期設計是 3-state,後來簡化成 2-state,但沒清掉這個殘留常數。
4. **`spi_master.v`**:`tx_shift[7]` 被載入(`tx_shift <= txdata_reg`)但從沒被讀過——第一個要送出的 bit 其實是直接從 `txdata_reg[7]` 拿,之後每次 shift 只讀 `tx_shift[6:0]`,bit 7 形同虛設。修法是把 `tx_shift` 從 8-bit 縮成 7-bit(只保留真正會被讀到的 `[6:0]`),shift/mosi 讀取的 bit index 完全不用改,因為它們本來就只碰 `[6:0]`。

四處都全部驗證過:重新跑一次 `-Wall`(不含前述兩個 `-Wno-*`)的 lint,確認這 4 個警告消失;再跑一次完整的 18 項 regression,確認全部維持綠燈,且整顆 SoC 的 STA 關鍵路徑數字(10.966ns)完全沒變——這些都是功能上無害的殘留,合成本來就會默默優化掉,只是原始碼裡多留了幾行沒人讀的邏輯。

同一次 lint pass 也發現(但判斷為刻意的架構取捨、不修改,只補進 `docs/architecture.md` 第 7 節):**幾乎每個周邊的 AXI-Lite response channel 都沒有真的檢查對方的 `s_bready`/`s_rready`**(固定拉一拍 valid 就自動放下),以及 **`dma_engine.v` 自己的 burst master 不檢查 `dma_ram` 回應的 `m_bresp`/`m_rresp`**(跟已知的 `picorv32_axi` 不檢查 BRESP/RRESP 同一類)。這兩個之所以沒引發任何測試失敗,是因為這個專案自己的 crossbar/測試環境剛好都是「提前準備好接收」的行為,跟 AXI4 規範要求的「VALID 必須撐到 READY 也是高電位」不完全等價——是巧合式正確,不是規範保證的正確。

### 新的政策:每個 block 都固定跑一次獨立的 lint

`scripts/run_lint.sh` 對每個 block 的真實 deliverable RTL(不含測試專用的 testtop/fake slave)各自跑一次 `verilator --lint-only`,結果存進 `blocks/<name>/lint/lint_report.txt`。跟 `-Wno-UNUSEDSIGNAL`/`-Wno-UNUSEDPARAM` 被關掉的一般 build 不同,這支腳本刻意保留這兩個檢查,只保留 `-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC`(這個專案大量使用 register-offset 常數跟位址欄位的寬度轉換,這兩個警告噪音大於訊號)跟 PicoRV32 自己風格造成的 4 個 flag。

也對 vendored 的 `rtl/core/picorv32.v` 單獨跑了一次**完全不加任何 `-Wno-*`** 的 lint(`rtl/core/lint/lint_report.txt`),列出全部 44 個警告供參考,但**沒有修改這個檔案**——PicoRV32 是這個專案明確規定「vendored、不修改」的核心。44 個警告裡,21 個 BLKSEQ + 7 個 GENUNNAMED + 1 個 DECLFILENAME 都是已知、已經在 README 記錄過的 PicoRV32 自身編碼風格(不是這個專案的問題);15 個 UNUSEDSIGNAL 裡有 14 個是 `dbg_*` 開頭的內部除錯訊號(PicoRV32 自己刻意留給波形除錯用、本來就不會被消費的慣例),剩下 1 個是 `mem_busy`(一個算出來但從沒被讀過的便利訊號)——這些都只是記錄下來,留給任何未來真的需要動 PicoRV32 fork 版本的人參考,這個專案本身不動它。

### 重要的釐清:Verilator lint 到底能抓什麼、不能抓什麼

`--lint-only` 完全是**靜態分析**——不跑模擬、不合成,純粹分析 RTL 的語法樹跟訊號流,能抓的是「寫法上看得出來有問題」的東西,不是「邏輯在時序上到底對不對」。實際會用到的檢查大致分四類:

- **寬度/型別**:`WIDTHEXPAND`/`WIDTHTRUNC`(賦值兩邊 bit 寬度不一致)、`SELRANGE`(bit-select 索引超出訊號寬度)。這個專案大量用register-offset 常數跟位址欄位寬度轉換,雜訊大於訊號,所以這兩個從一開始就被 `-Wno-` 關掉。
- **訊號流**:`UNUSEDSIGNAL`/`UNUSEDPARAM`(這次抓到的 4 個死碼)、`UNDRIVEN`(訊號被讀但沒人驅動——Phase 6 `dma_engine.v` 早期忘記驅動 `m_wstrb` 就是這個警告攔下來的)、`MULTIDRIVEN`(同一訊號被多處驅動)。
- **FSM/邏輯結構**:`CASEINCOMPLETE`/`CASEOVERLAP`(case 沒 default、或多個分支常數值重疊——Phase 3 SPI 跟 Phase 6 AES 的 register-offset 截斷 bug 都是這個警告抓到的)、`LATCH`(組合邏輯 `always` block 漏寫分支,意外推導出 latch)、`UNOPTFLAT`(偵測不到拓樸順序的組合邏輯迴圈)。
- **風格/慣例**(比較主觀,PicoRV32 自身風格用的那 4 個 `-Wno-*` 都屬於這類):`BLKSEQ`(clocked block 裡用了 blocking assignment)、`DECLFILENAME`(module 名稱跟檔名不一致)、`GENUNNAMED`(`generate` block 沒命名)、`PINCONNECTEMPTY`(port 明確接空的 `()`)。

**它做不到的事,比它能做到的事更值得記住**:這個專案目前為止踩過、修過的真正功能性 bug——`aes_chain` 用了還沒更新的 `mode_reg`、`dma_engine` 的 `wlast` 差一拍、SPI CPHA 的 `edge_cnt==0` 特例、I2C 的 START condition 時序、crossbar 仲裁 grant 被中途偷走——**沒有一個是 lint 能抓到的**,全部都是靠 cycle-accurate 的模擬、逐拍跟軟體參考模型比對才抓到的。Lint 只能回答「這裡有沒有東西宣告了沒用、case 有沒有漏、寬度有沒有兜不齊」,回答不了「這個訊號在這一拍讀到的到底是不是你以為的那個值」——這正是為什麼這個專案從 Phase 1 開始就把驗證重心放在 cycle-accurate simulation + 獨立軟體模型比對,lint 只是這次才補上的、範圍窄很多的第二道防線,補的是「死碼/風格」這一層,不是「邏輯正確性」那一層。

### 新增:`reports/soc_top/` 一站式 sign-off 報告快照

`scripts/collect_soc_reports.sh` 一次跑完整個 SoC 層級的 simulation regression、lint、synthesis、STA,把結果收斂進 `reports/soc_top/`(這個資料夾**會**進版控,是刻意留下的簽核快照,跟 `blocks/*/syn`、`blocks/*/sta` 那些隨時可重新產生、故意不進版控的 scratch log 不同)。合成產生的完整 Yosys log 動輒幾十 MB(每一輪 PicoRV32 hierarchy 的中間優化 pass 都會印出來),不值得進版控,所以只保留最後的面積/cell 統計摘要;完整版留在本地的 `blocks/soc_top/syn/synth_log.txt`(已在 `.gitignore`)。

### 再往下一層:量化的 coverage(line/toggle/branch/FSM)+ 圖像化的 sign-off dashboard

lint 抓到「有沒有死碼」,但沒辦法回答「測試到底覆蓋了多少邏輯」——這需要真正的 coverage 數據。`scripts/run_coverage.sh` 對全部 18 個 regression 測試,改用 `--coverage-line --coverage-toggle` 重新建置、跑過一輪,把每個測試自己的 `coverage.dat` 合併成一份專案層級的聚合結果,再用 `verilator_coverage` 產生 per-file annotated source(每一行標上被 hit 幾次)跟一份 lcov `.info`。

**FSM state coverage 沒有現成的路可以直接拿**:Verilator 的 `--coverage-fsm` 是針對它自己能辨識的特定 FSM 樣式做的啟發式偵測,實際對這個專案裡全部 11 個用 `localparam` + `case` 寫的純 Verilog-2001 FSM(`spi_master`、`i2c_master`、`uart`、`jtag_tap`、`aes_core`、`aes_chain`、`axi_lite_xbar` 的讀寫兩個 FSM、`dma_ram` 的讀寫兩個 FSM、`dma_engine`)測試後,一個都沒抓到——`fsm_state`/`fsm_arc` 兩個類別的 summary 永遠是 0/0。改用另一個角度:annotated 檔案裡,每一個 `case (state)` 的分支開頭(例如 `ST_IDLE: begin`)本來就會帶有自己的 line-coverage hit count——這其實就是「這個狀態有沒有被進入過」最直接、最精確的訊號,不需要額外的 instrumentation。`scripts/analyze_coverage.py` 直接從 annotated 檔案裡,對每個 FSM 已知的狀態名稱清單(從原始碼讀出來的,不是猜的)去查對應那一行的 hit count,組出一份真正的「每個狀態有沒有被走到過」表格。結果:**11 個 FSM,全部狀態都被走到至少一次(100%)**。

同一支腳本也把 `blocks/*/lint/lint_report.txt` 的全部 135 筆 lint 發現,依照訊息內容自動分類成幾個桶(已修好的死碼類型此時已經歸零、剩下的是「文件記錄過的限制」如 BREADY/RREADY/BRESP/RRESP 沒被檢查、「刻意的設計」如位址高位元/byte-strobe/burst 欄位不用、「vendored PicoRV32 自身風格」),避免簡單粗暴地把 135 行原始警告直接倒給人看。

最後 `scripts/build_dashboard.py` 把這些數據(coverage 百分比、FSM 狀態表、分類後的 lint 發現、架構圖)全部渲染成一個單一的靜態 HTML 頁面(`reports/soc_top/dashboard.html`),取代原本純文字的 report——這個檔案本身也進版控,跟其他 `reports/soc_top/` 底下的檔案一樣是刻意留下的快照,不是每次都要重新產生才能看的東西。

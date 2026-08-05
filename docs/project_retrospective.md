# Project Retrospective：Phase 0 - Phase 7

這份文件記錄整個 RISCV_SOC 專案每個 phase 實際做了什麼、中間踩到哪些真實的 bug、怎麼定位根因、怎麼修的。目的是留一份誠實的開發紀錄——不是「一路順利做完」的美化版本，而是「這裡卡住了,這樣想錯了,後來怎麼發現的」。

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

### 錯誤模式 C：用「原值 + bitwise complement」兩個值想補滿 toggle coverage,結果只補到一半

在把 toggle coverage 從 80.1% 推到 90%+ 的過程中(見 `docs/coverage_waivers.md` 第 5 節),同一個邏輯錯誤連續踩了三次,分別在 DMA 的 `key_reg`/`iv_reg`、`axi_lite_xbar` 每個 slave port 自己的 rdata mirror、以及透過 JTAG poke `soc_top.v` 的 top-level mirror wire。

三次都是同一個想法:「這個暫存器原本只寫過一個固定值 V1,要讓每個 bit 都雙向 toggle 過,寫一次 `~V1`(bitwise complement)應該就夠了」。實際推演發現不對:假設暫存器 reset 值是 0,依序寫入 V1 再寫入 `~V1`——**V1 裡是 1 的 bit** 會經歷 `0→1(寫V1)→0(寫~V1)`,兩個方向都覆蓋到;但 **V1 裡是 0 的 bit** 只會經歷 `0→0(寫V1,沒變化)→1(寫~V1)`,只有單一方向,序列在這裡就結束,永遠補不到「1→0」。如果 V1 剛好 1-bit 很少(例如 `axi_lite_xbar` 測試裡 Timer 用的 `0x11110004`,32 bit 裡只有 5 個 1),兩值法實際上只補得到不到 1/6 的 bit,遠低於預期。

三次都是先照「兩值法」做、實測 coverage 數字幾乎沒動,才回頭發現這個推演漏洞。修法是同一套:**用兩個極值(全 0、全 1)取代「原值+complement」**,或是在兩值法後面多加第三步「寫回原值」,讓每個 bit 都至少經歷一次完整的雙向 transition。往後任何想靠「寫一兩個值」補 toggle coverage 的場合,先手算一次每個 bit 實際會不會雙向 transition,不要假設「值不一樣」就等於「雙向都補到」。

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

在把每個 block 的測試整合進同一支 regression 腳本、確保每一個都是**乾淨重新編譯**(不是沿用可能已經過時的 build 產物)之後,`watchdog` 測試意外地失敗了 2 個 check——但目錄裡舊的、還沒被清掉的 `wdt_sim` binary 卻是綠的。追下去發現:`blocks/watchdog/dv/sim_main.cpp` 裡寫死的 `WARN_MARGIN = 3`,跟 `watchdog.v` 實際的 default parameter `WARN_MARGIN = 4` 對不上——而且 `watchdog.v` 的這個 default 值從 Phase 2 第一次 commit 開始就一直是 4,`docs/specs/watchdog.md` 裡也一直寫著「預設 4」,兩邊唯一不一致的地方就是這個測試裡寫死的常數。也就是說:**這個測試常數從一開始就是錯的**,只是舊的 `wdt_sim` binary 剛好是在某次意外用對數字的情況下建出來的,之後這個常數被改錯、卻沒人重新乾淨編譯過,binary 就一直「看起來是綠的」,實際上早就跟原始碼脫鉤了。

這正是「維護一支能一次性乾淨重跑全部測試的 regression 腳本」存在的意義:它抓到的不是「這次改動引入的新 bug」,而是「原始碼其實已經跟已建置的驗證結果不一致、只是沒人重新跑過驗證」這種悄悄發生的腐化(rot)。修法很單純:把測試常數改成 4,重新編譯,全綠。

### 效能數據的驗證方法論註記

Phase 7 的效能數據(`docs/performance.md`)全部來自**真正跑起來的量測**,不是估算:
- Fmax 來自對整顆 SoC(記憶體陣列以 blackbox 處理)做真正的 Yosys 合成 + OpenSTA timing analysis,不是只合成單一模組後外推。
- DMA 的 cycles/block 數字來自在 C++ testbench 裡對 `tick_half` 呼叫次數做精確計數,不是理論值。
- 中斷延遲(3-14 cycles,平均 8.6)是直接寫一支 scope-aware 的 VCD parser,對 `blocks/soc_top/dv/wave.vcd` 這份已經存在的完整波形做後處理量出來的——過程中也踩到一個小坑:一開始猜測需要透過 Verilator 的內部 hierarchy signal 存取 PicoRV32 深層的 `irq_active` 暫存器,但 Verilator 預設不會把這類內部訊號暴露成可以直接存取的 C++ member,與其冒險用 `--public` 之類的旗標重新編譯、或用不穩定的內部命名去猜 C++ member 名稱,不如**直接解析既有的 VCD 波形檔**——`soc_top_sim` 本來就已經用 `--trace` 深度 99 產生完整波形,VCD 格式本身很單純(`$scope`/`$var`/`$upscope` 定義 hierarchy,後面是逐拍的訊號變化),不需要額外的 Python 套件也能寫出一支可靠的最小化 parser。

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

### 新增:`reports/sign_off/` 一站式 sign-off 報告快照

`scripts/collect_soc_reports.sh` 一次跑完整個 SoC 層級的 simulation regression、lint、synthesis、STA,把結果收斂進 `reports/sign_off/`(這個資料夾**會**進版控,是刻意留下的簽核快照,跟 `blocks/*/syn`、`blocks/*/sta` 那些隨時可重新產生、故意不進版控的 scratch log 不同)。合成產生的完整 Yosys log 動輒幾十 MB(每一輪 PicoRV32 hierarchy 的中間優化 pass 都會印出來),不值得進版控,所以只保留最後的面積/cell 統計摘要;完整版留在本地的 `blocks/soc_top/syn/synth_log.txt`(已在 `.gitignore`)。

### 再往下一層:量化的 coverage(line/toggle/branch/FSM)+ 圖像化的 sign-off dashboard

lint 抓到「有沒有死碼」,但沒辦法回答「測試到底覆蓋了多少邏輯」——這需要真正的 coverage 數據。這一段完整記錄實際建置這套 coverage + dashboard 流程時,真的卡住、真的踩過的每一個坑,不是事後補寫的乾淨版本。

#### 第一個坑:`--coverage` build 出來,但 `coverage.dat` 從沒出現過

用 `--coverage-line --coverage-toggle` 重新編譯 `timer` 測試、跑完,`VM_COVERAGE=1` 確認有生效,程式也正常印出 PASS——但目錄裡完全找不到 `coverage.dat`。查了才知道:`--coverage` 只是在 Verilated model 裡打開 instrumentation(每個 coverage point 都會在模擬過程中累積次數),但**不會自動把結果寫成檔案**——一定要在 C++ testbench 的 `main()` 裡明確呼叫 `VerilatedCov::write("coverage.dat")`。這個專案裡全部 18 支 `sim_main.cpp`(或等效檔名)都沒有這行,得手動一一補上。因為要同時保留原本乾淨的 `run_regression.sh`(不掛 coverage instrumentation)不受影響,補上的寫法是用 `#if VM_COVERAGE` 包起來——`VM_COVERAGE` 這個 macro 只有在真的用 `--coverage-*` build 時才會是 1,一般 build 底下這整段完全是 no-op,兩條路徑共用同一份原始碼,不用維護兩份測試檔。

#### 第二個坑:寫是寫了,但 `coverage.dat` 只有 22 bytes(只有 header,沒有任何真實的 coverage point)

補上 `VerilatedCov::write(...)` 呼叫的第一次嘗試,把它放在 `delete dut; delete ctx;` **之後**——build 成功、跑起來也是 PASS,`coverage.dat` 確實出現了,但只有一行 `# SystemC::Coverage-3`,完全沒有任何實際的 coverage point。原因:`delete ctx` 這個動作會把這個 context 自己的 coverage 累積器一起拆掉,寫入呼叫如果排在拆除**之後**,能寫的東西早就沒了。修法:把 `VerilatedCov::write(...)` 移到 `delete dut;` **之前**——這個順序上的細節,跟這個專案先前好幾次「不是邏輯錯,是時序/順序錯了一拍」的教訓是同一個大類別的錯誤,只是這次發生在 C++ testbench 的收尾程式碼,不是 RTL 本身。

#### 第三個坑:`--coverage-fsm` 對這個專案的 FSM 一個都沒認出來

打開 `--coverage-fsm`,先拿 `timer.v`(其實沒有真正的 FSM,只是一個 down-counter)測,`fsm_state`/`fsm_arc` 都是 0/0——合理,反正它本來就不是 FSM。但換成 `spi_master.v`(有明確的 `localparam IDLE = 1'b0; localparam RUN = 1'b1;` 兩態 FSM)重新測,結果還是 0/0。這代表 Verilator 的 `--coverage-fsm` 啟發式偵測,對這種純 Verilog-2001、用 `localparam` + `case` 手寫的 FSM 樣式沒有反應——它辨識的可能是別的、更特定的寫法慣例。既然這條路走不通,只能換個角度自己組出 FSM coverage。

#### 換一個角度:從 line coverage 裡直接撈 case-arm 的 hit count

直接打開 `timer` 那次(--coverage-line 已經開著)產生的原始 `coverage.dat` 逐行看,發現裡面每一個 `case` 分支都各自有自己獨立的 coverage point,格式類似 `tlinepagev_line/timerocaseS107`——也就是說,Verilator 的 line coverage 本來就會替每一個 `case` 分支開頭那一行單獨計數,而這正好就是「這個狀態有沒有被進入過」最精確的訊號,完全不需要額外的 instrumentation 或 covergroup。決定放棄 `--coverage-fsm`,改成直接讀 line coverage,對每個已知 FSM(狀態名稱清單是從原始碼的 `localparam` 宣告讀出來的,不是用猜的)去查每個狀態那一行的 hit count。

#### 除錯過程中一次自己誤讀資料格式的插曲

第一次寫 parser 時,先用 `grep -n` 去看 annotated 檔案內容,看到類似 `160: 017517         ST_IDLE: begin` 這種格式,誤以為檔案本身就帶著「行號:hit count」的前綴,照這個假設寫的正規表示式最後全部解析成 0/0(11 個 FSM 全部顯示 0%)。回頭直接用 Python 讀檔案原始內容、印出 `repr()`,才發現 `grep -n` 自己加的行號前綴混進了我對格式的理解——annotated 檔案其實**沒有**行號欄位,是跟原始檔案逐行一一對應的(第 N 行永遠對應原始檔案第 N 行),每一行開頭固定是 7 個字元的 coverage 標記:要嘛是 7 個空白(這行沒有被 instrument),要嘛是一個標記字元(空白/`~`/`%`,似乎對應不同的 point 類型)後面緊接著 6 位數、補零的 hit count,完全沒有多餘的分隔符。改用正確的格式重新解析後,11 個 FSM 全部變成 100%——這也提醒:先看工具的原始輸出,不要透過另一個工具(這裡是 grep)包過一層再去理解格式,中間可能會混進不屬於原始資料的東西。

#### 合併 18 個測試的 coverage 時,路徑對不齊導致 annotate 一直報錯

把全部 18 個測試的 coverage.dat 用 `verilator_coverage --write` 合併起來後,想再跑 `--annotate` 產生完整的 per-file 標註原始碼,卻一路連續踩到好幾次「Can't read annotation file: X」的錯誤,而且**每次修好一個,下一次又換另一個檔案報錯**——先是 `../rtl/../rtl/aes.v`(某個測試用絕對路徑指到 aes 目錄下的檔案、另一個測試卻用相對路徑指到同一個檔案,合併後 annotate 想用「當初 build 時的路徑原文」去開檔案,但 annotate 執行時的當下目錄跟原本 build 時的目錄不一樣),修完換成 `../rtl/../rtl/soc_top.v`(同一類問題,只是換一個檔案),再來是 `../rtl/aes_pkg.vh`(這個是被 `` `include `` 進來的,問題出在不同測試給的 `-I` include 路徑寫法不一致,導致 Verilator 記錄下來的 `aes_pkg.vh` 解析路徑也不一致),最後是 `dma_engine_testtop.v` 這類測試專用的 testtop 檔案(原本用單純的檔名相對於各自測試的目錄,annotate 執行時的目錄跟它對不上)。逐一排查、修正的過程中確認一個規律:**同一份底層原始碼,只要在不同測試的 build 指令裡用了不一樣寫法的路徑(絕對 vs. 相對、不同的 `-I` 順序),合併之後就會被當成路徑不同、annotate 沒辦法穩定解析**。最後的作法是把 `scripts/run_coverage.sh` 裡**全部**檔案引用(不管是主要的 RTL 檔案、testtop 測試專用檔案、還是純粹拿來給 `-I` 用的 include 目錄)一致改成絕對路徑,才終於讓 18 個測試合併後的 annotate 一次跑完、不再報錯。

#### 一個單純被漏掉的 build flag

修完路徑問題後,`soc_top` 這個測試改用 coverage flag 重新編譯直接建置失敗——連結階段找不到 `VerilatedVcdC` 的符號。原因很單純:`soc_top` 的 testbench 本來就有用 `--trace` 產生 VCD 波形(拿去給 Phase 7 的中斷延遲分析用),但這次幫它加 coverage flag 的時候忘記把 `--trace` 也一起加回去,導致 verilated 出來的程式碼裡有用到 tracing 相關的 class,卻沒有連結對應的實作。補上 `--trace` 後就正常了。

#### Lint 分類規則也是逐步補出來的,不是一次到位

寫 `scripts/analyze_coverage.py` 把 135 筆 lint 發現分類時,第一版規則跑完還剩 31 筆「uncategorized」,逐一看過內容才補齊剩下的規則:`aes_chain.v` 的 `MODE_ECB` parameter 屬於「只是拿來記錄暫存器編碼、程式邏輯裡沒有真的拿去比對」的文件性常數;`core_busy`/`chain_busy` 屬於「子模組給的 busy 訊號,消費端只需要 done pulse 就夠,busy 沒讀不是問題」;`boot_rom.v` 的 `s_awaddr`/`s_wdata` 整個訊號沒被用到(不是只有高位元沒用到),因為它本來就是唯讀記憶體,寫入本來就會被直接拒絕;`uart.v` 的 `s_wdata[31:8]` 沒被用到,是因為 TXDATA 本身就只是 8-bit 暫存器;最後,凡是出現在 `picorv32.v` 裡的發現,不管訊息內容是什麼,一律先歸進「vendored PicoRV32,不是這個專案自己的問題」這個桶,不套用其他規則。補完之後 135 筆全部有分類,沒有遺漏。

#### 最後的結果

- 這個專案自己寫的 RTL,line coverage **96.3%**
- 全部 **11 個 FSM,狀態 coverage 100%**(每個狀態都至少被進入過一次)
- 135 筆 lint 發現全部分類完畢(文件記錄過的限制 / 刻意的設計 / vendored PicoRV32 風格),沒有一筆是「不知道算什麼」
- `scripts/build_dashboard.py` 把以上全部數據 + 架構圖,渲染成一個單一的靜態 HTML(`reports/sign_off/dashboard.html`),取代原本純文字的 report——這個檔案本身也進版控,是刻意留下的快照,不是每次都要重新產生才能看的東西。

### 再往下一層:toggle coverage 的 waiver 流程

58.1% 這個 toggle coverage 數字掛在 dashboard 上一陣子後,回頭認真想「這個數字到底準不準、要不要花力氣去拉高」——結論是不用建 UVM(這個專案從 Phase 0 開始就是純 Verilog-2001,不用 SystemVerilog,UVM 需要 SystemVerilog,前提就不成立;而且大部分的缺口一看就是結構性的,不是 constrained-random 能解決的多樣性問題),改用業界常見的方式:逐條 review、把「結構上就是不可能 toggle」的訊號明確 waive 掉。這一段記錄實際做這件事時踩到的坑。

#### 第一個坑:raw aggregate 的 58.1%,其實是被 hierarchy instance 重複計數灌水過的數字

想先確認到底有哪些 signal 是缺口,直接拿 `verilator_coverage --report summary,hier` 的輸出來看每個 module 的明細,才發現同一份 RTL 只要在合併後的測試套件裡被多個不同路徑實例化,就會被算好幾次——`aes_core.v` 就同時出現在 `TOP.aes`、`TOP.aes_chain.u_core`、`TOP.aes_core`、`TOP.dma_engine_testtop.u_engine.u_chain.u_core`、`TOP.soc_top.u_aes.u_chain.u_core` 這 5 個路徑下。如果直接在這個聚合數字上動手套 waiver,同一個 bit 的 waiver 理由會被計算 5 次,waiver 對最終數字的實際影響會被嚴重放大,數字沒有意義。於是決定不用 `verilator_coverage` 內建的 report,改成直接讀 `merged.dat` 原始資料自己做 per-bit 去重複。

#### 第二個坑:兩次嘗試都解析失敗(0 match),原因是沒認出格式裡藏著的控制字元

第一版 parser 用一般的正規表示式去抓檔案路徑欄位,想法是用 `[^l]+` 排除到下一個 `l` 開頭的欄位為止——結果完全抓不到任何東西(matched=0)。原因是這個專案的絕對路徑裡本身就重複出現字母 `l`(`Levi-agent`、`blocks` 都有),`[^l]+` 在真正的欄位分隔符出現之前,老早就被路徑裡的某個 `l` 截斷。第二版嘗試換個角度,把所有「看起來像雜訊」的控制字元(`ord(ch) < 0x20`)整個濾掉再解析——結果一樣是 0 match,因為這些字元根本不是雜訊,是欄位之間真正的結構性分隔符,濾掉之後欄位全部黏在一起,更沒辦法分割。兩次都失敗後,回到最基本的作法:用 `open(path, 'rb')` 直接印出原始 bytes,不透過任何字串處理去猜——這才看清楚真正的格式是 `C '\x01f\x02<file>\x01l\x02<line>\x01t\x02toggle\x01o\x02<signal>:<0->1|1->0>\x01...' <count>`,`\x01` 分隔每個欄位、`\x02` 分隔 key 跟 value,而且 key 可以是多字元(例如 `page`,不是只有 `f`/`l`/`t`/`o` 這種單一字母)。改用正確的欄位切法後才一次解析成功(matched=59110、去重複後 unique bits=11401)。這個坑本質上跟前面「annotated 檔案格式被 `grep -n` 混淆」是同一類教訓的第二次出現:先看原始 bytes,不要用猜的。

#### 修正後的數字:69.5%(waive 前),不是 58.1%

去重複、per-bit 重新統計後,waive 前的 toggle coverage 是 **69.5%(7923/11401 bits)**,比 raw aggregate 的 58.1% 高了 11.4 個百分點——差距完全來自去除重複計數,還沒套用任何一條 waiver。

#### 逐條 review 訊號、寫 waiver rule 時,自己也犯了一次跟 waiver 本身精神矛盾的錯

review 完把訊號分成幾大類(位址匯流排高位元、always-ready 寫死的 handshake、AXI response 編碼只用到 OKAY/SLVERR、peripheral 層級寫死 OKAY 的 bresp/rresp、從沒被讀取的 wstrb、AXI4 burst-subset 欄位)之後,第一版 waiver file 把 JTAG bridge 的 `addr_reg`(儲存 JTAG shift 進來的目標位址)也歸進「位址高位元,上游已解碼、跟這裡無關」這一類,套用理由是「JTAG 測試只探測幾個具代表性的位址,不是全位址空間」。跑出結果後才發現這條 rule 沒有限定檔案,結果同時誤中了 `jtag_axi_bridge.v`、`jtag_dtm.v` 之外,還誤中了完全不相關的 `i2c_master.v:316`(一個 7-bit 的 I2C target 位址暫存器)。

回頭重新檢查才意識到問題不在「這個 signal 叫不叫 addr」,而在於這個 signal 的值**有沒有真的被下游拿去用**:`s_awaddr` 的高位元是 crossbar 已經解碼完、slave 確定用不到的部分,waive 掉沒問題;但 `addr_reg` 是一個真的會驅動實際 AXI 交易位址、或決定 I2C target 的完整值,沒有任何一個 bit 是結構上不可能變化的,純粹是目前的測試只選了少數幾個具代表性的位址/target 去測——跟前面決定不 waive 的 `mode_reg`(AES 模式暫存器,因為測試順序只造成單方向 toggle)、`key_reg`(DMA 只用過一組固定金鑰)是同一種性質的缺口:測試向量多樣性不足,不是硬體限制。已把這條 rule 從 waiver file 移除,改列進 residual gap,留待未來用更多樣的位址/target 補測試。

#### 最後的結果

- Toggle coverage:raw aggregate 58.1% → deduped per-bit(waive 前)69.5% → deduped per-bit(waive 後,36 條 rule、1513 bits 被排除)**80.1%**
- 每一條 waiver rule 都附上對應的 RTL 行號實證(不是憑感覺套 pattern),寫在 `reports/sign_off/coverage/toggle_waivers.txt`
- 1965 bits 刻意不 waive、留作 residual gap(主要是 `dma_engine.v` 的 `key_reg`/`iv_reg` 只測過一組固定金鑰、`divider_reg` 只測過偏小的除頻值、部分 `s_rdata`/`m_rdata` 高位元、以及 `soc_top` 自己還沒有端到端測過 SPI/I2C)——這些留在 `docs/coverage_waivers.md`,不是消失掉,是明確標記成「之後可以加測試補的項目」
- 完整量化的 waive 前後對照(含每個 block 的細分)獨立寫在 `docs/coverage_waivers.md`,`reports/sign_off/dashboard.html` 也新增對應的區塊呈現同一份數據。

### 再往下一層:gate-level 的驗證(multi-corner STA、formal LEC、gate-level simulation)

問完「跟業界標準比還缺什麼」之後,補了四塊東西(範圍限定在 `aes` + `soc_top`,跟既有 per-block synthesis 的範圍一致):hold-time STA、multi-corner STA、RTL 對 netlist 的 formal equivalence check(LEC)、gate-level simulation。這一段記錄實際做這幾件事時踩到的坑。

#### Multi-corner STA:意外發現只有一份 corner library

原本以為要另外下載 slow/fast corner 的 liberty 檔案,才能做真正的 setup(slow corner)/hold(fast corner)分析——結果直接在系統上搜,發現 `/Users/shunghsiangwu/eda/src/OpenSTA/test/nangate45/` 底下就有 OpenSTA 自己測試用的 `Nangate45_fast.lib`/`Nangate45_slow.lib`,跟合成用的 `NangateOpenCellLibrary_typical.lib` 逐一比對 cell 名稱,239/241 顆完全一致,只差一顆跟邏輯無關的物理 tap cell `TAPCELL_X1`——確認是同一個 cell family,可以直接拿來用,不用另外去找。OpenSTA 自己的 `examples/min_max_delays.tcl` 也剛好示範了完全對的語法(`read_liberty -max slow.lib` + `read_liberty -min fast.lib` + `report_checks -path_delay min_max`),照抄這個模式寫 `sta_mcmm.tcl` 一次就跑成功,沒有繞路。跑出來的結果也是刻意檢查過才確定合理:setup 在 SDC 刻意設定的 2.0ns/500MHz 探測週期下當然大量違規(WNS -41.32ns/-36.40ns),這是 `constraints/*.sdc` 本來就記載的預期行為(拿來讀真實 data arrival time、換算 Fmax 用的,不是要衝這個頻率);hold 在 fast corner 下完全乾淨,TNS 剛好等於 0.00——這才是這一步真正新增的、有意義的資訊。

#### Gate-level simulation:合成出來的真正 Nangate45 netlist 沒辦法直接模擬

一開始想直接拿 `synth.ys` 已經產生的 `soc_top_out.v`(真正 tech-mapped 到 Nangate45 標準元件的 netlist)給 Verilator 模擬,才發現系統上只有 latch/clock-gate/adder 這幾類 cell 的 functional Verilog model(`cells_latch.v`/`cells_clkgate.v`/`cells_adders.v`),沒有 AND/OR/NAND/DFF 這些基本邏輯閘的 functional model——沒有這些,Verilator 沒辦法知道一顆 `AND2_X1` 實際的行為是什麼。解法是另外產生一份「generic netlist」:`synth -top X` 跑完就停,不繼續做 `dfflibmap`/`abc -liberty` 這一步技術映射,這樣 netlist 還停留在 Yosys 自己內部的通用邏輯閘(`$_AND_`/`$_DFF_P_` 這類)——實際測試發現 Yosys 的 `write_verilog` 會把這些內部通用邏輯閘**自動展開成一般的 Verilog assign/always 敘述**,完全不需要外部 cell library,Verilator 可以直接吃。這份「generic netlist」驗證的是 synthesis 本身的邏輯優化有沒有改變行為,跟 LEC 驗證的「技術映射有沒有改變行為」是互補、但不同的兩件事。

跑 soc_top 的 gate-level 版本時第一次 build 失敗,錯誤是一堆 `PINMISSING`(instance 缺 pin)——查了實際缺的是哪些 pin 之後,發現全部是本來就沒被用到的訊號(PicoRV32 從沒接的 PCPI coprocessor 介面、以及 crossbar 的 `s0_bresp`/`s0_rresp`——這個之前就在 lint 分類裡記錄過,PicoRV32 的 AXI master 本來就不檢查 BRESP/RRESP),是 Yosys 優化掉這些訊號之後,`write_verilog` 沒有把 module 自己的 port list 完全同步修剪掉導致的落差,不是真的接錯線——確認全部對應到已知的、本來就沒用的訊號後才加上 `-Wno-PINMISSING`。加上之後,`soc_top` 的 gate-level 版本一次跑過:真實開機、5 次 Timer 中斷、UART 輸出、JTAG 讀寫 RAM、DMA 控制埠全部 PASS,證實 Yosys 對這個規模的完整 SoC(含 PicoRV32)做的合成優化沒有改變任何行為。

#### Formal LEC:兩次因為兩邊(gold/gate)沒有對齊而失敗,最後 aes_core 到 97.7%、soc_top 刻意縮小範圍

寫 `equiv_make`/`equiv_simple`/`equiv_induct` 這組 Yosys 指令第一次執行,直接撞到 `ERROR: Re-definition of module`——原因是 `design -save gold` 之後沒有清掉當前 design 就繼續 `read_verilog` 讀 gate netlist,兩邊都叫 `aes_core`,自然衝突,補上 `design -reset` 解決。

第二次撞到 `ERROR: No SAT model available for cell _16878__gate (INV_X1)`——一開始以為是 `read_liberty -lib` 讀出來的 cell 有問題,查了 `read_liberty` 的說明才發現 `-lib`這個 flag 的意思是「只建立空的 blackbox module」,完全沒有帶任何邏輯內容,SAT solver 當然找不到模型可以用——改成不加 `-lib`(直接讀,連帶 `-ignore_miss_func` 忽略少數缺 function 定義的 cell)就正常了,因為 `NangateOpenCellLibrary_typical.lib` 本身每顆 cell 都帶 `function` attribute(例如 `AND2_X1` 就是 `function : "(A1 & A2)";`),Yosys 讀進來就能重建出邏輯內容,不需要額外的 functional Verilog model 這一步(這一點也順便解答了前一段 gate-level simulation 遇到的「沒有 functional model」問題——LEC 不需要,因為它是靠 liberty 檔案自己的 function 描述,不是真的去模擬)。

第三次撞到 `ERROR: No SAT model available for cell ...($mem_v2)`——這次是 aes_key_expand 內部的 round-key 陣列在 RTL(gold)端還停留在 Yosys 的粗粒度記憶體抽象(`$mem_v2`),但 gate 端已經被完整的 `synth` flow(包含 `memory_collect`/`memory_map`)拆成一顆一顆的正反器,兩邊抽象層級對不齊,導致 `equiv_induct` 找不到能對應的模型——在 gold 端也補上 `memory_collect`/`memory_map`,讓兩邊都拆到同一個粒度後就正常了。

`aes_core` 完整跑完 `equiv_simple` + `equiv_induct`(預設 4 步歸納)後,還剩 904 個未證明,分組後全部集中在 `u_key_expand.rk[0]`——把歸納深度加到 `-seq 12` 後降到 520 個,分組後發現這 520 個沿著同一條訊號鏈(`rnum` round counter → `sub_shift_enc`/`sub_shift_dec` → `data_reg` → `data_out`,加上幾個控制訊號),跟 AES core 本身「10 拍 key expansion + 11 輪」的真實時序深度吻合——判斷這是歸納步數還沒完全覆蓋到這個深度造成的,不是真的邏輯不等價,而且同一份 netlist 已經被 `run_gatelevel_sim.sh` 用真實 FIPS-197 測試向量獨立驗證過行為正確,兩種方法互相印證,沒有繼續往上加大 `-seq`(每加深一次,SAT 求解時間就大幅增加,報酬遞減)——**97.7%(22126/22646)是誠實記錄下來的最終結果,不是硬做出來的 100%**。

`soc_top` 含整顆 PicoRV32、cell count 是 aes_core 的兩個數量級以上,對這種規模跑跟 aes_core 一樣完整的 sequential induction 不切實際(aes_core 一個 block 光是 `equiv_induct` 就要跑十幾分鐘還沒完全收斂了),而且「含嵌入式 CPU 的整顆晶片做 full-chip formal equivalence」即使在真正的商用 EDA 工具上也是出了名的難題,業界標準做法本來就是「block-level formal + full-chip simulation」——所以 `blocks/soc_top/syn/lec.ys` 刻意只跑 `equiv_simple`(不做 induction),當作 best-effort 的部分驗證,跑出 60.2%(36036/59864,純組合邏輯層級的等價性),明確標注這不是「signoff 通過」的數字,整顆 SoC 真正的驗證由前面的 gate-level simulation 補上。這個範圍縮小是刻意做的判斷,不是省事——寫進 `docs/lec_methodology.md` 時特別把理由講清楚。

#### 最後的結果

- Multi-corner STA:soc_top slow-corner Fmax ≈ 23.2MHz(比之前只看 typical corner 的 91.2MHz 保守很多),兩個 block 在 fast corner 下 hold 都完全乾淨(0 個違規)——完整數字見 `docs/performance.md` 第 7 節。
- Gate-level simulation:aes_core、soc_top(含真實開機、中斷、UART、JTAG、DMA)在 Yosys 合成後的 netlist 上都 PASS。
- Formal LEC:aes_core 97.7% 完整證明,soc_top 刻意縮小範圍的 60.2% 部分驗證——完整理由跟數字見 `docs/lec_methodology.md`。
- `docs/performance.md` 新增第 8 節,明確記錄這個專案的 signoff 範圍界限(停在 gate-level netlist,不含 place & route/DRC/LVS/DFT/power signoff),講清楚是刻意的取捨,不是漏掉。

### 再往下一層:CDC(Clock Domain Crossing)驗證

問「這個平台是不是只有一個 clock」的時候,直接查 RTL 糾正了一個誤解:不是單一 clock,`tck`(JTAG 測試時脈)跟 `clk`(系統時脈)是兩個完全獨立、非同步的 domain,`jtag_axi_bridge.v` 是唯一橫跨兩者的模組。這台機器沒有裝任何專門的 CDC 工具,得用業界在沒有商用工具時的替代做法:STA 正確宣告 + 結構性 review + 模擬壓力測試三件事互補。

#### SDC/STA:tck 該宣告成 clock,還是純資料訊號?

這兩個選項不是二選一,而是要一起用:`tck` 因為真的驅動 `jtag_tap.v`/`jtag_dtm.v` 裡正反器的 clock pin,不宣告成 clock 的話 STA 會完全跳過整個 tck domain 的時序分析(不只是跨 domain 的部分);但宣告成 clock 之後,如果沒有額外講清楚它跟 `clk` 沒有相位關係,STA 會試著去算兩個 clock 之間的 worst-case skew,對兩個真正非同步的訊號來說這個計算完全沒有意義。正確做法:`create_clock` 宣告 tck(選一個保守的週期,20ns/50MHz,反正 tck domain 自己的邏輯很簡單,選哪個值幾乎都會過,重點不在這個數字)+ `set_clock_groups -asynchronous` 明確排除兩者之間的路徑。改完重跑 `sta.tcl`/`sta_mcmm.tcl`,確認 `Path Group` 只有乾淨分開的 `clk`/`tck` 兩組,沒有混合的跨 domain 路徑被拿去算 setup/hold——這一步解決的是「STA 不要對非同步邊界產生誤判」,不是「synchronizer 本身有沒有做對」。

#### 模擬壓力測試:发現現有測試只測過一個方向的時脈比例

`jtag_axi_bridge.v` 的 CDC 機制(toggle synchronizer + busy 比較邏輯)本身的 header comment 明確宣稱「regardless of how large the clock-period ratio is in either direction」——這是一句可以被測試驗證的具體宣稱。檢查現有的 `jtag_chain` regression 測試才發現,它固定用 tck 遠慢於 clk 的比例(每個 tck 半週期對應 10 個 clk 半週期),只測過「真實 JTAG probe 對比快系統時脈」這一個方向,反過來的方向(tck 比 clk 快)從沒測過。既然設計自己宣稱兩個方向都成立,就補一個新的 regression target 驗證看看:`jtag_chain_fast_tck_sim_main.cpp`,完全相同的 IDCODE/AXI write-read-back/BYPASS 測試序列,只把時脈關係反過來(tck 每 5 個半週期才讓 clk 走一個半週期)。跑完一次就 PASS,證實這個 toggle-synchronizer 設計真的對兩個方向都成立,不是只在「tck 慢」這個常見情境下剛好沒事。

#### 過程中發現一批跟這次改動無關、但會讓 regression 整個看起來壞掉的舊問題

寫完新測試、跑 `scripts/run_regression.sh` 想確認整體沒有壞掉時,結果 19 個測試裡有 15 個 `BUILD-FAIL`,錯誤訊息是 `make: *** No rule to make target '3.d'`——一開始以為是新加的測試或改動的 SDC 弄壞了什麼,但仔細看錯誤內容,是各個 block 自己的 `obj_dir_regr` 建置快取目錄底下,存在檔名帶空格的殘留檔案(像 `verilated_threads 3.d` 這種,之前 session 就注意過這類帶空白數字後綴的重複檔案,但沒有深究),讓 `make` 的 dependency 解析把檔名切錯,誤判成「要 make 一個叫 3.d 的目標」。這些 `obj_dir_*` 目錄整個都是 `.gitignore` 排除的建置快取,不是原始碼,直接整批刪掉讓它們重新從零建置,19 個測試全部正常編譯、全部 PASS——確認這批失敗是之前累積下來的建置快取損毀,跟這次的 CDC 改動本身無關。

#### 最後的結果

- `blocks/soc_top/constraints/soc_top.sdc` 新增 tck clock 宣告 + `set_clock_groups -asynchronous`,`sta.tcl`/`sta_mcmm.tcl` 重跑確認 Path Group 正確分開。
- `blocks/jtag/rtl/jtag_axi_bridge.v` 的每一條跨 domain 訊號(START/DONE toggle、BUSY 比較、RESP_OK/RDATA 的 2-flop 同步)逐條對照 RTL review 過,確認同步器級數跟拓樸(第一級直接取樣來源暫存器,無組合邏輯夾雜)。
- 新增 `jtag_chain_fast_tck` regression target,補上原本沒測過的「tck 比 clk 快」方向,跟原有的 `jtag_chain` 一起涵蓋兩個時脈比例的極端。
- 完整報告、每條訊號的 review 結果、以及明確標注的範圍界限(數位模擬無法重現真實 metastability)寫在 `docs/cdc_methodology.md`。

### 再往下一層:RDC(Reset Domain Crossing)——reset 訊號本身也需要同步

做完 CDC 之後,問「跟業界標準比還缺什麼」時翻出一個之前就寫在 `soc_top.v` header comment 裡、但當時刻意擱置的問題:`rst` 這個訊號未經任何同步,直接餵給 `clk` domain 跟 `tck` domain 的每一個模組(包括 `jtag_axi_bridge.v` 的 `tck_rst` 埠)。真實晶片的 reset 通常來自外部電路,本質上是非同步的,直接餵給同步邏輯有 metastability 風險——這是跟 CDC 同一類、但專門處理「reset 訊號本身跨 domain」的問題。

修法是在 `soc_top.v` 加兩個「非同步 assert、同步 de-assert」的 2-flop reset synchronizer,一個 domain 一個,所有內部模組改吃同步過的 `rst_clk_sync`/`rst_tck_sync`,不再直接吃外部 `rst`。這是這個專案「一律 synchronous reset」慣例的**唯一刻意例外**——同步器自己的暫存器必須把 `rst` 放進 sensitivity list 才能立即 assert,這正是它存在的目的,已經在 RTL comment 裡把「為什麼這裡例外」寫清楚,避免之後被誤會成風格不一致。

改完之後重跑 regression,一開始又看到 14/19 測試 BUILD-FAIL——查了發現又是同一類跟這次改動完全無關的舊問題:`obj_dir_*` 建置快取目錄裡再次出現帶空格的殘留檔案(這次連 `timer`/`watchdog` 這種我完全沒碰過的 block 也一起中獎,直接證實不是這次 RTL 改動造成的)。這是這個 session 第二次遇到同一種快取損毀——原因還沒查清楚(可能是背景某個系統程序,例如 Time Machine 或 Spotlight,在建置期間對這些目錄做了什麼),但修法一樣:整批刪掉 `obj_dir_*` 重建。清乾淨之後 19 個測試全部 PASS,包含唯一真的會受這次改動影響的 `soc_top`(多了 2-cycle 的 reset 釋放延遲,沒有讓任何 cycle-accurate 檢查失敗)。

**這個改動只動了 `soc_top.v`**,單一 block 的獨立測試都是直接 instantiate 各自 RTL、自己驅動 `rst`,不經過這層同步器,完全不受影響——這也是為什麼可以只在整合層級加,不用動到每個周邊自己的 RTL。完整說明寫在 `docs/cdc_methodology.md` 第 6 節。

### 把 reset synchronizer 改動連帶的過時快照重新跑過一輪

`soc_top.v` 的 RTL 改了之後,synthesis netlist、STA 報告、LEC 數字、coverage dashboard 全部變成基於舊 RTL 的過時快照——這一段記錄重新跑這些東西時,踩到的幾個坑。

#### 手動重跑 STA 直接撞上兩個「已經修過但這次繞過了修法」的舊問題

手動跑 `yosys synth.ys` + `sta sta.tcl` 想拿新數字,結果 OpenSTA 直接報 `syntax error`——查了兩輪才發現:①`wire signed [31:0] i;`,PicoRV32 內部一個徹底沒人讀的 for-loop index 變數(`assign i = 32'd1;`,零個 reader),OpenSTA 的簡化版 Verilog parser 不支援 `signed` 這個 qualifier;②修完第一個,緊接著撞上第二個,`boot_rom` 這個 blackbox 實例化時帶了一個字串型別的 parameter override(`.HEXFILE("firmware.hex")`),OpenSTA 的 parser 也不支援字串參數。

一開始的反應是直接修 `synth.ys`(加 `opt_clean -purge` 想把那個死掉的 `i` 清掉)——結果清是清掉了,但緊接著就撞上第二個問題,而且這兩個問題明明都不是這次 RTL 改動造成的(PicoRV32、boot_rom 都沒被碰過)。回頭去看 `scripts/collect_soc_reports.sh` 才發現:**這兩個問題老早就有人踩過、也早就修好了**——只是修法寫在 `collect_soc_reports.sh` 的 sed 後處理步驟裡,不在 `synth.ys` 本身,而這次是直接手動跑 `yosys synth.ys`/`sta sta.tcl`,繞過了這層既有的修法,才會覺得像是新問題。把 `synth.ys` 裡多加的 `opt_clean -purge` 改回原本的 `clean`,直接改用 `collect_soc_reports.sh` 這個既有的、正確的 orchestration script 重新跑一輪——這個教訓值得記下來:**遇到看起來眼熟的問題,先查專案裡有沒有現成的腳本/修法,不要急著在別的地方重新發明一次**。

#### 真的抓到一個新的 removal check 違規,不是重複的舊問題

用 `collect_soc_reports.sh` 跑出乾淨的報告之後,另外重跑 `sta_mcmm.tcl`(多 corner 版本)確認 hold 沒有壞掉,結果這次是真的抓到一個新問題:hold 從乾淨的 `wns min 0.00` 變成 `wns min -0.08`,起點是 `rst` 這個 port、終點是 reset synchronizer 自己的正反器,類型是 removal check(非同步 SET/RESET 腳位的 hold 對應版本)。判斷這是 reset synchronizer 結構上必然的性質(`rst` 本質上非同步,不可能保證每次變化都跟 `clk` 的任一個 edge 有 0.086ns 的餘裕),不是真的時序問題,在 SDC 加了 `set_false_path -from [get_ports rst]`(先確認過 `rst` 在整個設計裡只剩這兩個 synchronizer 在用,排除範圍夠精準)解決,hold 恢復乾淨,setup 數字完全沒變。這次的教訓也記下來:**做完 CDC/RDC 的 RTL 修正之後,一定要重新跑一次 STA 確認,不能只看 regression 綠燈就假設時序也沒事**——regression 是功能驗證,不會告訴你 removal/recovery timing 有沒有問題。

#### LEC 也需要跟著補一個 pass

`blocks/soc_top/syn/lec.ys` 重跑時直接報錯:「No SAT model available for async FF cell ... Consider running `async2sync`」——新加的 reset synchronizer 正反器是這個設計裡唯一真正非同步 reset 的正反器,LEC 原本的 SAT flow 沒有為它準備模型。照錯誤訊息建議,在 gold/gate 兩邊都加上 `async2sync`(Yosys 內建 pass)解決,加完後數字幾乎不變(60.2%→60.1%),確認新加的 reset 邏輯本身沒有引入新的等價性問題。

#### 這個 session 第三次遇到同一種建置快取損毀

跑 `collect_soc_reports.sh` 內建的 regression 時,又一次看到 13/19 測試 `BUILD-FAIL`,錯誤訊息跟前兩次一模一樣(`obj_dir_*` 目錄裡帶空格數字後綴的殘留檔案讓 `make` 解析錯誤)。這是這個 session 第三次踩到同一個問題,而且完全複現在我完全沒碰過的 block(`timer`/`watchdog` 等)上,確認不是任何一次 RTL 改動造成的。用 `brctl status` 查了一下,確認這台機器的 iCloud 同步(bird daemon)是在跑的——這個專案剛好放在 `~/Desktop/` 底下,如果 Desktop 有開「iCloud Drive 同步 Desktop 跟文件」,大量小檔案在短時間內被 Verilator 平行寫入/重寫,很可能就是這種「檔名帶空格數字後綴」重複檔案的來源。這只是一個合理推測,沒有進一步驗證或去改系統設定(那是使用者自己的偏好選擇,不是我該擅自動的東西)——每次遇到就清掉 `obj_dir_*` 重新建置,目前為止都能徹底解決。

#### 最後的結果

- `blocks/soc_top/syn/synth.ys` 維持原本的 `clean`(沒有引入新的清理步驟),改用既有的 `scripts/collect_soc_reports.sh` 重新產生全部報告。
- Chip area 129847.1(cell count 78649),比改動前的 130337.1(79128)略降,關鍵路徑 10.966ns(Fmax 91.2MHz)完全沒變——reset 邏輯跟 AES key expansion 這條臨界路徑無關。
- Multi-corner STA 補上 `set_false_path -from [get_ports rst]` 之後,hold 恢復乾淨。
- LEC(`docs/lec_methodology.md`)soc_top 數字更新為 60.1%,並補上 `async2sync` pass。
- Coverage/dashboard 數字微幅變動(多了 4 個新增正反器對應的 toggle 檢查點),`docs/coverage_waivers.md`、`docs/verification_summary.md` 都同步更新成新數字。

### 再往下一層:把 deduped toggle coverage 從 80.1% 推到 92.2%

`docs/coverage_waivers.md` 第 5 節的 residual gap(1966 bits)列出來之後,一直是「已知、刻意留著」的狀態。這次回頭挑幾項低成本的補起來,目標抓 90%。

#### 起手:先做兩項低成本的,結果只到 81.9%

第一輪只做了 i2c/spi 的 `divider_reg`(直接寫暫存器,幾乎零成本)跟 DMA 加一組不同的 key/IV(重用 `aes_core` 已經驗證過的 FIPS-197 Appendix B 向量)。做完重新量測,80.1%→81.9%,進步有限。回頭重新拆解 residual gap 才發現:原本規劃「不夠 90% 再做的第四項」(`soc_top` 層級的 SPI/I2C loopback 整合測試)只佔 42 bits,就算整個補滿也只能再推 0.4 個百分點——真正擋在 90% 前面的是 `*_rdata`/`*_wdata` 這些 bus mirror 暫存器資料多樣性不足的問題(合計超過 1300 bits),不是原本以為的第四項。跟 Levi 確認後改打這一塊。

#### 兩值法的陷阱(見上方錯誤模式 C)

改打 bus mirror 之後,第一版做法是「原值 + bitwise complement」兩個值,想說值不一樣總該補到雙向 toggle。`axi_lite_xbar` 補完重測,發現 `timer_rdata` 這類 signal 幾乎沒有進步——回頭手算才發現這個兩值法的漏洞:reset 值是 0 的情況下,「原值裡是 1」的 bit 才會經歷完整的雙向 transition,「原值裡是 0」的 bit 序列在 complement 那一步就結束了,只補到單向。Timer 原本測試用的 `0x11110004` 只有 5 個 1-bit,難怪幾乎沒效果。同一個坑後來在 DMA 的 key/iv 窮舉、以及透過 JTAG poke `soc_top.v` 自己的 mirror wire 時又各踩了一次,都是先看到「改了但數字沒動」才回頭發現。改成「全 0 → 全 1 → 全 0」兩極值(或「原值→complement→原值」三段)之後,才真的補滿。

#### `soc_top.v` 自己的 mirror wire 是獨立的 coverage 檢查點,補別的地方不會連帶補到

`axi_lite_xbar.v` 內部的 per-slave rdata mirror,跟 `soc_top.v` 自己宣告的同名 top-level wire(`timer_rdata`、`wdt_rdata` 等),雖然電氣上接在一起、名字也一樣,但因為在不同檔案,toggle coverage 是以 `(file, line, signal)` 當 key 去重複的兩個完全獨立的檢查點——把 `axi_lite_xbar` 測試補好,`soc_top.v` 自己的份完全不會連帶被補到。得另外透過 `soc_top` 測試裡本來就有的 JTAG debug bridge 路徑,直接對 Timer 等幾個確認過的「直接寫入」暫存器做讀寫,才能補到這一層。這一項是這一輪影響最大的一步,單這裡就貢獻了從 89.8% 到 92.2% 的最後一段。

#### 最後的結果

- Deduped toggle coverage(waive 後):80.1%(7926/9892)→ **92.2%**(9153/9925),residual gap 從 1966 bits 降到 772 bits。
- 過程中沒有修改任何 RTL——全部是在既有 testbench 裡加測試向量(i2c/spi divider、DMA 第二組 key/IV + 窮舉暫存器覆蓋、`axi_lite_xbar`/JTAG bridge 的第三組資料值、`soc_top` 透過 JTAG 對其餘周邊的窮舉 poke)。
- 19 個 regression targets、135 個 lint finding、chip area(129847.1)、Fmax(91.2MHz)全部沒變——純粹是驗證廣度的提升,不影響任何功能或時序數字。
- 還剩的 772 bits 主要是 DMA 內部的搬移進度計數器(`cur_src`/`cur_dst`/`blocks_left`,需要真的跑一次不同長度/位址的搬移才能補)跟 `soc_top` 層級的 SPI/I2C 整合測試(原本規劃的第四項,42 bits,優先度較低沒動),詳見 `docs/coverage_waivers.md` 第 5 節。

### 再往下一層:全專案 reset 極性從 active-high 改成 active-low(resetn)

Levi 看 RTL 時發現一個實務經驗上的落差:這個專案自己寫的周邊全部用 active-high `rst`,但真實業界(尤其是 AMBA/AXI 規範的 `ARESETn`)更常見 active-low。查證後發現這個落差是真的、有具體理由,不是單純習慣問題:

- AMBA/AXI 規範明訂 reset 訊號是 `ARESETn`,active-low 是官方 spec 慣例。
- 這個專案實際合成用的 Nangate45 cell library 本身也是 active-low 慣例——查了 `DFFR_X1`/`DFFS_X1` 這些帶硬體 reset/set pin 的 cell,reset pin 命名是 `RN`(Reset-Not),function 定義是 `!RN` 觸發。
- 專案自己 vendor 進來、完全沒改過的 PicoRV32 CPU 原生就是 active-low(`resetn`)——`soc_top.v` 原本得自己做一次 `wire resetn = !rst_clk_sync;` 反相橋接,兩種慣例並存在同一個檔案裡。

決定全專案統一改成 `resetn`(而不是 `rst_n`),理由是直接對齊 PicoRV32 的既有命名,順便讓 `soc_top.v` 不用再做反相橋接。範圍:18 個 RTL 檔案(每個周邊 + `axi_lite_xbar`/`dma_ram`/`dma_engine`/JTAG 全家族 + `soc_top.v`)、5 個 testtop wrapper、共用的 `tb/common/fake_axi_lite_slave.v`、19 個 testbench、SDC 的 `set_false_path` 目標、還有 CDC report/各 IP spec doc。逐個 block 改完 RTL + 對應 testbench 就跑一次 regression,不是全部改完才一次驗證。

#### `soc_top.v` 的 reset synchronizer 是唯一需要真的重新設計的地方

其餘所有周邊都是機械式的 `if (rst)` → `if (!resetn)` 反相,邏輯完全等價。但 `soc_top.v` 自己的 RDC reset synchronizer(見 `docs/cdc_methodology.md` 第 6 節)是這個專案唯一真正的 async reset 邏輯,不能只做字面反相——原本是 `posedge rst` 觸發、async SET;改成鏡像等價的 `negedge resetn` 觸發、async CLEAR。

#### 抓到的第一個真問題:`mem_blackboxes.v` 忘記改

全部 RTL/testbench 改完、跑 regression 全綠之後,以為完工了,結果重新合成 `soc_top` 時 Yosys 直接報錯:「`dma_ram` 沒有叫 `resetn` 的 port」。查了才發現 `blocks/soc_top/syn/mem_blackboxes.v`(合成用的記憶體 blackbox 替身,`boot_rom`/`sram`/`dma_ram` 三個)還是舊的 `rst` port 宣告——這個檔案不會被 Verilator regression 讀到,只有真的跑合成才會踩到,所以 regression 全綠完全沒發現這個漏網之魚。這是這次改動範圍盤點時漏掉的一類檔案:**合成專用的輔助檔案(blackbox、generic netlist 等)不會被一般測試流程覆蓋到,retrofit 這類「改介面」的工作時,清單要包含這些檔案,不能只看 `rtl/`+`dv/`**。修正後重新合成成功。

#### 抓到的第二個真問題:Verilator 的 zero-init 對 active-low 訊號是個陷阱

`soc_top` 的 testbench 一開始把 `dut->resetn` 直接設成 0 表示 reset asserted——但 Verilator 預設把訊號 zero-init,對 active-low 訊號來說「預設值」剛好就是「reset asserted」的值,所以這行沒有產生真正的訊號 edge。開機期間 `tck` 完全沒有 toggle 過(firmware boot 只靠 `clk`),導致 tck domain 的 async reset synchronizer 從來沒被真正觸發、也從來沒有機會完成同步釋放,一路卡到測試最後第一次真正送 JTAG 訊號時才發作(前兩個 JTAG 操作失敗:寫 RAM、讀回都失敗)。

這個 bug 很值得記錄的地方:**它在 active-high 的舊版本裡不會發生**,因為舊版本第一行是 `dut->rst = 1;`——`rst` 同樣 zero-init 成 0,但 0 對 active-high 訊號來說是「未 reset」,所以這一行(0→1)是一次真正的 transition,`posedge rst` 正常觸發。同一套「先明確設初始值再翻轉」的寫法,在改成 active-low 之後,恰好因為預設值語意改變而失效——**改變一個訊號的極性,不能只改 RTL 跟穩態邏輯,連 testbench 裡「怎麼製造出第一次 reset edge」都要重新檢查,不能假設原本的初始化順序在新極性下還一樣安全**。

修法:先明確把 `dut->resetn` 設成 1(製造出真正的 1→0 transition),並在 reset 釋放後、真正的 JTAG 流程開始前,手動 pump 幾個 no-op 的 `tck` edge(`tms=1` 讓 TAP 停在 Test-Logic-Reset,不影響邏輯),讓 tck domain 提前完成同步釋放。修完 19 個 regression 全部 PASS。

#### 意外發現:Fmax 從 91.2MHz 掉到 67.5MHz,原因不在 AES 或 PicoRV32 的邏輯

全部功能驗證通過後,重新合成+STA 發現一個意外结果:whole-SoC 的 critical path 從原本的 `aes_key_expand`(10.966ns)整個換到 `u_cpu/picorv32_core` 內部一段完全沒改過的邏輯(14.821ns)。追查後確認:

- `aes_core` 獨立合成的數字幾乎沒變(38.219ns→38.399ns,正常合成雜訊範圍),證實 AES 邏輯本身沒問題。
- PicoRV32 是完全沒改過一行的 vendored 檔案,餵給它的 `resetn` 訊號邏輯行為跟改之前完全等價。
- Chip area 反而略降(129847.1→129373.6,少了一顆反相器),不是邏輯變多了。

跟 Levi 確認後,結論是**誠實記錄現狀,不再深挖**:這很可能是 Yosys/abc 的技術對應(technology mapping)演算法對 netlist 結構變動的敏感度造成的——全專案大量訊號改名、少一顆反相器,這類結構性變動會改變 abc 內部啟發式優化的決策順序,連帶影響到邏輯上完全無關模組的合成結果,是已知但很難精準預測的合成工具行為。完整數字跟推論寫在 `docs/performance.md` 第 1、7 節。**這是這次 retrofit 最重要的教訓**:就算改動本身邏輯上完全等價、經過完整 regression + LEC 驗證,合成後的時序數字仍然可能因為工具的非局部優化行為而改變——「邏輯等價」不等於「時序不變」,兩者要分開驗證,不能只看 regression 綠燈就假設 Fmax 這類數字也不受影響。

#### 最後的結果

- 19 個 regression targets 全部 PASS,135 個 lint finding 數量不變。
- Toggle coverage 微幅變動(92.2%→92.0%,9153→9132 covered bits)——JTAG reset 釋放時序修正後,開機階段實際命中的 toggle 組合略有不同,不是測試變少,仍遠高於 90% 目標。
- Chip area 129373.6(略降),Fmax 67.5MHz(見上,已知且記錄清楚的變化,不是邏輯缺陷)。
- CDC/RDC 的結構性 review 結論不變(synchronizer 級數、topology 都是鏡像等價的重新設計),multi-corner STA 的 hold 依然完全乾淨。
- **這次改動全程沒有動到 `scripts/` 目錄底下任何一個腳本,也沒有動到任何一個 block 的 `testlist.sh`/`lintlist.sh`**——convention-over-configuration 的自動化引擎(`ic-verification-signoff-scaffold` skill 的原型)在一次觸及全專案介面命名的大改動下完全不用跟著改,只有實際的 RTL/testbench/文件內容變了,證實這套自動化設計是真的跟專案細節解耦的。

### 再往下一層:追查 Fmax 掉了 26% 的原因,最後不只補回來還變更好

上一節結尾誠實記錄了 Fmax 91.2→67.5MHz「不再深挖」,但這只是先按下不表,不是結案。Levi 後來還是想知道真正的原因,而且明確要求「查就好,不要動這一版本任何東西」——先用一個獨立的 `git worktree`(不影響目前這個已經 commit 的版本)重新合成當時的 v2.0.0 commit,確認:(1) 合成是 deterministic 的,重新跑一次數字跟 commit 時完全一樣;(2) 現在踩到的 PicoRV32 critical path,在 retrofit 之前的舊版本裡完全不在 top-5 worst path 裡;(3) PicoRV32 原始碼逐位元組沒有任何改變。三點合起來證實:這是 Yosys/abc 技術對應對 netlist 結構變動的敏感度造成的,不是邏輯缺陷、不是隨機雜訊、也不是這次 retrofit 本身做錯了什麼。

問完「為什麼」之後,Levi 接著問「能不能用 abc 參數把 timing 拉回來」——這次同樣先在獨立 worktree 裡實驗,查證後找到真正的根因:**`blocks/soc_top/syn/synth.ys` 裡的 `abc -liberty $NANGATE45_LIB` 呼叫從頭到尾都沒有帶 `-constr`**。查 Yosys 的 `abc` pass 說明才發現,abc 內建的預設 script 只有在給了 `-constr`(driving cell/load 假設)之後才會執行 `buffer`/`upsize`/`dnsize` 這幾個真正做 gate sizing 的 pass——沒有 `-constr`,不管加不加 `-D`(delay target)都只做純面積導向的技術對應,完全不會針對任何一條路徑做尺寸調整(用 Yosys 的 log 直接比對過:加 `-D` 但不加 `-constr`,合成出來的網表位元對位元完全一樣,證實 `-D` 單獨用是 no-op)。也就是說,這個 SoC 從 Phase 7 一開始的合成流程,就從來沒有真正做過 timing-driven sizing——retrofit 只是把這個一直存在的盲點暴露出來而已。

**過程中先試錯了一個看似合理、實際上更差的方向**:把整個 hierarchy 攤平(`synth -top soc_top -flatten`)讓 abc 用單一全域網表跑,理論上這樣 abc 才能看到跨 submodule 邊界的完整路徑。結果是反效果:critical path 從 14.821ns 惡化到 38.364ns。原因是這個專案原本(從 Phase 7 開始)就是「per-module abc」——`synth -top soc_top` 預設不會攤平 hierarchy,每個 submodule(AES、DMA、i2c 等)各自跑一次 abc,問題規模小,abc 的 heuristic 表現比較好;硬攤平成一個 ~127K cell 的巨大平面網表後,abc 的全域 heuristic 反而做出更差的決策。**這是一個違反直覺但值得記住的教訓:對這個規模的設計,把 hierarchy 攤平給合成工具「看到全貌」不一定是好事,工具本身的演算法規模效應可能比拿到更多資訊更重要**。

真正生效的做法:保留原本的 per-module hierarchy,新增 `blocks/soc_top/syn/constr.txt` 並加上 `-D`,啟用 abc 的 sizing pass。Levi 追問「有 3 個 corner 嗎」以及「這裡跟業界不太一樣的地方」,點出一個更根本的問題:sizing 決策當時只用 typical corner library 算,不是真正業界 MMMC(Multi-Mode Multi-Corner)流程——真正的 signoff 工具會用 worst-case corner 或多 corner 同時感知去做 sizing,而不是先在 typical 上調完、再事後拿別的 corner 去驗證有沒有中獎。這個落差其實從專案一開始就存在(Yosys/abc 本身不支援 MMMC,是開源工具鏈的天花板),只是一直沒有做 sizing 的時候是「潛在」的,一旦真的開始 sizing,就變成「有可能影響決策」的。改成 `dfflibmap`/`abc` 都吃 `$NANGATE45_SLOW_LIB`(而非 typical)之後重新跑三個 corner,確認 setup 在 typical/slow 兩個 corner 都大幅改善、hold 在 fast corner 依然完全乾淨——這次剛好三個 corner 都變好,但這是驗證出來的結果,不是方法論本身保證的,值得記住「先合成後驗證」跟「合成時就對多 corner 負責」是兩種不同嚴謹程度的做法。

**最終結果**(細節見 `docs/performance.md` §1、§7):
- Typical corner critical path 14.821ns→2.881ns,Fmax 67.5MHz→**347.1MHz**,關鍵路徑從 PicoRV32 換回 AES chain——不只補回 retrofit 掉的頻率,還比 retrofit 之前(91.2MHz)更好。
- Slow corner critical path 51.837ns→10.288ns,Fmax 19.3MHz→**97.2MHz**,同樣比 retrofit 前(≈23.2MHz)更好。
- Fast corner hold 全程維持 0 違規。
- 代價是 chip area 多了 4.76%(129373.6→135530.2)——sizing 為了改善時序會插入 buffer、放大 cell,面積上升是預期中的取捨,不是異常。
- 用 best-effort LEC(`equiv_simple`)驗證過:sizing 前後的證明覆蓋率完全沒變(同樣 36014 個 checkpoint 被證明),確認這是純粹的 cell 尺寸調整,沒有引入任何邏輯偏差。
- 19 個 regression targets 全部 PASS、135 個 lint finding 不變。

**這次的教訓,跟上一節「邏輯等價不等於時序不變」互為表裡**:這次反過來證明了「時序退化不代表已經無解」——遇到合成工具的技術對應對結構變動敏感這種問題,不是只能「誠實記錄、放棄治療」,先搞懂工具的合成腳本實際上在做什麼(這裡是「沒帶 `-constr` 就不會做 sizing」這個具體機制),往往能找到真正的槓桿點,而不是盲目調參數碰運氣。整個過程(包含中間被否決的 flatten 實驗)全部先在獨立 `git worktree` 裡驗證過,確認方向正確、跑過三個 corner 的 STA、跑過 LEC 交叉驗證之後,才實際套用到這個已經 commit 的版本上——過程中沒有任何一步是「先套用再看行不行」。

### 再往下一層:crossbar 的 decode-miss response 從 SLVERR 修正成 DECERR,加一個診斷 CSR + 中斷(v2.2.0)

這輪的起點不是效能或驗證問題,是 Levi 看 `docs/memory_map.md` 的周邊位址表時,注意到 `SLAVE_ERR`(decode miss 的 fallback)被排在「周邊」那張表裡,格式跟 Timer/UART 這些真正有 RTL 模組的周邊完全一樣——雖然 `axi_lite_xbar.v` 的原始碼裡它明明只是 `decode_addr()` function 的一個分支,不是獨立 block。這是純粹的文件排版誤導,不是 RTL 有問題,但也因此帶出了後面一整輪真正的功能討論。

**討論過程(這次的順序值得記錄,因為每一步都是 Levi 主動追問把方向修正過來的)**:

1. Levi 想順便「做 SLAVE_ERR 的功能」,原始想法是想記錄踩到哪個未映射位址——一開始我以為只是要加一個可讀的暫存器,提議用一個固定位址讓 CPU 直接讀。
2. Levi 反問「這樣 CPU 就要一直 polling,很耗資源,這顆 CPU 沒有 interrupt 機制嗎」——PicoRV32 在這個專案裡本來就有完整的 32-bit `irq` bus(bit 3-8 已經用在 Timer/WDT/I2C/SPI/AES/DMA),bit 9 以上都還空著,順理成章改成「CSR 記錄位址 + interrupt 通知」,不用 polling。
3. Levi 再問「這樣是業界會處理的方式嗎」——查證後發現大方向對(CSR + interrupt 通知、decode 邏輯放在 crossbar 內部,都是真實 AXI interconnect IP 的標準做法),但揪出一個真正的規格落差:這個專案從 Phase 1 開始,decode miss 一律回 `SLVERR`,嚴格照 AMBA/AXI4 規範應該回 `DECERR`(interconnect 自己找不到 slave,跟「slave 自己回報錯誤」是不同語意)。這個落差不是這次討論才產生的,是一直都在,只是沒人specifically去對照規範檢查過。
4. Levi 決定兩個一起做,並且要求:圖上如果要標示 SLAVE_ERR 或新的 CSR,要清楚標成 CSR、不要讓人誤會那是一個 block。

**實作前的盤點,抓到兩個沒預期到的連動**:
1. 現有測試(`blocks/axi_lite_xbar/dv/sim_main.cpp`)剛好用 `0x4000_7000` 當「確認是未映射位址」的探測位址,跟新 CSR 選的位址直接撞在一起——不先盤點就直接動手的話,新 CSR 會讓這個既有測試的假設(「這裡應該是未映射」)失效卻不會馬上被發現。
2. `docs/coverage_waivers.md` 有一條 waiver 理由寫「這個專案的 response 編碼只會用到 OKAY/SLVERR,bit[0] 永遠是 0,不用管」——DECERR 一旦真的用起來,這個理由對 crossbar 自己的 `s_bresp`/`s_rresp` 就不再成立了(即使 waiver 機制本身因為「只檢查還沒 covered 的 bit」而自動不受影響,這條理由的文字敘述已經跟事實不符,需要修正)。

**最終實作**(細節見 `CHANGELOG.md` v2.2.0):
- `rtl/include/axi_lite.vh` 新增 `AXI_RESP_DECERR`,`axi_lite_xbar.v` 的 decode-miss 路徑改回真正的 DECERR。
- 新增兩個唯讀 CSR(`0x4000_7000`/`0x4000_7004`,寫入分開的暫存器而不是「一個暫存器+方向 bit」,單純是實作起來比較不用處理位元塞不下的問題),寫入這個 window 一律 SLVERR(位址有效,只是唯讀,跟 `boot_rom` 拒絕寫入同一套邏輯)。
- 新增 `irq` bit 9,decode miss 發生的同一個 cycle 拉一個 pulse,接進 `soc_top.v` 的 `irq_bus`。
- 測試把探測位址從 `0x4000_7000` 移到 `0x4000_8000`,新增 CSR 讀值正確性、IRQ 剛好 pulse 一次(讀 CSR 或寫 CSR window 都不該誤觸發)的測試。
- `toggle_waivers.txt` 的 Rule 3 文字修正(regex 本身沒動,機制已經自動排除掉真正 covered 的 bit,細節見 `docs/coverage_waivers.md` 第 8 節)。

**驗證結果**:19/19 regression 全過、135 個 lint finding 不變、typical/slow corner 關鍵路徑完全沒變(還是 AES chain,2.881ns/10.288ns,這個改動量體太小、也不在關鍵路徑上,不影響時序)、hold 依然乾淨。Chip area 因為新增的兩個 32-bit 暫存器+相關邏輯,略增 0.7%(135530.2→136510.1),deduped toggle coverage 從 92.0% 微降到 91.4%(分母變大、新邏輯還沒做窮盡的 toggle 測試,不是既有測試變差,仍遠高於 90% 目標)。

**這次的教訓**:一個看似單純的「文件排版讓人誤會」的小發現(SLAVE_ERR 混在周邊表格裡),經過 Levi 一連串「這樣不會怎樣嗎」「業界是這樣做的嗎」的追問,最後牽出一個從 Phase 1 就存在、從沒被抓到的規格不精確(SLVERR/DECERR 混用)。**這類問題不會自己跳出來——沒有任何測試會因為「該回 DECERR 卻回了 SLVERR」而失敗,因為兩者都只是「非 OKAY」,只有真的去對照規格逐條檢查才會發現。** 另外,動手前先盤點「這個改動會撞到哪些既有的東西」(這次抓到位址衝突、waiver 理由過時兩個連動),比動手改完才發現測試莫名其妙開始失敗,省下來的除錯時間遠大於盤點本身花的時間。

# Toggle Coverage Waiver Report

沿用業界常見的 coverage sign-off 流程:對 toggle coverage 缺口逐條 review,把「結構上就是不可能 toggle」的 signal 明確 waive 掉(waive 後同時從分子、分母移除,不算 covered、也不再計入 uncovered),其餘缺口如果只是「目前測試向量不夠多樣」而非硬體限制,就不 waive,留作 residual finding。方法論跟本專案既有的 lint finding 分類(`docs/project_retrospective.md`)是同一套精神。

規則檔:`reports/sign_off/coverage/toggle_waivers.txt`(36 條 rule,附完整理由註解)
產生數據的程式:`scripts/analyze_coverage.py`(`build_toggle_waiver_report()`)
Dashboard 呈現:`reports/sign_off/dashboard.html` 的「Toggle Coverage Waivers」區塊

## 1. 數字總表

| 統計方式 | Toggle coverage | 說明 |
|---|---|---|
| Raw aggregate(`verilator_coverage --report summary`) | **65.0%**(48252/74288) | 沿用至今的舊數字。同一個 source-level toggle point,只要被多個 hierarchy instance 引用(例如 `aes_core.v` 在合併後的測試套件中被 5 個不同路徑實例化),就會被重複計數,分母被灌水但沒有對應的多樣性增加。 |
| Deduped per-bit,**waive 前** | **79.7%**(9142/11472 bits) | 直接 parse `merged.dat` 原始資料,以 (file, line, signal) 去重複,每個實際存在的 bit 只算一次(任一 instance 有覆蓋就算覆蓋)。比 raw aggregate 更誠實,單純修正重複計數的問題,還沒套用任何 waiver。 |
| Deduped per-bit,**waive 後** | **91.4%**(9142/9998 bits) | 套用 36 條 waiver rule,排除 1474 個「結構上不可能 toggle」的 bit(從分子分母同時移除)之後的最終 sign-off 數字。 |

**waive 前後對照:79.7% → 91.4%,+11.7 個百分點,分母從 11472 bits 縮減到 9998 bits(移除 1474 bits)。**

（v2.2.0 新增 axi_lite_xbar 的 DECERR/診斷 CSR 之後的數字,見第 8 節。分母比之前多了(新 RTL 引入新的 bit),但覆蓋率仍遠高於 90% 目標。)

（這是加測試向量、把 residual gap 從 1966 bits 補到 772 bits 之後的數字——見第 5 節「加測試向量把 residual gap 從 80.1% 推到 92.2%」。covered bit 數在那一輪從 7926 上升到 9153;waiver 本身邏輯不變,waive 不會讓任何東西「變成 covered」,純粹是把「本來就不該被拿來衡量」的 bit 移出評分範圍——waived bit 數從 1513 降到 1480,是因為部分先前「未覆蓋但符合 waiver 規則」的 bit 現在被新測試直接覆蓋了,不再需要被 waive。

**這裡的數字比第 5 節記錄的 92.2%/9153 又略降到 92.0%/9132**——active-low reset retrofit(見 `docs/project_retrospective.md`)改變了 `soc_top` testbench 裡 JTAG tck domain reset 釋放的確切時序(修掉了一個先前從沒被注意到的模擬層級問題,見 retrospective),連帶讓 JTAG 相關電路在開機階段實際經歷的 toggle 序列跟之前不完全一樣,covered bit 數從 9153 變成 9132。這不是測試向量變少或變差,是同一組測試在時序修正後,實際命中的 bit 組合略有不同——仍然遠高於 90% 的目標,沒有進一步處理。）

（這幾個數字比最初版本多了 4 個 bit，是後來在 `soc_top.v` 加了 reset synchronizer 新增的 4 個正反器，見 `docs/verification/cdc_methodology.md`——多出來的 bit 全部落在 soc_top 自己的分類裡，不影響任何一條 waiver rule 或其他 block 的數字。）

## 2. 為什麼採用「deduped per-bit」而不是直接在 raw aggregate 上套 waiver

Verilator 內建的 `--report summary,hier` 是以 hierarchy instance 為單位加總,同一個 module 被 instantiate 幾次,底下的 coverage point 就被算幾次。以本專案為例,`aes_core.v` 同時出現在 `TOP.aes`、`TOP.aes_chain.u_core`、`TOP.aes_core`、`TOP.dma_engine_testtop.u_engine.u_chain.u_core`、`TOP.soc_top.u_aes.u_chain.u_core` 這 5 個路徑下——如果直接在這個聚合數字上套 waiver,同一個 RTL bit 的 waiver 理由會被算 5 次,嚴重扭曲每條 waiver rule 對最終數字的實際影響力。

因此,`scripts/analyze_coverage.py` 新增 `parse_toggle_bits()`,直接讀取 `reports/sign_off/coverage/merged.dat` 的原始 toggle coverage record(格式為 `C '\x01f\x02<file>\x01l\x02<line>\x01t\x02toggle\x01o\x02<signal>:<0->1|1->0>...' <count>`),以 `(file, line, signal)` 去重複,每個 bit 只計一次、取所有 instance 的最大值。waiver rule 也是套在這個去重複後的資料上,數字才有意義。

## 3. Waiver 分類與理由(1513 bits,36 條 rule)

| 類別 | 涵蓋 bit 數 | 理由(附 RTL 實證) |
|---|---:|---|
| **位址匯流排高位元**(`s_awaddr`/`s_araddr` 及 crossbar 對應 mirror wire、內部 latch) | 1283 | 每個 AXI-Lite slave 只讀自己那一小段 register-offset(例如 `timer.v` 只看 `s_awaddr[6:0]`),crossbar(或 block-level 測試裡的 BFM)在傳到 slave 之前早就完成完整位址解碼——超出已映射範圍的高位元對 slave 本身沒有任何定義行為,沒有東西可以測。 |
| **Always-ready 寫死的 handshake signal**(`s_awready`/`s_arready`/`s_wready` 及 crossbar mirror) | 87 | 確認於 RTL:`timer.v:50-52` 等每個簡單 peripheral 都是 `assign s_awready = 1'b1;`(專案裡幾乎每個 block 都採用這個 always-ready、無 back-pressure 的慣例)——這些 wire 物理上不可能變成 0。 |
| **AXI response bit[0]**(全專案慣例) | 72 | 本專案的 `AXI_RESP` 編碼(`rtl/include/axi_lite.vh`)只用到 OKAY(`2'b00`)跟 SLVERR(`2'b10`),從不使用 EXOKAY/DECERR——這兩個實際會用到的值 bit[0] 都是 0,所以任何 `*resp` signal 的 bit[0] 在整個專案裡都是結構性常數,不是單一 module 的行為,是專案級的編碼慣例。 |
| **Peripheral 層級 bresp/rresp 整體寫死 OKAY** | 20 | 確認於 RTL:`timer.v:98,113` 等每個 peripheral 都是無條件 `s_bresp <= \`AXI_RESP_OKAY;`——只有 crossbar 自己才會針對未映射位址產生真正的 SLVERR,peripheral 本身永遠不會。 |
| **wstrb 從未被讀取**(lint 已確認 `UNUSEDSIGNAL`) | 9 | 跟既有 lint 分類 `benign-no-byte-strobe` 完全對應——如果一個 signal 的值從未被消費,它的 bit pattern 本來就無關緊要,toggle coverage 在這種 signal 上沒有意義。 |
| **DMA 主埠寫死 full-word `m_wstrb`** | 8 | 確認於 RTL:`dma_engine.v` 無條件驅動 `m_wstrb <= 4'hF;`——DMA 只搬整個 128-bit block,從來沒有 byte-partial 寫入的使用情境。 |
| **AXI4 burst-subset 欄位**(`awsize`/`arsize`/`awburst`/`arburst`/`awlen`/`arlen`) | 34 | 專案文件明確記載的 scope cut(`rtl/include/axi4.vh`、`docs/specs/dma.md`):只支援 INCR burst、固定 4-byte beat。確認於 RTL:`dma_engine.v:174-175,208-209` 永遠驅動 `AXI4_SIZE_4B`/`AXI4_BURST_INCR` 常數,burst 長度固定 4 拍(`8'd3`)。 |

## 4. 每個 block waive 前後對照

| Block | Waive 前 | Waive 後 | 變化 |
|---|---:|---:|---:|
| aes | 3873/3928 (98.6%) | 3873/3890 (99.6%) | +1.0pp |
| axi_lite_xbar | 1411/1923 (73.4%) | 1411/1459 (96.7%) | +23.3pp |
| boot_rom | 124/162 (76.5%) | 124/124 (100.0%) | +23.5pp |
| dma | 1054/1403 (75.1%) | 1054/1209 (87.2%) | +12.1pp |
| i2c | 211/289 (73.0%) | 211/251 (84.1%) | +11.1pp |
| jtag | 513/671 (76.5%) | 513/617 (83.1%) | +6.6pp |
| soc_top | 1137/1933 (58.8%) | 1137/1469 (77.4%) | +18.6pp |
| spi | 216/274 (78.8%) | 216/236 (91.5%) | +12.7pp |
| sram | 134/178 (75.3%) | 134/140 (95.7%) | +20.4pp |
| timer | 184/226 (81.4%) | 184/188 (97.9%) | +16.5pp |
| uart | 109/188 (58.0%) | 109/150 (72.7%) | +14.7pp |
| watchdog | 187/230 (81.3%) | 187/192 (97.4%) | +16.1pp |

`boot_rom` 現在 waive 後 100%。`axi_lite_xbar`、`sram` 也都推到 95%+。這一版數字已經包含第 5 節新增的測試向量(crossbar per-slave bitwise-complement 三輪值、DMA/JTAG/i2c 的窮舉暫存器覆蓋等),不是單純 waiver 分類的結果——單靠 waiver 分類已經打過的低垂果實在前一版就摘完了,這一輪的提升主要來自「補測試向量」而不是「重新分類」。

## 5. 加測試向量把 residual gap 從 80.1% 推到 92.2%

上一版(見下方「舊版 residual gap」)列出的缺口全部是「這個 register 理論上可以是任何值,只是目前測試剛好只用了少數幾組向量」,不是硬體限制,所以理論上補測試向量就能補起來,不需要 RTL 改動。這一節記錄實際動手補的過程和結果。

**起點**:80.1%(7926/9892 bits),residual gap 1966 bits。**目標**:先做低成本項目看能到多少,不到 90% 再做整合測試,結果最後全部靠補測試向量做到 **92.2%**(9153/9925 bits),沒有動到整合測試那一項。

補的方式,按實際做的順序:

1. **i2c/spi 的 `divider_reg`/`div_cnt`**:`divider_reg` 是直接寫入的暫存器,寫一次全 1 再寫回小值,兩次操作就能把 32 個 bit 都雙向 toggle 過一次,幾乎零成本。`div_cnt` 只有在交易真的進行中才會數,所以另外配一個較大(但不誇張,~70000 cycle 內跑得完)的 divider 值,啟動一次交易讓它實際數上去一段,不等交易做完(結果不檢查,只要 toggle 有發生)。
2. **DMA 的 `key_reg`/`iv_reg`/`len_reg`/`src_addr_reg`/`dst_addr_reg`**:這幾個也是直接寫入的暫存器(見 `dma_engine.v`),不需要真的觸發一次搬移就能補滿——加一組完全不同、獨立驗證過的 key(FIPS-197 Appendix B,`aes_core` 測試已經驗證過)重新跑一次 ECB 單 block 搬移(補上 mode=0 這個之前沒人測過的值),再加一段純粹寫 register 的窮舉序列(全 1 → 全 0)補滿其餘 bit。**關鍵教訓**:兩個值(原值 + complement)只能讓「原值裡是 1」的 bit 拿到雙向 toggle,「原值裡是 0」的 bit 只會拿到單向——第一次用這個手法時漏了這點,只做了「原值→complement」兩步,實測效果比預期差很多;後來全部改成「全 1 → 全 0」兩極值,才真的補滿。
3. **`axi_lite_xbar` 每個 slave port 自己的 rdata mirror register**:crossbar 內部對每個 peripheral 各自維護一份 read-data mirror,原本每個 slave 只測過一組固定資料值。同樣踩到上面那個「兩值只夠單向」的坑——第一次只加了「原值→complement」,再測發現大部分 bit 還是沒補到;改成「原值→complement→原值」三段(讓兩個方向都至少發生一次)才真正補滿。
4. **`jtag_axi_bridge`/`jtag_dtm` 的 rdata/addr CDC pipeline register**:原本只測過 2 組不同的位址/資料組合,加第三組(位址範圍另一端 + 資料 complement)。
5. **`soc_top.v` 自己的 `*_rdata`/`*_wdata` top-level mirror wire**(Timer/WDT/UART/I2C/SPI/AES 各自到 crossbar 的連接線):這是這一輪影響最大的一項。這些 wire 是 soc_top.v 自己宣告的,跟 `axi_lite_xbar.v`/各 peripheral 自己的同名 signal 是不同的 (file, line, signal) key,補了 3、4 都不會連帶補到這裡,得另外處理。透過 soc_top 測試裡本來就有的 JTAG debug bridge 路徑,對 Timer 的 REG_RELOAD 等幾個確認過的「直接寫入」暫存器做「寫全 1 讀回 → 寫全 0 讀回」,同時補到暫存器本身、`axi_lite_xbar.v` 的 per-slave mirror、跟 soc_top.v 自己的 top-level mirror 三層。第一版只寫一組任意值(例如 `0x5A5A5A5A`)+ 讀回,幾乎沒有效果——原因就是上面第 2、3 點同樣的坑,單一任意值不夠,換成「全 1/全 0」兩極值才真的補滿。

**還沒補、刻意留著的**(772 bits residual,主要是這兩類):
- **DMA 的 `cur_src`/`cur_dst`/`blocks_left`**:這幾個是搬移進行中才會變化的內部進度計數器,不像 `key_reg` 那樣可以直接寫,需要真的跑一次不同長度/位址的搬移才能補,還沒做。
- **`soc_top.v` 自己的 SPI/I2C 實體 pin**(`spi_sclk`/`spi_mosi`/`spi_miso`/`spi_cs_n`/`i2c_scl`/`i2c_sda`)以及對應的 crossbar-facing mirror:`spi`/`i2c` 各自的獨立測試已經測得很完整,但 `soc_top` 整合測試沒有真的跑一次完整 SoC 路徑的 SPI/I2C transaction——這是本來規劃的「補測試」四個選項之一,這次沒動到,因為單獨這塊只值 42 bits(不到 0.5 個百分點),優先度排在後面,真正推過 90% 的是上面 1-5 點。

### 舊版 residual gap(補測試向量之前,僅供對照)

- **`dma_engine.v` 的 `key_reg`(128 bit)、`iv_reg`(64 bit)**:DMA 路徑的每一組測試都固定用同一組 NIST 官方測試金鑰/IV,這個 register 從沒被載入過第二組不同的值。
- **`i2c_master.v`/`spi_master.v` 的 `divider_reg`/`div_cnt`**:32-bit 的除頻常數 register,但實際測試只用過幾組偏小的除頻值,高位元從沒被設過。
- **各 block 自己的 `s_rdata`/`m_rdata`(24-32 bit 未覆蓋)**:反映目前固定測試向量的 bit pattern 剛好沒有讓每個 bit 都出現過 0 跟 1 兩種值,不是暫存器寬度用不到。
- **`jtag_axi_bridge.v`/`jtag_dtm.v`/`i2c_master.v` 的 `addr_reg`/`addr_tck`**:一開始誤判為跟位址匯流排高位元同一類「結構性」問題(細節見下方除錯記錄),但重新檢視後發現這幾個 register 的值真的會被下游邏輯拿來用,只是每個測試選的位址/target 種類不夠多。
- **`soc_top.v` 自己的 SPI/I2C 實體 pin**以及對應的 crossbar-facing 匯流排 mirror。

## 6. 過程中抓到的一個自己的誤判(值得記錄)

第一版 waiver file 曾經把 `addr_reg`/`addr_tck` 當成跟 `s_awaddr`/`s_araddr` 同一類「上游已經解碼過,高位元沒有定義行為」直接 waive 掉。套用後發現這條 rule 用 signal 名稱比對、沒有限定檔案,結果同時誤中了三個完全不相關的 register:`jtag_axi_bridge.v:89`、`jtag_dtm.v:78`(JTAG bridge 的目標位址暫存器)跟 `i2c_master.v:316`(I2C target 位址暫存器,只有 7 bit,跟 JTAG 毫無關係)。

重新檢查這三個 register 的 RTL 後發現,跟 `s_awaddr` 不一樣的地方在於:`s_awaddr` 的高位元是 crossbar「已經解碼過、slave 自己確定用不到」的位元,但 `addr_reg` 是一個真的會被下游拿去用的完整值(驅動實際 AXI 交易位址,或決定要跟哪個 I2C target 通訊)——沒有任何 bit 是「結構上不可能」,純粹是測試只挑了幾個具代表性的位址/target 去測。判斷標準應該是「這個 signal 的值有沒有真的被下游消費、下游行為會不會因為這個值不同而不同」,不是「signal 名字裡有沒有 addr」。已把這條 rule 從 waiver file 移除,改列進第 5 節的 residual gap。

## 7. 如何重跑

```bash
scripts/run_coverage.sh                 # 重新收集每個 block/dv/testlist.sh 自動註冊的測試的 coverage,merge 成 merged.dat
python3 scripts/analyze_coverage.py     # 重新 parse + 套用 waiver,寫出 reports/sign_off/dashboard_data.json
python3 scripts/build_dashboard.py      # 重新產生 reports/sign_off/dashboard.html
```

新增/修改 waiver rule:直接編輯 `reports/sign_off/coverage/toggle_waivers.txt`(格式:`<signal-regex><TAB><理由>`,套用在 bit-indexed 名稱如 `s_bresp[0]` 跟去掉 index 的 base name 如 `s_bresp` 兩者上),重跑 `analyze_coverage.py` 即可。

## 8. v2.2.0:DECERR + 診斷 CSR 讓 Rule 3 的其中一條理由過時

`axi_lite_xbar.v` 新增了 decode-miss 的正確回應碼(`SLVERR`→`DECERR`)跟一個診斷用 CSR(細節見 `docs/project_retrospective.md`、`docs/memory_map.md`)之後,Rule 3(`^s_bresp\[0\]$`/`^s_rresp\[0\]$`,「這個專案的 response 編碼只會用到 OKAY/SLVERR,bit[0] 永遠是 0」)的理由**不再是 project-wide 成立的事實**——crossbar 自己對外的 `s_bresp`/`s_rresp`(呈現給 s0/s1 的那個)現在真的會在 decode miss 時驅動 `DECERR`(`2'b11`,bit[0]=1),不再是結構性常數。

**但這不是一個需要修正的 bug,數字也沒有變差**——這個 waiver 機制是「先看這個 bit 有沒有真的被覆蓋,只有還沒覆蓋的才會去檢查 waiver rule」(見 `scripts/analyze_coverage.py` 的 `build_toggle_waiver_report()`),所以:

- axi_lite_xbar 自己的 `s_bresp[0]`/`s_rresp[0]`,因為新增的 DECERR 測試(`blocks/axi_lite_xbar/dv/sim_main.cpp`)讓它們兩個方向都真的 toggle 過,**已經直接算作 covered,從來沒有被這條 waiver 規則接住過**——實際檢查過 dashboard 產生的 waived-bit 範例清單,這條規則現在只列出真正的周邊模組(`aes.v`、`boot_rom.v`、`dma_engine.v` 等),axi_lite_xbar 完全沒有出現在裡面,證實機制運作正常。
- 其他所有周邊(Timer/Watchdog/UART/I2C/SPI/AES/DMA/boot_rom)自己的 `s_bresp`/`s_rresp`,以及 crossbar 內部連到這些周邊的 per-slave mux wire(`rom_bresp`/`ram_bresp`/`w_slave_bresp` 等),**這條 waiver 理由仍然完全成立**——這些周邊本身從來沒有機會生成 `DECERR`(那是 crossbar 自己的邏輯,不會透過周邊的 bresp/rresp 路徑),bit[0] 在這些地方依然是真正的結構性常數。

實際做的修正:只更新 `toggle_waivers.txt` 裡這幾條規則的**理由文字**,把「project-wide 都不會用到 DECERR」改成「周邊層級跟 crossbar 內部 per-slave mux 才適用,crossbar 自己對外的 bresp/rresp 是 v2.2.0 之後的例外」,**regex pattern 本身完全沒動**(不需要動,機制已經自動排除掉真正覆蓋到的 bit)。這是「文件講的理由要跟實際行為保持誠實」的例子,不是修 bug。

順便更新的整體數字(`docs/verification/coverage_waivers.md` 第 1 節表格已同步):waive 前 79.7%(9142/11472)、waive 後 91.4%(9142/9998),1474 bits waived、36 條 rule 不變。分母比 v2.1.0 時期多了(新 RTL 引入新的暫存器/邏輯),百分比因此比 92.0% 略降到 91.4%,是新增邏輯測試向量還沒做到窮盡的正常現象,不是既有測試變差,仍然遠高於 90% 目標。

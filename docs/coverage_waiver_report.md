# Toggle Coverage Waiver Report

沿用業界常見的 coverage sign-off 流程:對 toggle coverage 缺口逐條 review,把「結構上就是不可能 toggle」的 signal 明確 waive 掉(waive 後同時從分子、分母移除,不算 covered、也不再計入 uncovered),其餘缺口如果只是「目前測試向量不夠多樣」而非硬體限制,就不 waive,留作 residual finding。方法論跟本專案既有的 lint finding 分類(`docs/project_retrospective.md`)是同一套精神。

規則檔:`reports/sign_off/coverage/toggle_waivers.txt`(36 條 rule,附完整理由註解)
產生數據的程式:`scripts/analyze_coverage.py`(`build_toggle_waiver_report()`)
Dashboard 呈現:`reports/sign_off/dashboard.html` 的「Toggle Coverage Waivers」區塊

## 1. 數字總表

| 統計方式 | Toggle coverage | 說明 |
|---|---|---|
| Raw aggregate(`verilator_coverage --report summary`) | **58.1%**(43169/74290) | 沿用至今的舊數字。同一個 source-level toggle point,只要被多個 hierarchy instance 引用(例如 `aes_core.v` 在合併後的測試套件中被 5 個不同路徑實例化),就會被重複計數,分母被灌水但沒有對應的多樣性增加。 |
| Deduped per-bit,**waive 前** | **69.5%**(7926/11405 bits) | 直接 parse `merged.dat` 原始資料,以 (file, line, signal) 去重複,每個實際存在的 bit 只算一次(任一 instance 有覆蓋就算覆蓋)。比 raw aggregate 更誠實,單純修正重複計數的問題,還沒套用任何 waiver。 |
| Deduped per-bit,**waive 後** | **80.1%**(7926/9892 bits) | 套用 36 條 waiver rule,排除 1513 個「結構上不可能 toggle」的 bit(從分子分母同時移除)之後的最終 sign-off 數字。 |

**waive 前後對照:69.5% → 80.1%,+10.6 個百分點,分母從 11405 bits 縮減到 9892 bits(移除 1513 bits)。**

covered bit 數(7926)本身完全沒變——waiver 不會讓任何東西「變成 covered」,純粹是把「本來就不該被拿來衡量」的 bit 移出評分範圍。

(這幾個數字比最初版本多了 4 個 bit,是後來在 `soc_top.v` 加了 reset synchronizer 新增的 4 個正反器,見 `docs/cdc_report.md`——多出來的 bit 全部落在 soc_top 自己的分類裡,不影響任何一條 waiver rule 或其他 block 的數字。)

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
| aes | 3871/3928 (98.5%) | 3871/3890 (99.5%) | +1.0pp |
| axi_lite_xbar | 1145/1923 (59.5%) | 1145/1447 (79.1%) | +19.6pp |
| boot_rom | 117/162 (72.2%) | 117/124 (94.4%) | +22.2pp |
| dma | 767/1403 (54.7%) | 767/1208 (63.5%) | +8.8pp |
| i2c | 126/289 (43.6%) | 126/251 (50.2%) | +6.6pp |
| jtag | 394/671 (58.7%) | 394/609 (64.7%) | +6.0pp |
| soc_top | 831/1933 (43.0%) | 831/1457 (57.0%) | +14.0pp |
| spi | 140/274 (51.1%) | 140/236 (59.3%) | +8.2pp |
| sram | 134/178 (75.3%) | 134/140 (95.7%) | +20.4pp |
| timer | 148/226 (65.5%) | 148/188 (78.7%) | +13.2pp |
| uart | 102/188 (54.3%) | 102/150 (68.0%) | +13.7pp |
| watchdog | 151/230 (65.7%) | 151/192 (78.6%) | +12.9pp |

`axi_lite_xbar`、`boot_rom`、`sram` 提升最明顯,因為這三個 block 的缺口幾乎全是位址匯流排高位元跟 always-ready 訊號,完全落在 waiver 分類裡。`dma`、`i2c`、`soc_top` 提升幅度較小,是因為這幾個 block 剩下的缺口大多是下一節的 residual gap(真正的測試向量多樣性不足),而不是結構性缺口。

## 5. Residual gap(刻意不 waive,留待未來加測試向量)

總計 1966 bits,分布在下列幾種模式——每一種都是「這個 register 理論上可以是任何值,只是目前測試剛好只用了少數幾組向量」,跟前面的「結構上不可能」是不同性質,所以刻意不 waive:

- **`dma_engine.v` 的 `key_reg`(128 bit)、`iv_reg`(64 bit)**:DMA 路徑的每一組測試都固定用同一組 NIST 官方測試金鑰/IV,這個 register 從沒被載入過第二組不同的值。風險偏低——AES 資料路徑本身已經透過 `aes_diff` 測試用 500 組隨機金鑰單獨驗證過,這裡缺的只是 DMA 自己這份 register 的搬運路徑沒有額外驗證,不是核心加解密邏輯沒驗證。
- **`i2c_master.v`/`spi_master.v` 的 `divider_reg`/`div_cnt`**:32-bit 的除頻常數 register,但實際測試只用過幾組偏小的除頻值,高位元從沒被設過——一個合理但還沒補的加分項(測一組刻意選大的除頻值即可補齊)。
- **各 block 自己的 `s_rdata`/`m_rdata`(24-32 bit 未覆蓋)**:反映目前固定測試向量的 bit pattern 剛好沒有讓每個 bit 都出現過 0 跟 1 兩種值,不是暫存器寬度用不到。
- **`jtag_axi_bridge.v`/`jtag_dtm.v`/`i2c_master.v` 的 `addr_reg`/`addr_tck`**:一開始誤判為跟位址匯流排高位元同一類「結構性」問題(細節見下方除錯記錄),但重新檢視後發現這幾個 register 的值真的會被下游邏輯拿來用(驅動實際 AXI 位址、決定 I2C target),只是每個測試選的位址/target 種類不夠多——已從 waiver file 移除,留在這裡當 residual。
- **`soc_top.v` 自己的 SPI/I2C 實體 pin(`spi_sclk`/`spi_mosi`/`spi_miso`/`spi_cs_n`/`i2c_scl`/`i2c_sda`)以及對應的 crossbar-facing 匯流排 mirror**:這幾個 block 各自的獨立測試(`spi`/`i2c` regression target)已經很完整地測過,但 `soc_top` 自己這個整合測試只有功能性驗證 Timer/UART/JTAG/DMA register poke,沒有真的透過完整 SoC 路徑跑一次 SPI/I2C transaction——是一個真實但風險偏低的整合層級缺口,適合之後加一個 `soc_top` 層級的 SPI/I2C loopback 測試來補。

## 6. 過程中抓到的一個自己的誤判(值得記錄)

第一版 waiver file 曾經把 `addr_reg`/`addr_tck` 當成跟 `s_awaddr`/`s_araddr` 同一類「上游已經解碼過,高位元沒有定義行為」直接 waive 掉。套用後發現這條 rule 用 signal 名稱比對、沒有限定檔案,結果同時誤中了三個完全不相關的 register:`jtag_axi_bridge.v:89`、`jtag_dtm.v:78`(JTAG bridge 的目標位址暫存器)跟 `i2c_master.v:316`(I2C target 位址暫存器,只有 7 bit,跟 JTAG 毫無關係)。

重新檢查這三個 register 的 RTL 後發現,跟 `s_awaddr` 不一樣的地方在於:`s_awaddr` 的高位元是 crossbar「已經解碼過、slave 自己確定用不到」的位元,但 `addr_reg` 是一個真的會被下游拿去用的完整值(驅動實際 AXI 交易位址,或決定要跟哪個 I2C target 通訊)——沒有任何 bit 是「結構上不可能」,純粹是測試只挑了幾個具代表性的位址/target 去測。判斷標準應該是「這個 signal 的值有沒有真的被下游消費、下游行為會不會因為這個值不同而不同」,不是「signal 名字裡有沒有 addr」。已把這條 rule 從 waiver file 移除,改列進第 5 節的 residual gap。

## 7. 如何重跑

```bash
scripts/run_coverage.sh                 # 重新收集全部 18 個測試的 coverage,merge 成 merged.dat
python3 scripts/analyze_coverage.py     # 重新 parse + 套用 waiver,寫出 reports/sign_off/dashboard_data.json
python3 scripts/build_dashboard.py      # 重新產生 reports/sign_off/dashboard.html
```

新增/修改 waiver rule:直接編輯 `reports/sign_off/coverage/toggle_waivers.txt`(格式:`<signal-regex><TAB><理由>`,套用在 bit-indexed 名稱如 `s_bresp[0]` 跟去掉 index 的 base name 如 `s_bresp` 兩者上),重跑 `analyze_coverage.py` 即可。

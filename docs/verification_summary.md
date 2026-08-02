# Verification Summary

19 個獨立的 Verilator 測試,一次跑過 `scripts/run_regression.sh`,目前全綠。每一列對應一個獨立編譯出來的測試 binary;細節與驗證方法論見各自的 `docs/specs/*.md`。

## 1. 總表

| # | 測試 | 範圍 | 方法 | 結果 |
|---|---|---|---|---|
| 1 | `timer` | Timer 週期精確倒數、auto-reload、sticky EXPIRED、EN stop/hold | Cycle-accurate 導向測試(逐 cycle 比對軟體模型) | PASS |
| 2 | `watchdog` | WARNING/RESET_REQ 精確時序、KICK、STATUS 語意 | Cycle-accurate 導向測試 | PASS |
| 3 | `uart` | TX frame 解碼、busy 行為、忙碌中寫入被忽略 | Cycle-accurate 導向測試 | PASS |
| 4 | `sram` | 完整/部分寫入(byte strobe)、讀回、word 互不干擾 | 導向測試 | PASS |
| 5 | `boot_rom` | `$readmemh` 載入、讀取正確性、寫入被拒(SLVERR) | 導向測試 | PASS |
| 6 | `i2c` | 寫入、讀取、對未知位址 NACK、busy/no-queue | 導向測試,對一個假 I2C slave（`fake_i2c_slave.v`) | PASS |
| 7 | `spi` | 全部 4 種 CPOL/CPHA 模式、byte-accurate、busy/done、忙碌中 START 被忽略 | 導向測試,對一個假 SPI slave（`fake_spi_slave.v`) | PASS |
| 8 | `jtag_tap` | IEEE 1149.1 16-state FSM 完全比對參考模型,任意狀態下 TMS reset 安全性質 | Property-based + 參考模型比對 | PASS |
| 9 | `jtag_chain` | TAP+DTM+bridge 整條鏈,tck↔clk CDC(tck 慢於 clk 的方向)、IDCODE、BYPASS、透過真正 AXI4-Lite slave 讀寫 | 端到端整合測試 | PASS |
| 9b | `jtag_chain_fast_tck` | 同上,但 tck 反過來比 clk 快——CDC ratio 的另一個極端方向 | 端到端整合測試(CDC 壓力測試,見 `docs/cdc_report.md`) | PASS |
| 10 | `aes_key_expand` | 11 組 round key | FIPS-197 Appendix A.1 官方向量 | PASS |
| 11 | `aes_core` | 單一 block encrypt/decrypt | FIPS-197 Appendix B + C.1 官方向量 | PASS |
| 12 | `aes_chain` | CBC/CTR mode chaining,兩個方向 | NIST SP 800-38A Appendix F.2/F.5 官方向量 | PASS |
| 13 | `aes_axi_wrapper` | 透過真正 AXI4-Lite 暫存器介面的 ECB/CBC | FIPS-197 + NIST SP800-38A 官方向量,額外驗證 KEY 唯讀、busy/no-queue | PASS |
| 14 | `aes_diff` | 500 組隨機明文/金鑰 | Differential test,對一個獨立從零寫的 C++ AES-128 參考模型(自己也先過官方向量) | PASS |
| 15 | `axi_lite_xbar` | 位址解碼路由到全部 9 個 slave、SLVERR on miss、2-master 仲裁(含競爭邊界情況) | 導向測試,對 8 個 `fake_axi_lite_slave.v` | PASS |
| 16 | `dma_ram` | AXI4 INCR burst 讀寫、byte strobe、單拍 burst、連續 burst 互不干擾 | 導向測試 | PASS |
| 17 | `dma_engine` | 多 block CBC encrypt/decrypt + CTR,透過真正 AXI4 burst + `aes_chain`,CPU 零介入 | 端到端測試,比對 NIST SP800-38A 向量,15 項個別檢查 | PASS |
| 18 | `soc_top` | Firmware boot、5 次真實 Timer 中斷(經 PicoRV32 getq/setq/retirq)、UART 輸出、JTAG 透過真正 2-master crossbar 讀寫 RAM 與 DMA 控制暫存器 | 全 SoC 整合測試,執行真正編譯出來的韌體 | PASS |

## 2. 覆蓋率之外的驗證方式

- **Differential testing**（AES)：不只跑官方向量,額外拿一個完全獨立寫的軟體參考模型跑 500 組隨機輸入互相比對,抓純粹「剛好在官方向量上蒙對」的錯誤。
- **Property-based testing**（JTAG TAP)：驗證「從任意狀態 TMS=1 五次一定回到 TEST_LOGIC_RESET」這條 IEEE 1149.1 規範的安全性質,不是只測特定路徑。
- **Cycle-accurate 時序驗證**（Timer/Watchdog)：不是只檢查「最後有沒有觸發」,而是每個 cycle 都跟一個軟體模型比對,確保觸發的時機精確到 cycle。
- **合成後 lint 乾淨**：每個 block 都用同一組 Verilator flag（`-Wall` 開頭)編譯,唯一允許的例外是 vendored PicoRV32 自己的程式碼風格（`-Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED`,不是這個專案自己寫的 RTL 產生的警告)。

## 3. 量化的 coverage 數據

`scripts/run_coverage.sh` + `scripts/analyze_coverage.py`,完整方法論見 `docs/project_retrospective.md`。跑完全部 18 個 regression 測試(`--coverage-line --coverage-toggle`)合併後:

| 指標 | 結果 |
|---|---|
| Line coverage(這個專案自己寫的 RTL,不含 vendored PicoRV32) | **96.3%** |
| Toggle coverage,raw aggregate(`verilator_coverage --report summary`) | 58.1%(43157/74282 points)——這個數字把同一個 source-level toggle point 依 hierarchy instance 重複計數(例如 `aes_core.v` 被 5 個不同路徑實例化),分母被灌水,詳見下方 |
| Toggle coverage,deduped per-bit,**waive 前** | **69.5%**(7923/11401 bits) |
| Toggle coverage,deduped per-bit,**waive 後**(36 條 waiver rule,waive 掉 1513 個結構上不可能 toggle 的 bit) | **80.1%**(7923/9888 bits) |
| Branch coverage(全專案合併) | 77.3%(1500/1940 points) |
| **FSM state coverage**（11 個 FSM:spi_master、i2c_master、uart、jtag_tap、aes_core、aes_chain、axi_lite_xbar 讀/寫、dma_ram 讀/寫、dma_engine) | **100%**(全部狀態都至少被進入過一次) |

Toggle coverage 完整的 waiver 方法論、每一條 rule 的 RTL 實證、waive 前後每個 block 的量化對照、以及刻意不 waive 的 residual gap 清單:`docs/coverage_waiver_report.md`。

圖像化的 sign-off dashboard(coverage bar chart、toggle waiver 摘要、每個 FSM 的狀態 checklist、135 筆 lint 發現分類後的 summary、架構圖)：`reports/sign_off/dashboard.html`,可以直接用瀏覽器打開,不需要額外工具。

## 4. Gate-level 層級的驗證(STA multi-corner、formal LEC、gate-level simulation)

範圍限定在 `aes` + `soc_top`(跟現有 per-block synthesis/STA 的既有範圍一致):

- **Multi-corner STA**(`blocks/{aes,soc_top}/sta/sta_mcmm.tcl`):第 1 節、`docs/performance.md` 引用的 Fmax 是單一 typical corner 的數字,這裡補上 setup(slow corner)+ hold(fast corner)。soc_top 在 slow corner 下真實關鍵路徑 43.128ns(**slow-corner Fmax ≈ 23.2MHz**),fast corner 下 hold 完全乾淨(0 個違規)。完整數字見 `docs/performance.md` 第 7 節。
- **Formal equivalence check(LEC)**(`blocks/{aes,soc_top}/syn/lec.ys`):用 Yosys 的 `equiv_make`/`equiv_simple`/`equiv_induct` 形式化證明「synthesis 出來的 gate-level netlist」邏輯上等價於 RTL。aes_core 完整跑完,97.7% 證明完成;soc_top 因為含整顆 CPU、規模差兩個數量級,刻意只跑不含 sequential induction 的部分驗證(60.2%),改用下面的 gate-level simulation 補足整顆 SoC 的驗證——完整理由跟數字見 `docs/lec_report.md`。
- **Gate-level simulation**(`scripts/run_gatelevel_sim.sh`):拿現有的 regression testbench,直接對 Yosys 合成後的 netlist(而非 RTL)跑一次,驗證 synthesis 本身沒有改變行為。aes_core、soc_top(含真實開機、5 次 Timer 中斷、UART 輸出、JTAG 讀寫 RAM、DMA 控制埠)兩個都 **PASS**。
- **Signoff 範圍界限**:這個專案的 signoff 停在「gate-level netlist,邏輯跟時序都驗證過」——不含 place & route、DRC/LVS、DFT、power signoff,理由見 `docs/performance.md` 第 8 節(刻意的取捨,不是漏掉)。

## 5. CDC(Clock Domain Crossing)驗證

這個平台不是單一時脈——`tck`(JTAG 測試時脈,外部 debug probe 驅動)跟 `clk`(系統時脈)是兩個完全獨立、非同步的 domain,`jtag_axi_bridge.v` 是唯一橫跨兩者的模組。這台機器沒有裝專門的 CDC 工具(Spyglass CDC/Questa CDC 都沒有),用三件互補的事來驗證:

1. **STA 正確宣告非同步邊界**:`tck` 宣告成真正的 clock(而非純資料訊號,因為它真的驅動正反器)+ `set_clock_groups -asynchronous` 排除跨 domain 路徑的誤判。
2. **結構性 review**:對照 RTL 逐條確認每個跨 domain 訊號的 synchronizer 級數(全部 ≥2 級)、第一級是否直接取樣來源暫存器(無組合邏輯夾雜)。
3. **模擬層級的 ratio 壓力測試**:`jtag_chain`(tck 慢於 clk)+ 新增的 `jtag_chain_fast_tck`(tck 快於 clk)兩個方向都測過,驗證 RTL 宣稱的「任意時脈比例都成立」不是空話。

完整方法論、逐條訊號的 review 結果、以及明確標注的範圍界限(數位模擬無法重現真實 metastability,這部分需要 timing library MTBF 計算,不在這個專案範圍內):`docs/cdc_report.md`。

## 6. 這次 Phase 7 regression 抓到的一個真實 bug

跑 `scripts/run_regression.sh` 的過程中,`watchdog` 測試意外地從乾淨重編後失敗(2 個 check),但目錄裡舊的、還沒清掉的 binary 卻是綠的——追下去發現:`blocks/watchdog/dv/sim_main.cpp` 裡寫死的 `WARN_MARGIN = 3`,跟 `watchdog.v` 實際的 default parameter `WARN_MARGIN = 4`（從 Phase 2 第一次 commit 就是 4,`docs/specs/watchdog.md` 也一直寫 4)對不上——測試本身的常數從一開始就是錯的,只是舊的 binary 剛好是在某次意外用對的數字建出來的,之後沒人重新乾淨編譯過,才一直「看起來是綠的」。這正是「一次性乾淨 regression」存在的意義:抓到「原始碼其實已經不吻合、只是沒人重新建置驗證過」這種腐化。修法:把測試的常數改成 4,重編後全綠。詳細除錯過程見 `docs/project_retrospective.md`。

# Verification Summary

18 個獨立的 Verilator 測試,一次跑過 `scripts/run_regression.sh`,目前全綠。每一列對應一個獨立編譯出來的測試 binary;細節與驗證方法論見各自的 `docs/specs/*.md`。

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
| 9 | `jtag_chain` | TAP+DTM+bridge 整條鏈,tck↔clk CDC,IDCODE、BYPASS、透過真正 AXI4-Lite slave 讀寫 | 端到端整合測試 | PASS |
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

## 4. 這次 Phase 7 regression 抓到的一個真實 bug

跑 `scripts/run_regression.sh` 的過程中,`watchdog` 測試意外地從乾淨重編後失敗(2 個 check),但目錄裡舊的、還沒清掉的 binary 卻是綠的——追下去發現:`blocks/watchdog/dv/sim_main.cpp` 裡寫死的 `WARN_MARGIN = 3`,跟 `watchdog.v` 實際的 default parameter `WARN_MARGIN = 4`（從 Phase 2 第一次 commit 就是 4,`docs/specs/watchdog.md` 也一直寫 4)對不上——測試本身的常數從一開始就是錯的,只是舊的 binary 剛好是在某次意外用對的數字建出來的,之後沒人重新乾淨編譯過,才一直「看起來是綠的」。這正是「一次性乾淨 regression」存在的意義:抓到「原始碼其實已經不吻合、只是沒人重新建置驗證過」這種腐化。修法:把測試的常數改成 4,重編後全綠。詳細除錯過程見 `docs/project_retrospective.md`。

# CDC(Clock Domain Crossing)Report

這台機器上沒有裝任何專門的 CDC 檢查工具(Spyglass CDC、Questa CDC 都沒有,查過 Yosys 也沒有對應的內建 pass)。這份報告是業界在沒有商用 CDC 工具時的標準替代做法:STA 對非同步邊界做正確的宣告(排除誤判,但不驗證 synchronizer 本身)+ 針對實際 CDC 邊界的結構性人工 review(對照 RTL 確認 synchronizer 級數/拓樸)+ 針對 ratio 假設的模擬壓力測試。三件事互補,沒有一件單獨等於「CDC 驗證完成」。

## 1. 這個平台只有一個真正的 CDC 邊界

整個 SoC 只有一個時脈訊號驅動真正的邏輯:`clk`(系統時脈)。但還有第二個獨立、非同步的時脈:`tck`(JTAG 測試時脈),由外部 debug probe 驅動,跟 `clk` 沒有固定的相位或頻率關係。

- `jtag_tap.v`、`jtag_dtm.v`:完全跑在 `tck` domain,不知道 `clk` 存在
- `jtag_axi_bridge.v`:**唯一**橫跨兩個 domain 的模組,同時吃 `clk` 跟 `tck`,自己處理全部的 CDC

其餘所有模組(crossbar、每個周邊、AES、DMA、PicoRV32)都只在 `clk` domain 裡,彼此之間沒有 CDC 問題。

## 2. STA 對非同步邊界的宣告

`blocks/soc_top/constraints/soc_top.sdc` 新增:

```tcl
create_clock -name tck -period 20.0 [get_ports tck]
set_input_delay  0.0 -clock tck [get_ports tms]
set_input_delay  0.0 -clock tck [get_ports tdi]
set_output_delay 0.0 -clock tck [get_ports tdo]

set_clock_groups -asynchronous -group {clk} -group {tck}
```

- `tck` 宣告成真正的 clock(20ns/50MHz,對真實 JTAG probe 是保守夠用的假設)而不是純資料訊號——因為它真的驅動 `jtag_tap.v`/`jtag_dtm.v` 裡正反器的 clock pin,不宣告的話 STA 會完全跳過整個 tck domain 的時序分析,不只是跨 domain 的部分。
- `set_clock_groups -asynchronous` 明確告訴 OpenSTA 這兩個 clock 沒有相位關係,不要對跨 domain 的路徑算 setup/hold——重跑過 `sta.tcl`/`sta_mcmm.tcl` 確認:tck domain 自己的內部路徑(`jtag_dtm` 的 FSM)有被正常檢查、而且時序寬鬆(18.34ns/20ns 週期都還有margin);兩個 domain 之間完全沒有任何路徑被拿去做 setup/hold 比對(用 `Path Group:` 分組確認過,只有 `clk`、`tck` 兩組,沒有混合的)。

**這一步解決的是「STA 不要對非同步邊界產生誤判或假過關」,不是「synchronizer 本身有沒有做對」——後者要靠下面的結構性 review。**

## 3. `jtag_axi_bridge.v` 的結構性 review

逐一對照 RTL(`blocks/jtag/rtl/jtag_axi_bridge.v`)確認每一條跨 domain 訊號:

| 方向 | 訊號 | 機制 | Synchronizer 級數 | 備註 |
|---|---|---|---|---|
| tck → clk | START 事件 | `start_toggle_tck`(tck 端每次 START 翻轉一次)→ clk 端 2-flop double-flop → edge-detect 還原成 pulse | 2 級(`start_toggle_sync1`/`start_toggle_sync2`) | Toggle 編碼,不是直接同步 level/pulse,不會因為 tck:clk 比例而漏事件 |
| clk → tck | DONE 事件 | `done_toggle_clk` → tck 端 2-flop double-flop | 2 級(`done_toggle_sync1`/`done_toggle_sync2`) | 同上 |
| clk → tck | BUSY | 比較 `start_toggle_tck`(tck 自己寫的,不需同步)跟 `done_toggle_sync2`(已同步) | — | 不是同步一個 level,是比較兩個各自持有到下次事件為止的暫存器,對任何比例都成立 |
| clk → tck | RESP_OK | `resp_ok`(clk 端)→ tck 端 2-flop | 2 級(`resp_ok_sync1`/`resp_ok_sync2`) | 多位元/單位元皆同一套 2-flop,quasi-static:只在 busy 已經同步變成「不忙」之後才會被讀取,那時候 clk 端已經穩定一段時間 |
| clk → tck | RDATA(32-bit) | `rdata_reg`(clk 端)→ tck 端 2-flop-per-bit | 2 級(`rdata_sync1`/`rdata_sync2`) | 同上,quasi-static bus,由已同步的 busy 把關,不是任意時刻取樣 |

**確認事項**(直接讀 RTL 逐條核對,不是假設):
- 每一條跨 domain 訊號進到新 domain 的**第一級暫存器,輸入端都是對方 domain 的原始暫存器輸出**,中間沒有夾組合邏輯(例如 `start_toggle_sync1 <= start_toggle_tck;`,不是 `start_toggle_sync1 <= f(start_toggle_tck, 其他訊號);`)——這是 CDC 的基本要求:同步器的第一級要直接取樣來源暫存器,不能先經過組合邏輯才取樣,否則組合邏輯的 glitch 有可能被取樣到。
- 全部同步器都至少 2 級,沒有只用 1 級的。
- BUSY 不是同步一個 level,而是比較兩個各自維持到下次事件為止的 toggle 暫存器——這個設計本身有記錄在 RTL 的 header comment 裡,連同它取代的、曾經出過真實 bug 的舊版本(直接同步 busy level,tck 遠慢於 clk 時窗口可能被錯過)一起寫清楚,這段歷史本身就是這個結構是刻意設計、不是巧合的證據。

## 4. 模擬層級的 ratio 壓力測試

結構性 review 沒辦法驗證的是:「這個設計真的對**任意**時脈比例都成立嗎,還是剛好現有測試選的比例讓它看起來沒事?」——RTL 的 header comment 明確宣稱「regardless of how large the clock-period ratio is in either direction」,這是一個可以被測試驗證的具體宣稱。

檢查現有的 `jtag_chain` regression 測試才發現:它固定用 tck 遠慢於 clk 的比例(每個 tck 半週期對應 10 個 clk 半週期),只測了「真實 JTAG probe 對比快系統時脈」這一個方向,從沒測過反過來的情況。

補了一個新的 regression target,`jtag_chain_fast_tck`(`blocks/jtag/dv/jtag_chain_fast_tck_sim_main.cpp`):完全相同的 IDCODE/AXI write-read-back/BYPASS 測試序列,唯一的差異是把時脈關係反過來——tck 每 5 個半週期才讓 clk 走一個半週期,也就是 tck 真的比 clk 快,兩個方向都測過了。跑完 **PASS**,證實這個 toggle-synchronizer + busy 比較的設計,在兩個方向的極端比例下都正確。

**誠實的限制**:數位模擬本質上沒辦法真的重現類比世界的 metastability(暫態不穩定電壓)——這是任何純模擬手段(不管測多少種比例)都無法觸及的層面,真正能驗證「同步器在真實電路的 metastability 下降低到可接受機率」需要 STA 工具的 MTBF(平均故障間隔時間)計算或實際晶片測試,這個專案沒有目標製程的 timing library 資料可以做這個計算,所以這裡驗證的是「協定/邏輯設計本身在任意時脈關係下功能正確」,不是「實體電路的 metastability 機率」——這是刻意標注清楚的範圍界限,不是遺漏。

## 5. 總結

| 檢查項目 | 方法 | 結果 |
|---|---|---|
| STA 不對非同步邊界誤判 | `set_clock_groups -asynchronous` | 確認:tck/clk 兩個 Path Group 完全分開,無混合路徑 |
| Synchronizer 結構(級數、有無組合邏輯夾雜) | 對照 RTL 逐條 review | 全部 ≥2 級,第一級都直接取樣來源暫存器,無組合邏輯夾雜 |
| 邏輯/協定在任意時脈比例下的正確性 | 模擬,兩個方向的極端比例 | `jtag_chain`(tck 慢)+ `jtag_chain_fast_tck`(tck 快)都 PASS |
| 實體電路 metastability 機率 | 需要真正的 timing library MTBF 計算或流片測試 | 不在這個專案的範圍內(沒有目標製程資料),明確標注,不是遺漏 |

## 6. 如何重跑

```bash
./scripts/run_regression.sh   # 含 jtag_chain + jtag_chain_fast_tck 兩個方向
cd blocks/soc_top/sta && sta sta.tcl        # 確認 tck domain 內部時序 + async 分組
cd blocks/soc_top/sta && sta sta_mcmm.tcl   # 同上,含 setup/hold 兩個 corner
```

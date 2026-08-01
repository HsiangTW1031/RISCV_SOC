# RISC-V SoC 專案 — Phase 0~7 說明

## Phase 0 — 基礎建設

這是整個專案的地基,沒做完後面全部卡住。四件事平行進行:

1. **裝 RISC-V toolchain**:用 xPack 的 `riscv-none-elf-gcc` 預編譯包(v15.2.0-1,darwin-arm64),下載解壓、加進 PATH 就能用,不用 brew tap 也不用從源碼編譯。
2. **1 天限時的 Ibex 備案測試**:花一天測 `sv2v` 能不能把 Ibex 的 SystemVerilog 轉成 Yosys 0.67 吃得下的 Verilog。這是唯一會影響「要不要換 CPU」決定的檢查點,做完就收斂,不拖。
3. **git 初始化**:`git init` + 寫 `.gitignore`(排除模擬產出、合成網表、firmware binary 這些)+ 建 GitHub repo + 第一次 commit。
4. **`run_flow.sh` 泛化**:目前這支腳本只認得單一 `.v` 檔,SoC 有幾十個檔案一定爆掉。要改成能讀 filelist、支援多檔案,`blocks/soc_top` 這種整合層要吃 `filelist/rtl.f`。

**出場條件**:裸的 PicoRV32 能在 Verilator 裡跑出 hello-world;git repo 建好且有乾淨的第一次 commit;`run_flow.sh` 對每個模組資料夾都能跑,多檔案模式也正常。

**估時**:2-3 天

---

## Phase 1 — 可跑的 SoC 骨架

第一個把東西「串起來」的階段。範圍刻意縮小:只接 3 個 slave(ROM、RAM、UART),先確保骨架能動,不急著把 8 個周邊都做完。

- 手寫 AXI-Lite crossbar 的第一版(1 master × 3 slaves)
- UART 只做 TX(先有輸出管道才能看到 firmware 到底有沒有跑起來)
- 寫 firmware 的啟動程式碼(`crt0`/`start.S`)、linker script
- 編一支「Hello World」firmware,燒進模擬的 boot ROM

**出場條件**:完整 SoC(CPU + crossbar + ROM/RAM + UART)跑真實編譯出來的 C 程式,把字元透過模擬 UART 印出來,而且 testbench 是自我檢查的、跑完會回傳 exit code 0。這是整個專案第一個「活的」里程碑 —— 代表 CPU 取指、AXI 交易、位址解碼、周邊寫入全部打通了。

**估時**:1-1.5 週

---

## Phase 2 — 中斷、Timer、Watchdog

開始把周邊一個一個加進去,同時第一次啟用中斷機制。

- **Timer**:向下計數,計數到底觸發 compare-match,拉 `irq[3]`
- **Watchdog**:要定期「餵狗」,逾時就發出 reset 請求
- firmware 端要用 PicoRV32 自己一套非標準的中斷指令(`getq`/`setq`/`retirq`/`maskirq`/`waitirq`)寫中斷處理常式 —— 這跟一般 RISC-V 標準 CSR 中斷模型不一樣,得照它的規矩來

**出場條件**:Timer 中斷確實觸發並被正確處理;Watchdog 逾時後的 reset 時序在逐週期比對的測試中驗證過;所有單元測試和整合測試都綠燈。

**估時**:約 1 週

---

## Phase 3 — I2C + SPI

補齊剩下兩個串列周邊,而且要讓它們有「真的東西」可以講話,不是空對空測試。

- I2C master:實作 START/STOP/ACK 的位元組層級狀態機
- SPI master:實作移位暫存器,支援 4 種 CPOL/CPHA 組合
- 各自寫一個「假的從屬裝置」(fake I2C EEPROM、SPI loopback slave)當測試對象

**出場條件**:I2C 和 SPI 都能跟假從屬裝置完成位元組精確的交易驗證;crossbar 這時候已經擴充到 7 個 slave。

**估時**:1-1.5 週

---

## Phase 4 — AES-128 加速器(履歷重點模組)

這是整個專案最能拿出來講的模組,要做得紮實。

- 逐輪迭代的資料路徑:Sbox、ShiftRows、MixColumns、AddRoundKey、金鑰展開
- AXI-Lite 暫存器介面讓 CPU 寫入金鑰/明文、啟動、讀回密文
- RTL 內部架構刻意切乾淨,方便之後想加 CBC/CTR 模式或 DMA 時不用重寫
- 驗證用兩層:FIPS-197 官方測試向量(基準回歸)+ 內嵌的軟體 AES 參考模型做幾百組隨機明文/金鑰的差分測試(不依賴外部 crypto 套件)

**出場條件**:所有官方測試向量和 500+ 組隨機向量都通過;程式碼覆蓋率 >85%;這個模組獨立做一次 Nangate45 合成 + STA,拿到可以寫進履歷的面積/時序數字。

**估時**:1.5-2 週

---

## Phase 5 — JTAG TAP + 除錯橋接

刻意延後到這裡才做,範圍也刻意收斂:只做系統匯流排存取,不做完整除錯規格(因為 PicoRV32 沒有 halt/resume 這些硬體鉤子,做完整規格等於要改第三方 core 內部)。

- 標準 IEEE 1149.1 TAP 狀態機(16 個狀態)
- 自訂的暫存器(`IDCODE`、`BYPASS`、位址/資料/控制暫存器),讓外部可以透過 JTAG 對 AXI bus 讀寫
- 這個橋接變成 crossbar 的第二個 master,crossbar 因此升級成真正需要仲裁的 2-master 架構

**出場條件**:TAP 狀態機單元測試通過;JTAG 寫入資料、CPU 讀得到,反過來也成立;crossbar 的仲裁邏輯驗證過;文件裡明確寫清楚「完整除錯規格為什麼不做」。

**估時**:1-1.5 週

---

## Phase 6 — (選配延伸)AXI4 Burst + AES DMA

這階段不是必要項目,MVP 拿掉它也完整。如果前面都做完還有餘力才做:

- 加一個 DMA master,能對 RAM 發真正的 AXI4 burst 交易(不再是單拍)
- AES 擴充 CBC/CTR 模式,重用 Phase 4 的資料路徑
- DMA 直接串流資料經過 AES,不需要 CPU 一個一個字搬

**出場條件**:DMA 能不經 CPU 介入,連續處理多個資料區塊通過 AES 加密,結果跟軟體參考模型一致。

**估時**:2 週以上,選配

---

## Phase 7 — 文件與 Sign-off

求職導向專案的重點收尾,建議不要全部留到最後、邊做邊補。

- 架構文件、記憶體映射文件、驗證總結表
- SoC 整體的 STA 報告和最高時脈估算
- 效能數據:典型迴圈的週期數、AES 的加密速度(MB/s)、中斷延遲
- 一個能一次跑過所有模組的 regression 腳本

**出場條件**:`docs/` 資料夾內容都更新到最新;每個模組的 `run_flow.sh` 都能一次跑完且全綠 —— 這樣履歷上才能寫出具體數字,不是空話。

**估時**:0.5-1 週(但建議貫穿整個專案持續累積,不要壓到最後)

---

**整體 MVP 範圍 = Phase 0 到 5 加上 Phase 7,大約 7-9 週的專注工時**,Phase 6 是完全可以捨棄的加分項,每個 phase 的邊界都設計成「就算在這裡停下來,也不會留下做一半的東西」。

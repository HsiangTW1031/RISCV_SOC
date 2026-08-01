# AES-128 加密引擎 — 詳細報告

這份文件是寫給「第一次接觸加密相關 IP」的讀者（就是 Levi 你自己）：不只講這個模組做了什麼，也講這個演算法從哪裡來、為什麼業界跟學界認為它安全、以及這個 RTL 實作在安全性上實際能不能打包票。介面層級的規格（register map、AXI 介面）請看 `docs/specs/aes.md`；這裡專注在演算法背景跟設計決策。

## 1. 這個模組實作的是什麼

**AES（Advanced Encryption Standard）**，128-bit key、128-bit block 的版本（AES 也有 192/256-bit key 版本，這個專案只做 128）。AES 是一種**對稱式 block cipher**：加密跟解密用同一把金鑰，每次處理固定 128 bits（16 bytes）的資料。

AES 的原始名稱是 **Rijndael**（比利時密碼學家 Joan Daemen 和 Vincent Rijmen 設計，名字是兩人姓氏的組合），1998 年提交參加美國 NIST（National Institute of Standards and Technology，美國國家標準與技術研究院）舉辦的 AES 甄選競賽，2000 年勝出，2001 年正式以 **FIPS-197**（Federal Information Processing Standard 197）的身分公布。這個專案的 S-box、MixColumns 係數、key schedule 全部照 FIPS-197 的定義來，細節見第 4 節。

## 2. 為什麼會有 AES：DES 的教訓

在 AES 之前，美國政府標準是 1977 年公布的 **DES（Data Encryption Standard）**，key 只有 56 bits。56 bits 在 1970 年代看起來夠大，但運算能力進步太快：1998 年電子前哨基金會（EFF）打造專用硬體 **Deep Crack**，隔年（1999）搭配 distributed.net 的分散式運算資源，**在不到 24 小時內就用暴力法（brute force）試出了一把 DES 金鑰**。這證明 56-bit key 在現代運算力下已經不是「安全邊際」，而是「遲早會被暴力破解」的問題。業界先用 Triple DES（3DES，等於連續做 3 次 DES）當過渡方案，但 3DES 效能差、設計上也是妥協之作，於是 NIST 在 1997 年啟動 AES 甄選，公開徵求全世界密碼學家提案、公開分析、公開投票，最後選出 Rijndael。

這段歷史是理解「為什麼 AES 的 key size 選 128/192/256」的關鍵：**key size 要留夠大的安全邊際，大到即使運算能力持續進步幾十年，暴力破解依然不可行**。

## 3. 為什麼現在還認為 AES-128 安全

### 3.1 Brute force（暴力破解）的邊際
AES-128 的 keyspace 是 2^128，一個大到很難直覺想像的數字。就算全世界所有的運算資源全部拿來做暴力破解，在可預見的未來也不可能窮舉完 2^128 種可能——這不是「很難」，是「在目前物理與工程的極限下不可行」的等級。

### 3.2 已知最好的攻擊：Biclique attack
密碼學界對 AES 做了超過二十年的公開分析，目前公開已知**最好**的對 full-round AES 的攻擊，是 2011 年 Bogdanov、Khovratovich、Rechberger 三人發表的 **biclique attack**：把 AES-128 的有效安全性從理論上的 2^128 降到大約 **2^126.1**。這聽起來是個「突破」，但實務上完全沒有意義——2^126.1 跟 2^128 一樣都遠遠超出可行運算的範圍，這個結果的價值是學術上的（證明 AES 不是「完美」的理論上限），而不是實務上的威脅。**目前沒有任何已知、公開、對 full-round AES-128 實際可行的破解方法**。

### 3.3 官方認證與國際標準地位
- **FIPS-197**（2001）：美國聯邦政府資訊系統的正式標準。
- 美國國安單位（NSA/CNSS）核准 **AES-128 可用於 SECRET 等級機密資料，AES-192/256 可用於 TOP SECRET 等級**（近年 NSA 的新一代準則 CNSA 建議所有等級一律採用 AES-256，這是「更保守」的政策調整，不是說 AES-128 被攻破了）。
- **ISO/IEC 18033-3**：AES 也被納入國際標準組織的 block cipher 標準，不是只有美國自己在用。
- 二十多年來全世界密碼學界公開分析、公開發表攻擊研究，AES 是被檢驗最徹底的演算法之一，至今屹立不搖，這種「經得起長時間公開檢驗」本身就是信任的重要來源（跟「沒人研究過所以看起來安全」完全不同）。

### 3.4 這個 RTL 實作本身沒有的保證（重要免責聲明）
上面講的是**演算法**本身的安全性，不代表**這個具體的 RTL 實作**可以直接拿去做真正的安全產品。這個實作：
- **沒有做 side-channel 防護**：真正的安全晶片需要防範 power analysis（透過功耗變化推測金鑰）、cache-timing attack（軟體實作常見）等旁路攻擊，這需要額外的硬體對策（例如 masking），這個專案沒有做。
- 好消息是：這個 FSM 設計**天生是固定 cycle 數**（不管明文/金鑰內容是什麼，永遠是 ~21 cycles），這對抵抗「用執行時間長短推測資料」的 timing attack 有天然的幫助——但 S-box 用組合邏輯查表實現時，仍可能在功耗上洩漏資訊，這是之後如果要做成真正安全 IP 需要加強的地方。
- 這個模組的定位是**教育 / 履歷作品**：目的是紮實地做對 FIPS-197 演算法本身、用嚴謹的方法驗證正確性、並取得真實的合成/時序數字，而不是宣稱這是一個可以量產的安全晶片。

## 4. 這個實作內部怎麼運作（對照 FIPS-197）

AES-128 的核心運算建立在 **GF(2^8)**（一個 256 個元素的有限體/Galois Field）上，每個 byte 被當成這個體裡的一個元素。四個基本變換，每一輪（round）依序做：

1. **SubBytes**：查一張 256 進 256 出的 substitution table（S-box），對 state 裡每個 byte 獨立做非線性替換。S-box 的推導方式：先算這個 byte 在 GF(2^8) 裡的乘法反元素（reduction polynomial 是 x^8+x^4+x^3+x+1，也就是 0x11B），再套一個固定的仿射變換（affine transform）。**這個專案的 S-box 表不是從網路上抄來的**——是寫一支 Python 腳本從頭算出這 256 個值，再拿 FIPS-197 公開的幾個已知值（例如 S-box[0x00]=0x63）交叉驗證，確認算法正確後才转成 Verilog 的查表函式。
2. **ShiftRows**：把 state（4x4 的 byte 矩陣）的每一列循環左移，列 r 左移 r 格。
3. **MixColumns**：把每一欄的 4 個 bytes 當成 GF(2^8) 上的一個多項式，乘上一個固定的矩陣（係數 2, 3, 1, 1 循環排列）。乘法用 `xtime`（乘 2）這個基本操作組合出來（乘 3 = xtime(a) xor a，以此類推）。
4. **AddRoundKey**：跟這一輪的 round key 做 XOR。

**解密**（InvSubBytes、InvShiftRows、InvMixColumns，反向逐輪）用的是 FIPS-197 5.3 節定義的「直接反向」（Straightforward Inverse Cipher），不是後來為了 硬體效率重排過的「Equivalent Inverse Cipher」——選直接反向版本是因為它跟規格書的定義一一對應，比較容易驗證跟解釋，代價是加密和解密的 round 結構不完全相同（沒有共用同一套硬體）。

**Key schedule**（`aes_key_expand.v`）：11 把 round key 在 START 當下一次展開完（10 個 clock cycle，一個 cycle 產生一把），存進暫存器陣列。之所以不是「邊加密邊即時展開」，是因為**解密方向需要從最後一把 round key（rk10）開始用**，而 rk10 沒辦法不先算完整個 schedule 就生出來——所以無論加密解密，都先把 11 把 key 全部準備好再開始跑 round。

## 5. 驗證方法（信心的來源）

寫這種演算法最大的風險是「RTL 看起來邏輯自洽，但跟真正的 AES 定義有一個不容易發現的偏差」。這個專案用了四層互相獨立的驗證，層層加強信心：

1. `aes_key_expand` 單獨測試：11 把 round key 逐一比對 **FIPS-197 Appendix A.1** 官方公布的金鑰展開範例。
2. `aes_core`（round 邏輯本身，不含 AXI）：**FIPS-197 Appendix B** 和 **Appendix C.1** 兩組官方明文/金鑰/密文三元組，加密、解密兩個方向都測。
3. 透過真正的 AXI4-Lite 暫存器介面（`aes.v`）再測一次同樣的官方向量，確保「介面接線」本身沒有把 byte 順序接反這類低級錯誤。
4. **Differential test**：另外用 C++ 寫一份完全獨立、從零開始的軟體 AES-128（S-box/Rcon 表在程式一啟動時用另一套獨立程式碼現算，不是複製同一份表），跑 500 組隨機明文/金鑰，比對 RTL 跟軟體模型的密文是否一致，並確認 `decrypt(encrypt(pt)) == pt`。這支軟體模型自己也要先通過 FIPS-197 官方向量才會被信任當作比對基準（oracle）。

四層都通過之後，才有理由相信這個實作真的照著 FIPS-197 的定義做對了，而不是「剛好兩組官方向量矇對」。

## 6. Synthesis + STA 結果（Nangate45）

`blocks/aes/syn/synth.ys`（Yosys）針對 `aes_core.v`（含 `aes_key_expand.v`，不含 AXI wrapper——wrapper 只是暫存器跟 mux，面積可忽略）合成，`blocks/aes/sta/sta.tcl`（OpenSTA）做時序分析，都使用開源的 **Nangate45** cell library（45nm 製程的公開標準元件庫，學術界常用的參考製程）。

- **面積**：`aes_core` 總計約 **39,406 μm²**（含 `aes_key_expand` 子模組的 17,769 μm²），其中約 29.7% 是循序邏輯（flip-flop）。
- **關鍵路徑（critical path）**：10.153 ns，**落在 `aes_key_expand` 內部**，不是原本預期的 round 資料路徑（SubBytes/MixColumns 那條組合邏輯鏈）。實際路徑是：round-key 暫存器陣列的**可變位址讀取**（`rk[round_idx-1]`，用 `round_idx` 這個變數去索引 11 組 128-bit 暫存器）在合成後變成一棵有龐大扇出（fanout，一顆閘要驅動很多下游閘）的 11 選 1 多工器（mux）樹，這是這條路徑上出現異常大的 output capacitance（例如某個 NOR2 閘要驅動 795 fF 的負載）的原因。
- 換算成頻率：**Fmax ≈ 1 / 10.153ns ≈ 98.5 MHz**。
- 這是一個誠實、可以在履歷/面試裡直接討論的數字，也是一個現成的「如果要優化會怎麼做」的話題：既然瓶頸是 key schedule 的可變位址讀取，下一步優化方向會是把這個讀取拆成多一級 pipeline register，或者改成用 shift-register 方式取代「11 選 1 陣列讀取」（因為 round key 的使用順序其實是固定的，加密是 0→10、解密是 10→0，不需要真正隨機存取），藉此把這條長路徑打斷成兩段更短的路徑。這個專案目前刻意保留現狀，把它當作「已知、有明確根因、有明確優化方向」的設計取捨紀錄，而不是隱藏起來的問題。

## 7. 小結

這個模組做到的事：忠實照 FIPS-197 實作了 AES-128 加密與解密的完整 round 邏輯與 key schedule，每一個查表跟係數都從數學定義重新推導、交叉驗證過，而不是複製貼上；用四層獨立方法驗證正確性；在真實製程庫上取得了誠實的面積與時序數字，並且知道瓶頸在哪裡、為什麼在那裡。這個模組**沒**做到、也不宣稱做到的事：side-channel 防護、可量產的安全等級保證——這些是這份報告刻意講清楚的邊界。

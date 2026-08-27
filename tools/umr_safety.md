# UMR 安全分級與使用規範

> **執行任何 UMR 命令前必讀。** 本文的每一條鐵律都是撞死過 host 換來的。

## 0. 核心安全分級

UMR 的存取路徑分成兩類，混用會殺 host。「UMR 安全」這句話**只對 debugfs 路徑成立**，不能一概而論。

| 類別 | 路徑 | 機制 | 安全性 |
|------|------|------|--------|
| 安全 | `02_umr_queue_doctor.py`（讀 `/sys/kernel/debug/kfd/mqds`） | KFD debugfs 記憶體 | 永遠安全 |
| 安全 | `03_dump_sdma_registers.sh` / `04_dump_kfd_snapshots.sh` | debugfs / kernel-mediated | 永遠安全 |
| 安全 | `umr --script instances` / `xcds` / `-r <reg>` | discovery / debugfs register | 永遠安全 |
| **致命** | `umr --tool cpc` | 直讀 CPC 微控制器 MMIO | **條件性殺 host** |
| **致命** | `umr -O bits,halt_waves` | 主動 halt GPU waves via MMIO | **條件性殺 host** |

## 1. cpc / waves 鐵律

每一條都是實際撞死 host 後歸納出來的，不可省略任何一條。

### 1.1 只跑 XCC 0-3

8-XCC 全迴圈（0-7）**歷史上零次存活記錄**，撞死過 host。0-3 是唯一有存活記錄的範圍。

### 1.2 只對 hung GPU 執行

動態偵測 `util >= 95` 的卡，不要寫死某一顆。每輪 hang 的卡都不同（曾出現過單 GPU4、單 GPU6、GPU4+6、GPU4+5+6 等組合）。

### 1.3 每個 XCC 獨立呼叫 + 三重保護

```bash
# 每個 XCC 一次呼叫，用 timeout 包住
timeout 30 sudo umr -i <INST> -vmp <0..3> --tool cpc -O no_backtrace
# 每次呼叫後檢查 host 存活
uptime || { echo "HOST DEAD ABORT"; exit 1; }
```

- 每呼叫後做 uptime 檢查
- 偵測到 HOST DEAD 立即 abort，不要繼續下一個 XCC

### 1.4 背景執行 + 輪詢，不要前景等待

用 `nohup` 背景跑並輪詢 log，**絕對不要**用單一 SSH channel 前景 `stdout.read()` 等待。48 次呼叫會超過 remote exec 的 600s timeout，PipeTimeout 會被誤判成 host 死掉。

### 1.5 絕不使用 05 的預設全卡模式

`05_dump_all_cpc_info.sh` 內建 `for gpu in $(umr --script instances)` 掃全 8 卡，而且會 auto 寫 `halt_if_hws_hang=1`。**這個組合就是 host-killer**，不要直接跑。

### 1.6 exact 指令格式

```bash
# cpc（INST 為 UMR instance，非 GPU 編號）
sudo /usr/local/bin/umr -i <INST> -vmp <0..3> --tool cpc -O no_backtrace

# waves
sudo /usr/local/bin/umr -i <INST> -vmp <0..3> -O bits,halt_waves,no_backtrace -wa none
```

instance 編號用 `umr --script instances` 查，不要臆測。

## 2. cpc 不是確認 hang 的必要條件

判定 hang 的鐵證是 **wptr ≠ rptr 且跨多次 snapshot 凍結不動**，這個從安全路徑（queue_doctor 讀 debugfs）就拿得到。

CP 內部暫存器（cpc）是加分項，不是必需品，而且也可以從離線 scandump 安全取得。**不要為了拿 cpc 而冒殺 host 的風險。**

### 來源差異（重要）

關於 CPC 採集，目前有兩份互相衝突的實測經驗：

| | MI308X 現場實測（本文採用） | 上游採集 Recipe |
|---|---|---|
| `05_dump_all_cpc_info.sh` 預設模式 | host-killer，絕不可跑 | 列為標準採集項，正常執行 |
| XCC 範圍 | 只能 0-3，0-7 全迴圈零次存活 | 未設限制 |
| `06` 執行方式 | 必須 `--skip-cpc --skip-waves` | 完整模式 |

差異可能來自 ASIC 型號、driver 版本或 XCD 配置。**rockit 取保守值為預設**：
先假設會殺 host，需要 CPC 時走本文的安全包裝版。

若你的環境已驗證完整模式安全（專用 debug 節點、已知 ASIC/driver 組合），可以使用
完整模式，但在新環境第一次使用前務必先小規模驗證，不要直接套用他人的成功經驗。

## 3. GPU instance index 與 CPU 平台

UMR 會根據 CPU 平台調整 GPU instance index：

| CPU 平台 | UMR index 行為 | 你要做什麼 |
|---------|---------------|-----------|
| AMD CPU | UMR 自動 +2 | 直接用，不需調整 |
| Intel CPU | 需要手動 -2 | instance index 要減 2 |

**為什麼：** UMR 設計時假設 AMD CPU 平台（iGPU 等佔了前面的 index）。Intel CPU 沒有這些裝置，不做 -2 會指到錯誤的 XCC，讀到的暫存器值是錯的。

實務上直接查 `umr --script instances` 的輸出最保險，不要自己算。

## 4. 不要用 PID 判斷 GPU instance

用 PID 推斷 GPU instance 不可靠。正確做法是用 PCI BDF 做對應：

```bash
umr --script instances                    # UMR instance 列表
ls -l /sys/class/drm/card*/device         # DRM card → PCI BDF
cat /sys/class/kfd/kfd/topology/nodes/*/properties | grep -E 'node_id|location_id'
```

## 5. 快速檢查表

執行 cpc/waves 前逐項確認：

- [ ] 已從 queue_doctor 確認 wptr ≠ rptr（真的是 hang）
- [ ] 已動態偵測出 hung GPU（util >= 95），沒有寫死
- [ ] XCC 範圍限制在 0-3
- [ ] 每個 XCC 獨立呼叫，有 `timeout 30`
- [ ] 每次呼叫後有 uptime 檢查
- [ ] 用 nohup 背景跑，不是前景等待
- [ ] 沒有直接跑 `05_dump_all_cpc_info.sh` 預設模式

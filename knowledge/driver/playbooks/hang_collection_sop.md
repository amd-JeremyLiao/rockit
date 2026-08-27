# GPU Hang 完整日誌採集 SOP

> 適用於 ROCm workload 已進入 hang 後，抓取可用於分析 AQL / KFD / CPC / waves /
> SDMA / CLR 的完整 debug bundle。
>
> **執行前必讀** [tools/umr_safety.md](../../../tools/umr_safety.md)。

## 目標與範圍

**本 SOP 負責：**
- 保留 hang 現場，不 reset GPU、不重啟容器、不 kill 目標 process
- 記錄採集前後的 PID、業務進度、GPU utilization/VRAM 簽名
- 抓取 Queue Doctor full-ring raw/decoded、KFD runlist/MQD/HQD/dmesg、連續 queue trace
- 抓取 SDMA、waves、AQL queue、CLR runtime log
- 驗證日誌完整性以及採集過程中現場是否變化
- 產出 bundle 目錄與內容一致的 `.tgz`

**本 SOP 不負責：** 啟動或重建 workload、製造 hang、GPU reset、多輪 benchmark、判定最終 root cause。

## 環境佔位符

| 佔位符 | 說明 |
|--------|------|
| `<TARGET_HOST>` | 發生 hang 的目標機器 |
| `<GPU_BMC>` / `<CPU_BMC>` | GPU box / CPU box 的 BMC 位址 |
| `<DATA_DIR>` | 落盤目錄（獨立資料碟，非 root fs） |
| `<UPLOAD_HOST>` | 收檔機器 |

---

## 1. 安全邊界

### 1.1 採集期間絕對不要做的事

目標 process 必須全程存活。process 退出後，KFD queue metadata、GPUVM、AQL ring、
signal、MQD/HQD 對應關係可能已釋放或改變。

- 重啟容器
- kill server / client
- reset GPU
- reload `amdgpu`
- 啟動第二個完整 collector
- 修改 workload 環境變數
- 在採集完成前停止業務流量

### 1.2 會改變系統狀態的操作

本流程不是完全唯讀，以下操作需先確認影響：

| 操作 | 影響 |
|------|------|
| `sudo dmesg -C` | 清空當前 kernel ring buffer（不刪 journal 持久化歷史）。共享節點預設不要執行 |
| `15_trace_kfd_queue.sh capture` | 改 KFD dynamic-debug，設 `debug_evictions=1` 和 `halt_if_hws_hang=1`。應在 workload 啟動前開，採集後用 `disable` 還原 |
| CPC collector | 設 `halt_if_hws_hang` 並讀大量 CP/HQD/wave 狀態，可能使 GPU telemetry 顯示 `N/A`。**不要把 telemetry N/A 直接解釋成 workload 已退出** |
| AQL GDB collector | 會 attach 目標 process，可能短暫停頓或擾動。絕對不能被 debugger 觸碰時用 `--skip-aql-queue`，但 bundle 將缺少完整 GDB AQL 解碼 |

### 1.3 敏感資料

full-ring、AQL、signal、GDB 輸出可能包含 GPU/host virtual address、signal handle、
process/container 資訊、已消費但未覆蓋的歷史 packet、kernel object 與 kernarg 位址。
**不要把原始 bundle 上傳到公開服務。**

---

## 2. 相依工具與版本記錄

### 2.1 debug_scripts

rockit 已將其納入 submodule：

```bash
export DEBUG_SCRIPTS_DIR="$PWD/tools/debug_scripts"
git -C "$DEBUG_SCRIPTS_DIR" rev-parse HEAD
```

交付時必須記錄實際 commit，**不要只寫「latest」**。不要混用舊副本或
`debug_scripts_deprecated` 裡的腳本。

### 2.2 UMR

```bash
cd "$DEBUG_SCRIPTS_DIR"
./00_pull_build_umr.sh          # 不要用 root 跑整個 build

export UMR_DIR="${UMR_DIR:-$HOME/umr}"
git -C "$UMR_DIR" rev-parse HEAD
"$UMR_DIR/build/src/app/umr" -h
```

建議 UMR `1.0.11` 以上並確認支援目標 ASIC。CPC 介面用當前的 `--tool cpc` 語法，
不要用已廢棄的 `-cpc`。

### 2.3 主機依賴

Linux + AMDGPU/KFD、Bash 4.4+、Python 3.8+、`sudo`、`git`、`jq`、`ripgrep`、`tar`、
`rocm-smi`、`/opt/rocm/bin/amd-smi`、debugfs、可讀 `/proc/<PID>` 與 `/sys/kernel/debug/kfd`。

```bash
mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug

python3 -m py_compile "$DEBUG_SCRIPTS_DIR/02_umr_queue_doctor.py"
bash -n "$DEBUG_SCRIPTS_DIR/06_collect_all_gpu_debug.sh"
"$DEBUG_SCRIPTS_DIR/15_trace_kfd_queue.sh" status
```

---

## 3. 各 collector 抓什麼

| 腳本 | 抓取內容 | 用途 |
|------|---------|------|
| `02_umr_queue_doctor.py` | 依 PID 列舉 KFD queues、映射 GPU ID/KFD node/XCC/HQD、連續抓 RPTR/WPTR、完整物理 AQL ring（raw `.bin` + decoded `.txt`） | 判斷 `WPTR > RPTR`、RPTR 是否連續不動、當前 RPTR 處 packet、識別 INVALID/Barrier/Dispatch |
| `03_dump_sdma_registers.sh` | status / GFX / PAGE / RLC / XNACK 暫存器 | 排除或識別 SDMA queue/engine 停滯，區分 compute hang 與 copy path hang |
| `04_dump_kfd_snapshots.sh` | 連續多份 KFD debugfs（runlist / MQD / HQD）+ dmesg 靜態快照 + DRM scheduler/fence trace | 識別 queue active/evicted、對齊 MQD 與 HQD、觀察 map/unmap/evict/restore |
| `05_dump_all_cpc_info.sh` | 每張 GPU 每個 XCC 的 CP/HQD、PQ、RPTR/WPTR、doorbell、AQL control | 判斷 queue 是否仍映射在 HQD、分析 CP/CPF/MEC 狀態。**見第 5 節安全限制** |
| `08_dump_all_gpu_waves.sh` | 所有目標 GPU/XCC 的 wave 狀態 | 區分 CP-side stall 與仍有 active waves 的 kernel stall |
| `13_dump_aql_queues_gdb.sh` | attach 後從 ROCr/CLR 進程內結構列舉 queues、解碼 AQL/SDMA packets、讀 signal | 取得 queue 邏輯結構、關聯 barrier dependency 與 completion signal |
| `15_trace_kfd_queue.sh` | workload 全生命週期的 KFD dynamic-debug 時序 | queue create/destroy、runlist、map、evict、restore 時序 |

**continuous trace 與 `dmesg-final.txt` 不可互相取代：** 前者是全生命週期動態時序，
後者只是 collector 執行當下的 ring buffer 靜態快照。

---

## 4. 建議時序

最完整的採集要求在 **workload 啟動前**就完成準備：

```
1.  記錄工具 commit 與環境版本
2.  可選：清空本輪 dmesg（共享節點跳過）
3.  開啟 continuous KFD trace          ← 必須在 workload 之前
4.  啟動 workload（含 AMD_LOG_LEVEL 等 CLR log 設定）
5.  開啟 1 秒 GPU telemetry
6.  等待並確認 hang
7.  保存採集前現場簽名
8.  先暫存 CLR log
9.  執行 06 統一 collector
10. 保存採集後現場簽名
11. 比對 PID / stats / GPU 簽名
12. 合併 CLR log 和 continuous KFD trace
13. 重新產生 archive
14. 驗證 bundle 完整性
15. 確認完成後才停止 trace 或處理 workload
```

**如果 workload 已經 hang 但之前沒開 continuous trace：** 仍可抓 Queue Doctor、
KFD 靜態快照、CPC、waves、AQL、CLR。但報告必須註明缺少 hang 形成過程的 KFD 時序。
**不要把「hang 後啟動的空 trace」解釋為 hang 前沒有 queue 操作。**

**CLR log 環境變數必須在 workload 啟動時就設**，hang 後才設無效（runtime 已初始化）：

```bash
AMD_LOG_LEVEL=4
AMD_LOG_ASYNC=1
AMD_LOG_LEVEL_FILE=<container-visible log prefix>
```

CLR log 要透過 host bind mount 或明確複製方式保存。高 log level 漲得快
（LEVEL=5 單份約 1.8GB vs LEVEL=4 約 1GB），跑多輪要盯磁碟空間。

workload 跑在 container 裡時，可用現成腳本撈：

```bash
tools/debug_scripts/09_collect_docker_amd_log.sh --pid <PID>
# 或指定容器
tools/debug_scripts/09_collect_docker_amd_log.sh --container <NAME>
```

### 4.1 hang 觸發後的三階段順序

偵測到 hang（monitor log 出現疑似 hang 標記）後，採集要照這個順序，**不可調換**：

| 階段 | 內容 | 為什麼是這個順序 |
|------|------|-----------------|
| **STAGE 1 安全** | `06_collect_all_gpu_debug.sh --skip-cpc --skip-waves --skip-aql-queue`<br>（queue_doctor 約 13 分鐘 + sdma + kfd） | 全部走 debugfs，不會殺 host，先把最可靠的證據拿到手 |
| **STAGE 2 CLR log** | 複製 runtime log 到 bundle | **必須在 CPC 之前**。CPC 可能 abort 或殺 host，那時 CLR log 就撈不到了 |
| **STAGE 3 CPC / waves** | 背景執行安全包裝版（見第 5 節） | 風險最高，放最後。即使這階段失敗，前兩階段的資料已經落盤 |

`--skip-cpc --skip-waves` **不是放棄 CPC**，只是把它移到 STAGE 3 用安全方式跑。
UMR 內部的 queue_doctor / kfd / sdma / full-ring 一個都沒有 skip。

自動化採集時（由 watchdog 腳本觸發），同樣照這個順序，且 STAGE 3 要用 nohup
背景執行 + 輪詢 log，不要讓 watchdog 卡在前景等待。

---

## 5. CPC / waves 的安全限制（重要）

rockit 對 CPC 採集採**保守預設**。原因見 [umr_safety.md](../../../tools/umr_safety.md)：
`--tool cpc` 和 `-O bits,halt_waves` 走 MMIO 直讀，在部分環境會殺 host。

### 5.1 預設：跳過 CPC / waves

```bash
sudo env "PATH=$PATH" \
  "$DEBUG_SCRIPTS_DIR/06_collect_all_gpu_debug.sh" \
    --pid "$TARGET_PID" "${GPU_ARGS[@]}" \
    --samples 3 --interval 2 --vmp "$VM_PARTITION" --full-ring \
    --skip-cpc --skip-waves \
    --output-dir "$BUNDLE"
```

判定 hang 的鐵證是 queue_doctor 的 `wptr != rptr` 且跨 snapshot 凍結不動，
**不需要 CPC**。CPC 是加分項，也可從離線 scandump 安全取得。

### 5.2 需要 CPC 時：安全包裝版

不要跑 `05_dump_all_cpc_info.sh` 預設模式（內建 8 卡全迴圈 + auto 寫
`halt_if_hws_hang=1`）。改用手動安全版：hung GPU only、XCC 0-3、每個 XCC 獨立呼叫、
`timeout 30`、每次檢查 uptime、nohup 背景跑。完整鐵律見
[umr_safety.md](../../../tools/umr_safety.md)。

### 5.3 完整模式（僅限已知安全的環境）

若你的環境已驗證 CPC 全模式不會殺 host（例如專用 debug 節點、已知 ASIC/driver 組合），
可以跑完整模式：

```bash
sudo env "PATH=$PATH" \
  "$DEBUG_SCRIPTS_DIR/06_collect_all_gpu_debug.sh" \
    --pid "$TARGET_PID" "${GPU_ARGS[@]}" \
    --samples 3 --interval 2 --vmp "$VM_PARTITION" --full-ring \
    --output-dir "$BUNDLE"
```

> **來源差異說明：** 上游 Recipe 將 CPC/waves 列為標準採集項並以完整模式執行；
> MI308X 現場實測則發現 8-XCC 全迴圈會殺 host，必須限制在 XCC 0-3。
> 兩者可能因 ASIC、driver 版本或 XCD 配置而異。rockit 取保守值為預設，
> 在新環境使用完整模式前請先小規模驗證。

**絕對不要**在第一個 `06_collect_all_gpu_debug.sh` 還在跑時啟動第二個。

---

## 6. Hang 判定前置條件

至少確認以下八項，**不要只根據 GPU=100% 就判定 hang**：

- 容器 / process 仍存活
- host PID 沒有變化
- workload 之前曾正常輸出業務 stats
- 最近約 60 秒沒有新 stats
- 至少一張目標 GPU 為 100%
- GPU VRAM 仍被目標 process 佔用
- 不是所有目標 GPU 都已降為 0%
- CLR log 檔案存在且非空

```bash
docker inspect -f 'pid={{.State.Pid}} running={{.State.Running}}' "$SERVER_CONTAINER"
docker logs --timestamps --since 65s "$SERVER_CONTAINER" 2>&1 | awk '/\[stats\]/{print}'
rocm-smi -d "${OBSERVE_GPUS[@]}" --showuse --showmemuse --csv
[[ -s "$CLR_LOG_HOST_PATH" ]]
[[ -d /proc/$TARGET_PID ]]
```

業務沒有 `[stats]` 格式時，必須換成該 workload 的真實進度指標。

**soft-freeze 特徵：** GPU util 出現 0%/100% 混合（hung 的卡 100% spin，其餘 0%）+ QPS 掉到 0。

---

## 7. 現場簽名與完整性驗證

這是判斷 bundle 是否有效的關鍵，不可省略。

### 7.1 採集前簽名

```bash
export CAPTURE_TS="$(date +%Y%m%d_%H%M%S)"
export BUNDLE="$RESULT_ROOT/${CAPTURE_TS}-${TARGET_PID}-gpu-hang-full-log"
export CONTROL="${BUNDLE}.control"
mkdir -p "$CONTROL"

{
  printf 'time=%s\n' "$(date --iso-8601=ns)"
  printf 'target_pid=%s\n' "$TARGET_PID"
  rocm-smi -d "${OBSERVE_GPUS[@]}" --showuse --showmemuse --csv
  docker logs --timestamps "$SERVER_CONTAINER" 2>&1 |
    awk '/\[stats\]/{last=$0} END{print "latest_stats=" last}'
} >"$CONTROL/scene-pre.txt" 2>&1

git -C "$DEBUG_SCRIPTS_DIR" rev-parse HEAD >"$CONTROL/debug-scripts-commit.txt"
git -C "${UMR_DIR:-$HOME/umr}" rev-parse HEAD >"$CONTROL/umr-commit.txt"
```

在 debugger collector 之前先暫存 CLR log：

```bash
mkdir -p "$CONTROL/clr_logs"
cp --reflink=auto --sparse=always --preserve=timestamps \
  "$CLR_LOG_HOST_PATH" "$CONTROL/clr_logs/server_amdlog_1.txt"
```

### 7.2 採集後簽名與比對

```bash
mkdir -p "$BUNDLE/scene-integrity"
# ...產生 scene-post.txt（欄位同 scene-pre）...
cp "$CONTROL/scene-pre.txt" "$BUNDLE/scene-integrity/scene-pre.txt"
diff -u "$BUNDLE/scene-integrity/scene-pre.txt" \
        "$BUNDLE/scene-integrity/scene-post.txt" \
        >"$BUNDLE/scene-integrity/scene.diff" || true
```

`scene.diff` 一定含時間戳，**不能只憑 diff 非空就判定現場變化**。要人工確認：

- PID 相同
- container 仍 running
- 最後一條業務 stats 沒有推進
- 目標 GPU utilization/VRAM 簽名沒有實質變化
- 至少一張目標 GPU 採集後仍為 100%

現場若真的變了，建立警告檔並**保留 bundle 不要刪**：

```bash
printf '%s\n' 'Hang scene changed during collection; this bundle may be invalid.' \
  >"$BUNDLE/scene-integrity/WARNING_LOG_MAY_BE_INVALID.txt"
```

### 7.3 Bundle 完整性驗證

`06` 產生的 archive 不含之後複製的 CLR 和 continuous trace，合併後必須重新打包。

最少驗證項目：

```bash
[[ ${CAPTURE_RC:-1} -eq 0 ]]
rg -q '^final_failures=0$' "$BUNDLE/summary.txt"
[[ -s "$BUNDLE/queue_doctor/report.json" ]]

RAW_COUNT=$({ rg --files "$BUNDLE/queue_doctor" | rg '/full-ring/.*\.bin$' || true; } | wc -l)
DECODED_COUNT=$({ rg --files "$BUNDLE/queue_doctor" | rg '/full-ring/.*\.decoded\.txt$' || true; } | wc -l)
[[ "$RAW_COUNT" -gt 0 ]]
[[ "$RAW_COUNT" -eq "$DECODED_COUNT" ]]

[[ -s "$BUNDLE/sdma_registers.txt" ]]
[[ $(rg --files "$BUNDLE/kfd" | wc -l) -gt 0 ]]
[[ -s "$BUNDLE/clr_logs/server_amdlog_1.txt" ]]
[[ -f "${BUNDLE}.tgz" ]]

# 確認沒有混到 deprecated 腳本
! rg -q 'debug_scripts_deprecated' "$BUNDLE/commands.txt" "$BUNDLE/collector.txt"
```

完整模式（含 AQL GDB）額外驗證：

```bash
[[ -s "$BUNDLE/aql_queue_dump/aql_packet_decode_gdb.txt" ]]
rg -q 'Enumerated [1-9][0-9]* queue' "$BUNDLE/aql_queue_dump/aql_packet_decode_gdb.txt"
```

產生驗證檔：

```bash
{
  printf 'capture_rc=%s\n' "${CAPTURE_RC:-unknown}"
  printf 'raw_full_ring_count=%s\n' "$RAW_COUNT"
  printf 'decoded_full_ring_count=%s\n' "$DECODED_COUNT"
  printf 'target_pid_alive=%s\n' "$([[ -d /proc/$TARGET_PID ]] && echo yes || echo no)"
  printf 'archive=%s\n' "${BUNDLE}.tgz"
} >"$BUNDLE/verification.txt"
```

---

## 8. Bundle 結構

```
<bundle>/
├── collector.txt / commands.txt / summary.txt / system_info.txt
├── queue_doctor/
│   ├── report.json / summary.txt
│   └── .../full-ring/*.bin + *.decoded.txt
├── sdma_registers.txt
├── kfd/            snapshot-*/ , dmesg.txt , dmesg-final.txt
├── cpc/            *_umr_cpc_gpu*_xcc*.txt , *_summary.txt
├── waves/          *_waves_gpu*_xcc*.txt , *_summary.txt
├── aql_queue_dump/ aql_packet_decode_gdb.txt
├── clr_logs/       server_amdlog_1.txt
├── kfd_trace/      kfd-queue-continuous.log
├── telemetry/      gpu-util-1s.log
├── scene-integrity/ scene-pre.txt , scene-post.txt , scene.diff
│                    [WARNING_LOG_MAY_BE_INVALID.txt]
├── debug-scripts-commit.txt / umr-commit.txt
└── verification.txt

<bundle>.tgz
```

---

## 9. 中斷與失敗處理

1. 檢查目標 PID 是否仍存活
2. 檢查是否仍有 `06`、Queue Doctor、UMR、GDB 子進程
3. **不要並行啟動第二個 `06`**
4. 將 bundle 標記為 `aborted-partial`
5. 保留 `collector.txt`、`commands.txt` 和所有已產生的 raw 檔
6. 現場已變化時，不要把剩餘步驟拼接成「完整 bundle」
7. decode 失敗時保留 full-ring raw `.bin`，不要只留錯誤日誌
8. 目標 process 退出時，記錄退出時間、dmesg、container 狀態，不要偽裝成有效 hang 現場

---

## 10. 判斷 host 死活（防誤殺）

**絕不憑單次 ping / SSH 失敗就判定 host 死了。** soft-freeze 或 scandump 期間
host 網路會間歇不可達，這是正常現象。

判死三步驟：

1. 至少 5 次 ping、有間隔地重試
2. SSH 重連數次
3. 讀 host 上採集 log 是否有 `HOST DEAD ABORT` 標記

scandump 進行中 host ping 不通是預期的（帶外存取），此時一律不要碰 host。

BMC power cycle 是最後手段。誤判而 cycle 會清掉正在跑的採集和 hang 事件本身。

---

## 11. 採集完成後的清理

只有在 bundle 完成並確認不再需要原現場後，才停止 telemetry 和 trace：

```bash
kill "$TELEMETRY_PID" 2>/dev/null || true
kill -TERM -- "-$KFD_TRACE_PGID" 2>/dev/null || true
"$DEBUG_SCRIPTS_DIR/15_trace_kfd_queue.sh" disable
"$DEBUG_SCRIPTS_DIR/15_trace_kfd_queue.sh" status   # 記錄還原後的模組參數
```

不要在另一輪除錯仍依賴 `halt_if_hws_hang=1` 時執行全域 `disable`。

---

## 12. 重開機 SOP

前置條件：已依第 10 節確認 host 真的死了，或使用者明確下令。

1. **BMC power cycle：** GPU box `<GPU_BMC>` 先，等 30 秒，CPU box `<CPU_BMC>` 後。**順序不可反。**
2. **等開機 3-5 分鐘：** 連續多次 ping 都有回應才算好
3. **載入 driver：**
   ```bash
   sudo modprobe amdgpu     # 開機被 modprobe.blacklist 擋住，必做
   ls /dev/kfd && amd-smi list
   ```
4. **重啟 repro：** 清掉 stale 狀態後再啟動
5. **排程檢查：** 輪詢讀 log 判斷進度，等下一輪 hang

---

## 13. 交付清單

- bundle 目錄 + 內容一致的 `<bundle>.tgz`
- `verification.txt`
- 採集前後現場簽名
- continuous KFD trace
- 1 秒 GPU telemetry
- CLR runtime log
- debug_scripts commit
- UMR commit 與版本
- ROCm 版本、kernel 版本、amdgpu module 版本與 srcversion、firmware 版本
- workload 基本配置：GPU 可見性、`GPU_MAX_HW_QUEUES`、process/worker 數、stream 數、`HSA_USE_SVM`、`SVC_GC`

**不要只交付 `.tgz` 而遺失驗證結果、工具 commit 和現場簽名。**

### 13.1 交付格式

多輪採集之間格式要一致，分析的人才能用同一套腳本處理：

- `queue_doctor/` 和 `kfd/` **扁平展開**，不要再包一層
- `cpc_waves/` 放子目錄
- CLR log 放 capture 目錄頂層
- 最外層額外放整包 `.tar.gz`（與其他來源的封存檔分開放，避免混淆）

### 13.2 大檔傳輸

CLR log 動輒 1-2GB，單一 SSH channel 很容易斷。傳輸時必須：

- 帶**斷點續傳**（`rsync --partial --append-verify` 或 `scp` 搭配重試）
- 帶**自動重連**，不要假設一次傳完
- 傳完後對照 checksum，確認沒有截斷

```bash
# 斷點續傳範例
rsync -avP --partial --append-verify \
  "${BUNDLE}.tgz" <UPLOAD_HOST>:<DEST_DIR>/
```

不要把含有 GPU/host virtual address、signal handle、process 資訊的原始 bundle
上傳到公開服務（見第 1.3 節）。

---

## 相關

- [UMR 安全分級](../../../tools/umr_safety.md) — 執行前必讀
- [SDMA Fence Debug Playbook](sdma_fence_debug.md)
- [Timeout Death Map](timeout_death_map.md)

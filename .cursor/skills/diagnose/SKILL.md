# SKILL.md — GPU Hang 閉環診斷

> **Use this skill when** the user says "診斷", "diagnose", "幫我跑診斷",
> "GPU hang", "GPU 卡住", or describes a GPU hang / error / timeout symptom.

## 閉環診斷流程

### Step 1: 判斷模式

詢問使用者：

- **本機**（全自動）：agent 可直接執行 shell script，需要 sudo 權限
- **客戶機**（半自動）：agent 給命令，使用者貼回輸出

### Step 2: 初始收集

使用 `tools/collect_hang_info.sh` 收集完整的初始資料：

**本機：**
```bash
sudo ./tools/collect_hang_info.sh all
```

**客戶機：**
提供以下命令讓使用者在目標機器上執行：
```bash
sudo ./collect_hang_info.sh all -o /tmp/hang_diag
# 完成後打包：tar czf hang_diag.tar.gz -C /tmp hang_diag_*
```
請使用者將輸出目錄打包或各檔案內容貼回。

### Step 3: 解析輸出 + Layer 路由

讀取 collect_hang_info.sh 的輸出檔案，判斷問題層級：

1. 讀 `F2_dmesg_gpu_errors.txt`：
   - 有 amdgpu/amdkfd/sdma/fence/evict/reset → **driver 層**
2. 讀 `D_rocgdb_*_pid*.txt`：
   - thread 卡在 WaitRelaxed / hsaCopyStaged / libamdhip64 → **runtime 層**
   - AMDGPU Wave 數量 > 0 → compute 在跑（runtime 可能正常）
   - AMDGPU Wave = 0 → hang 可能在 driver/SDMA 層
3. 讀 `E1_kfd_queues.txt` + `E2_kfd_svm_debug.txt`：
   - queue evicted / SVM restore failed → **driver 層**
4. 兩層都有線索 → 兩層都搜

### Step 4: 迭代搜尋 RAG（最多 5 輪）

每輪：

1. 讀 `knowledge/_index.md` 確認路由
2. 讀對應層的 `{runtime|driver}/_index.md` 匹配症狀
3. 讀匹配的 `symptoms/*.md` 完整內容
4. 比對 log patterns
5. 若症狀建議「跑工具 X 確認」：
   - 本機：直接執行工具
   - 客戶機：提供完整命令，等使用者貼回
6. 解讀新輸出 → 回到步驟 2

**退出條件：**
- 確認匹配已知症狀 → 進入 Step 5a (KNOWN)
- 所有推薦工具跑完仍無匹配 → 進入 Step 5b (UNKNOWN)
- 達到 5 輪上限 → 進入 Step 5b (UNKNOWN)

### Step 5a: KNOWN ISSUE — 生成 HTML Report

生成類似 `coverage_report.html` 深色風格的 HTML 報告，內容：

```
## Header
- Issue 描述、環境資訊（hostname, kernel, ROCm version, GPU）、時間戳

## Root Cause
- SVG flowchart 顯示問題因果鏈
- 文字說明 root cause

## Evidence
- 每一輪工具輸出的關鍵摘要
- 匹配到的 log patterns

## Fix
- 修復方案或 workaround
- 相關環境變數設定

## References
- 匹配到的 symptoms/playbooks/cases 路徑
```

### Step 5b: UNKNOWN ISSUE — 生成 JIRA Report + 寫回知識庫

生成 markdown JIRA report：

```markdown
## 環境
- Host / Container / GPU / ROCm version / kernel

## 問題描述
- 使用者原始描述 + 時間線

## 已收集的 Log
- 每個工具輸出的關鍵摘要（附完整 log 路徑）

## 已排除的可能性
- 每一輪比對 RAG 後排除了什麼、依據是什麼

## 疑似 Root Cause
- 目前最可能的方向

## 建議下一步
- 還需要收集什麼資訊
- 建議誰來看（runtime team / driver team）
```

自動寫回知識庫：
```
knowledge/{runtime|driver}/cases/<issue_id>/
├── case.md          # status: unresolved
├── initial_log.md   # collect_hang_info.sh 關鍵輸出
└── tool_outputs.md  # 迭代工具輸出摘要
```

case.md frontmatter:
```yaml
---
status: unresolved
created: <date>
suspected_layer: driver | runtime | cross-layer
suspected_cause: "..."
tools_used: [...]
excluded: [...]
---
```

### 安全禁令（迭代時絕不可違反）

自動執行工具時，以下命令**永遠不可自動跑**，即使在本機全自動模式：

- `tools/debug_scripts/05_dump_all_cpc_info.sh` 預設模式（8 卡全迴圈 + `halt_if_hws_hang=1`，已知 host-killer）
- `umr --tool cpc` 跨 XCC 0-7 全範圍
- `umr -O bits,halt_waves` 對非 hung GPU
- 任何未加 `timeout` 的 cpc / halt_waves 呼叫

需要 cpc / waves 時，先讀 `tools/umr_safety.md`，並向使用者說明風險後才組裝安全版命令
（hung GPU only、XCC 0-3、獨立呼叫、`timeout 30`、每次檢查 uptime、nohup 背景跑）。

判定 hang 的鐵證是 queue_doctor 的 `wptr != rptr`，**不需要** cpc。

### 工具清單速查

**Runtime 層（按優先順序）：**
1. `rocgdb -batch -ex 'set pagination off' -ex 'info threads' -ex 'thread apply all bt' -ex 'info rocm-devices' -ex 'info rocm-waves' -p $PID`
2. `HIPER_LIGHT_MODE=1 LD_PRELOAD=libhiper.so ./app` (需事前掛載)
3. `HSA_ENABLE_DEBUG=1 LD_PRELOAD=/opt/rocm/lib/librocm-debug-agent.so ./app`

**Driver/GPU 層（按優先順序，全部走安全路徑）：**
1. `for f in $(sudo find /sys/kernel/debug/dri/ -name amdgpu_fence_info); do sudo cat $f; done`
2. `python3 tools/debug_scripts/02_umr_queue_doctor.py --pid $PID --samples 3 --interval 10`
3. `sudo tools/debug_scripts/04_dump_kfd_snapshots.sh --snapshots 3 --interval 5`
4. `sudo tools/debug_scripts/03_dump_sdma_registers.sh`
5. `echo 'file */amdkfd/kfd_device_queue_manager.c +p' | sudo tee /sys/kernel/debug/dynamic_debug/control && sudo cat /sys/kernel/debug/kfd/rls /sys/kernel/debug/kfd/hqds /sys/kernel/debug/kfd/mqds`

**一次性完整採集（安全模式）：**
```bash
tools/debug_scripts/06_collect_all_gpu_debug.sh --pid $PID --skip-cpc --skip-waves --skip-aql-queue
```

### 正式現場採集必做事項

要交付給他人分析的 bundle，必須走完整 SOP
（`knowledge/driver/playbooks/hang_collection_sop.md`），不可只跑 collector 就交件：

- **採集前後現場簽名**：記錄 PID / 業務 stats / GPU util 簽名並 diff。現場變了要建立
  `WARNING_LOG_MAY_BE_INVALID.txt`，bundle 保留不刪
- **記錄工具 commit**：`git -C tools/debug_scripts rev-parse HEAD` 與 UMR commit，
  不可只寫「latest」
- **bundle 完整性驗證**：`final_failures=0`、full-ring raw 數 == decoded 數、
  各 collector 產出非空
- **hang 判定不能只看 GPU=100%**：要同時確認 PID 未變、業務 stats 停止推進、
  VRAM 仍被佔用
- **continuous trace 與 CLR log 必須在 workload 啟動前就設**。若 hang 後才開，
  報告要註明缺少 hang 形成過程的時序，不可把空 trace 解釋成「hang 前沒有 queue 操作」

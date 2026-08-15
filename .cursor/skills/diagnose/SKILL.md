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

### 工具清單速查

**Runtime 層（按優先順序）：**
1. `rocgdb -batch -ex 'set pagination off' -ex 'info threads' -ex 'thread apply all bt' -ex 'info rocm-devices' -ex 'info rocm-waves' -p $PID`
2. `HIPER_LIGHT_MODE=1 LD_PRELOAD=libhiper.so ./app` (需事前掛載)
3. `HSA_ENABLE_DEBUG=1 LD_PRELOAD=/opt/rocm/lib/librocm-debug-agent.so ./app`

**Driver/GPU 層（按優先順序）：**
1. `for f in $(sudo find /sys/kernel/debug/dri/ -name amdgpu_fence_info); do sudo cat $f; done`
2. `sudo ./tools/dump_kfd_snapshots.sh -n 3 -i 5`
3. `sudo ./tools/dump_sdma_registers.sh`
4. `echo 'file */amdkfd/kfd_device_queue_manager.c +p' | sudo tee /sys/kernel/debug/dynamic_debug/control && sudo cat /sys/kernel/debug/kfd/rls /sys/kernel/debug/kfd/hqds /sys/kernel/debug/kfd/mqds`

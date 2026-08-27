# rockit

AMD GPU hang 診斷工具庫 + 雙層知識庫。在 Cursor 中開啟此 project，描述問題即可獲得診斷建議。

## 閉環診斷流程

![rockit 診斷流程](assets/diagnostic_flow.png)

### Phase 與進入點

流程分成 6 個 phase，**不需要每次從頭開始**。Agent 會先看你手上有什麼，直接跳到對應 phase：

| Phase | 前置條件 | 產出 |
|-------|---------|------|
| **P0 Intake** | 症狀描述 或 log | 執行模式、目標 PID |
| **P1 Collect** | 模式 + PID | bundle / log 檔 |
| **P2 Route** | 至少一份 log | 判定 runtime / driver 層 |
| **P3 Iterate** | 分層 + 工具輸出 | 匹配症狀 或 判定 unknown |
| **P4 Report** | 匹配症狀 或 unknown | HTML / JIRA report |
| **P5 Writeback** | UNKNOWN report | `case.md`（status: unresolved） |

進入點對照：

| 你有什麼 | 從哪開始 |
|---------|---------|
| 只有症狀描述 | P0 |
| 有 dmesg / rocgdb / fence_info 片段 | P2（跳過採集） |
| 有完整 bundle 或多個工具輸出 | P3（直接比對） |
| 已確認症狀，只要報告 | P4 |
| 要補完既有 unresolved case | P5 |

### 啟動門檻

資訊不足時 agent 會**停下來並列出缺什麼**，不會硬跑工具。三層門檻：

| 門檻 | 檢查什麼 |
|------|---------|
| Gate 0 | 有沒有症狀描述 / log / bundle 其中之一 |
| Gate 1 | 執行任何工具前必須有：執行模式 + 目標 PID |
| Gate 2 | 宣稱「是 hang」前要滿足判定條件（不能只看 GPU=100%） |

定義在 [.cursor/rules/intake-gate.mdc](.cursor/rules/intake-gate.mdc)。

### 工具選擇順序

每一輪迭代中，agent 按症狀推薦的優先順序逐一選擇工具：

| Runtime 層 | Driver / GPU 層（全部走安全路徑） |
|-----------|-----------------|
| 1. rocgdb batch attach | 1. 手動: amdgpu_fence_info |
| 2. HIPER (HIP API 錄製) | 2. 02_umr_queue_doctor.py（wptr≠rptr 鐵證） |
| 3. ROCm Debug Agent | 3. 04_dump_kfd_snapshots.sh |
| | 4. 03_dump_sdma_registers.sh |
| | 5. 手動: dyndbg + rls/hqds/mqds |

> **安全警告：** UMR 的 `--tool cpc` 和 `-O bits,halt_waves` 是 MMIO 直讀，會殺 host。
> 執行前必讀 [tools/umr_safety.md](tools/umr_safety.md)。判定 hang 的鐵證是 queue_doctor 的
> `wptr != rptr`，不需要 cpc。

### 兩種 Report 輸出

- **KNOWN → HTML Report**：Root cause SVG flowchart + 修復方案 + 相關 case 引用
- **UNKNOWN → JIRA Report**（markdown，可直接貼 JIRA）：環境、log 摘要、已排除可能性、疑似 root cause、建議下一步。自動寫回 `knowledge/{layer}/cases/`，標記 `status: unresolved`

## 快速開始

### 1. 遇到 GPU hang，先跑初始收集

```bash
sudo ./tools/collect_hang_info.sh all
```

### 2. 在 Cursor 中開啟此 project，描述問題

```
GPU 卡住了，dmesg 有 sdma timeout，process 卡在 hipMemcpy
```

AI 會自動走上面的閉環流程。

### 3. 或直接觸發診斷 skill

```
幫我診斷這個 GPU hang 問題
```

## 目錄結構

```
rockit/
├── .cursor/
│   ├── rules/                     # AI 行為規則
│   │   ├── project.mdc            # 全域規則 + 雙層路由
│   │   ├── diagnose.mdc           # 症狀診斷流程
│   │   ├── recommend-tool.mdc     # 工具推薦邏輯 + 安全禁令
│   │   └── interpret-log.mdc      # Log 解讀規則
│   └── skills/
│       └── diagnose/SKILL.md      # 閉環診斷 skill（5 輪迭代 + 雙出口）
│
├── tools/
│   ├── umr_safety.md              # UMR 安全分級（執行前必讀）
│   ├── collect_hang_info.sh       # 輕量跨層概況收集
│   ├── manual_commands.md         # 手動命令參考 (fence_info, dyndbg, signal)
│   ├── rocgdb_cheatsheet.md       # rocgdb 常用命令速查
│   ├── debug_agent_guide.md       # ROCm Debug Agent 指南
│   ├── _coverage.md               # 工具覆蓋對照表
│   ├── debug_scripts/             # submodule: yuanwei2023/debug_scripts
│   │   ├── 02_umr_queue_doctor.py     # queue 診斷主力（wptr/rptr 鐵證）
│   │   ├── 03_dump_sdma_registers.sh  # SDMA 暫存器 dump
│   │   ├── 04_dump_kfd_snapshots.sh   # KFD 多輪快照 + fence diff
│   │   ├── 06_collect_all_gpu_debug.sh # 完整 bundle 採集入口
│   │   ├── 15_trace_kfd_queue.sh      # continuous trace（workload 啟動前開）
│   │   └── ...                        # 05/08 為致命工具，見 umr_safety.md
│   └── hiper/                     # submodule: HIPER (HIP record/replay)
│
├── knowledge/                     # 雙層知識庫 (RAG)
│   ├── _index.md                  # 總索引 + 層級路由
│   ├── runtime/                   # CLR (HIP) + ROCR (HSA)
│   │   ├── _index.md
│   │   ├── symptoms/              # waitrelaxed_hang, hipfree_stall, ...
│   │   ├── playbooks/             # general_hang_triage
│   │   └── cases/                 # d2h_perm_hang, alibaba_waitrelaxed
│   └── driver/                    # KFD driver + GPU hardware
│       ├── _index.md
│       ├── references.md          # 規格書 / 原始碼 / 工具文件索引
│       ├── symptoms/              # sdma_fence_stuck, rdma_pin_rejected, ...
│       ├── playbooks/             # hang_collection_sop, sdma_fence_debug, ...
│       └── cases/                 # alibaba_rdma_underflow, sdma_fence_evidence
│
└── README.md                      # 本文件
```

Clone 時要帶 submodule：

```bash
git clone --recurse-submodules <repo-url>
# 已 clone 過的話
git submodule update --init --recursive
```

## 工具速覽

| 工具 | 層級 | 用途 | 安全性 |
|------|------|------|--------|
| collect_hang_info.sh | 全層 | 快速取得跨層概況 | 安全 |
| 06_collect_all_gpu_debug.sh | 全層 | 完整 bundle 採集 | 安全（需 `--skip-cpc --skip-waves`） |
| 02_umr_queue_doctor.py | KFD/GPU | wptr≠rptr 鐵證、MQD、pending packets | 安全 |
| 04_dump_kfd_snapshots.sh | KFD/Driver | fence diff + KFD queue 詳細 | 安全 |
| 03_dump_sdma_registers.sh | GPU HW | SDMA 暫存器完整 dump | 安全 |
| 15_trace_kfd_queue.sh | KFD | continuous trace（**workload 啟動前開**） | 改系統 debug 狀態 |
| 05_dump_all_cpc_info.sh | GPU HW | CPC 狀態 | **致命（預設模式殺 host）** |
| 08_dump_all_gpu_waves.sh | GPU HW | wave 狀態 | **致命（`--halt-waves`）** |
| rocgdb | CLR + ROCR + GPU | CPU/GPU thread debug + wave | 安全 |
| HIPER | CLR | HIP API 錄製 + replay | 安全 |
| Debug Agent | ROCR + GPU | crash/fault 自動診斷 | 安全 |

## 如何新增知識

### 新增症狀
1. 在 `knowledge/{runtime|driver}/symptoms/` 建 `.md`（按統一 frontmatter 格式）
2. 更新該層的 `_index.md` 速查表加一行

### 新增案例
1. 在 `knowledge/{runtime|driver}/cases/` 建目錄
2. 放入 `case.md`（含 frontmatter: status, root_cause, tools_used）+ 標註 log
3. 跨層問題：root cause 放主層，另一層建 cross-ref case

### 新增工具
1. 腳本放進 `tools/`
2. 更新 `tools/_coverage.md`

### UNKNOWN → KNOWN 轉換
問題解決後：
1. 將 case.md 的 `status: unresolved` 改為 `resolved`
2. 補上 root_cause 和 fix 欄位
3. 若是新症狀類型，在 `symptoms/` 建對應條目

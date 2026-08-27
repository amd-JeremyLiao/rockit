# SKILL.md — GPU Hang 閉環診斷

> **Use this skill when** the user says "診斷", "diagnose", "幫我跑診斷",
> "GPU hang", "GPU 卡住", or describes a GPU hang / error / timeout symptom,
> or provides GPU diagnostic logs / a debug bundle for analysis.

執行前先通過 `.cursor/rules/intake-gate.mdc` 的啟動門檻。資訊不足時停下來問，不要硬跑。

---

## Entry Router（先做這一步）

**不要預設從頭開始。** 先看使用者手上已經有什麼，直接跳到對應 phase：

| 使用者提供了什麼 | 進入 | 理由 |
|-----------------|------|------|
| 只有症狀描述，沒有任何 log | **P0** | 需要先確認模式與目標才能採集 |
| 有 dmesg / rocgdb / fence_info 片段 | **P2** | 已有證據，直接分層路由，跳過採集 |
| 有完整 bundle 或多個工具輸出 | **P3** | 直接進 RAG 比對迭代 |
| 已確認症狀，要求產出報告 | **P4** | 跳過診斷，直接生成 |
| 指向既有 unresolved case 要補完 | **P5** | 更新 case 狀態 |
| 只說「GPU 有問題」無其他資訊 | **停** | 觸發 Gate 0，先問清楚 |

判斷後**明確告知使用者從哪個 phase 開始、為什麼跳過前面**，例如：
「你已經有 fence_info 輸出，我從 P2 分層路由開始，跳過採集階段。」

---

## Phase 契約

每個 phase 宣告前置條件與產出。進入前檢查 `requires`，不滿足就停下來說明缺什麼。

### P0 — INTAKE（確認模式與目標）

| | |
|---|---|
| **requires** | 症狀描述 或 log 或 bundle 路徑（Gate 0） |
| **produces** | `mode`（local / customer）、`target`（PID 或 container） |

1. 確認執行模式：
   - **本機**：agent 可直接執行 shell script（需 sudo）
   - **客戶機**：agent 給命令，使用者貼回輸出
2. 取得目標 PID / process name / container 名稱
3. 若使用者描述疑似 hang，套用 Gate 2 的判定條件確認

**exit** → P1（需要採集）或 P2（已有 log）

### P1 — COLLECT（採集）

| | |
|---|---|
| **requires** | `mode` + `target`（Gate 1） |
| **produces** | bundle 或 log 檔集合 |
| **skip if** | 使用者已提供 bundle / log |

**快速概況（輕量）：**
```bash
sudo ./tools/collect_hang_info.sh <PID>
```

**正式採集（要交付給他人分析時）：**
```bash
tools/debug_scripts/06_collect_all_gpu_debug.sh --pid <PID> \
  --skip-cpc --skip-waves --skip-aql-queue
```

正式採集必須走完整 SOP（`knowledge/driver/playbooks/hang_collection_sop.md`），
包含現場簽名、bundle 驗證、工具 commit 記錄。見本檔末「正式採集必做事項」。

**客戶機模式：** 提供完整命令 + 說明預期輸出中要看什麼，請使用者貼回。

**exit** → P2

### P2 — ROUTE（分層路由）

| | |
|---|---|
| **requires** | 至少一份 log 或工具輸出 |
| **produces** | `layer`（runtime / driver / both） |

依證據判斷層級：

| 證據 | 判定 |
|------|------|
| dmesg 有 amdgpu / amdkfd / sdma / fence / evict / reset | driver |
| rocgdb 卡在 WaitRelaxed / hsaCopyStaged / libamdhip64 | runtime |
| AMDGPU Wave > 0 | compute 在跑，runtime 可能正常 |
| AMDGPU Wave = 0 | hang 可能在 driver / SDMA 層 |
| KFD queue evicted / SVM restore failed | driver |
| 兩邊都有線索 | both（兩層都搜） |

不確定時走 `knowledge/runtime/playbooks/general_hang_triage.md`。

**exit** → P3

### P3 — ITERATE（RAG 比對迭代，最多 5 輪）

| | |
|---|---|
| **requires** | `layer` + 至少一份工具輸出 |
| **produces** | `matched_symptom`（KNOWN）或 `exhausted`（UNKNOWN） |

每輪：

1. 讀 `knowledge/_index.md` 確認路由
2. 讀對應層 `{runtime|driver}/_index.md` 匹配症狀
3. 讀匹配的 `symptoms/*.md`，比對 log patterns
4. 症狀檔若建議「跑工具 X 確認」：
   - 本機：直接執行
   - 客戶機：給命令，等貼回
5. 解讀新輸出 → 回到步驟 2

**exit 條件：**
- 確認匹配已知症狀 → P4（KNOWN）
- 推薦工具都跑完仍無匹配 → P4（UNKNOWN）
- 達 5 輪上限 → P4（UNKNOWN）

每輪結束時簡短告知：這輪排除了什麼、下一輪要跑什麼、目前在第幾輪。

### P4 — REPORT（產出報告）

| | |
|---|---|
| **requires** | `matched_symptom` 或 `exhausted` |
| **produces** | HTML report（KNOWN）或 JIRA report（UNKNOWN） |

**KNOWN → HTML report：**

```
## Header      issue 描述、環境（hostname / kernel / ROCm / GPU）、時間戳
## Root Cause  因果鏈流程圖 + 文字說明
## Evidence    每輪工具輸出的關鍵摘要、匹配到的 log patterns
## Fix         修復方案或 workaround、相關環境變數
## References  匹配到的 symptoms / playbooks / cases 路徑
```

**UNKNOWN → JIRA report**：依團隊 bug 模板產出，格式見下方
「JIRA Report 模板」。

**exit** → P5（UNKNOWN 時）或完成（KNOWN）

#### JIRA Report 模板

直接輸出以下 markdown，可貼進 JIRA。**rockit 能填的欄位一律填滿，
填不了的用 `[需人工補充: ...]` 明確標示，不要留空白或編造。**

```markdown
## Bug Description

[觀察到的行為 vs 預期行為。附錯誤訊息、stack trace、關鍵 log 片段]

## Failure Summary

[1-2 句：什麼失敗、多常發生、什麼條件下觸發]

## Configuration

| Field | Value |
|---|---|
| OEM Model/Chipset | |
| APU/CPU | |
| BIOS | |
| VBIOS | |
| Operating System | |
| Graphics Driver | |
| Device ID | |
| Memory | |
| Kernel Ver | |

## Impacted Scope

- 受影響的 GPU / ASIC：
- 是否所有卡都出現，或只有特定幾顆：
- 受影響的 workload / test：

## Customer Impact

- **Blocking deployment/POC/production?** [需人工補充: Yes/No + 客戶名稱與時程]
- **Customer-Visible Symptom:** [crash / hang / 錯誤結果 / 效能下降 / 功能不可用]
- **Blast Radius:** [需人工補充: 單一客戶 POC 還是平台級]

## Workaround

- **Available?** [Yes / No]
- **Details:** [步驟、代價（效能/手動操作/功能受限）、是否已與客戶驗證]

## Diagnostic Evidence

- **已收集的 log:** [bundle 路徑 + 各 collector 關鍵摘要]
- **已排除的可能性:** [每輪比對 RAG 排除了什麼、依據是什麼]
- **疑似 Root Cause:** [目前最可能的方向]
- **建議下一步:** [還需要什麼資訊、建議 runtime team 或 driver team 接手]

## Additional Information

- **Logs Attached:** [Yes / No — 附完整 log，不要只貼片段]
- **Regression Info:** [需人工補充: last-known-good build / first-bad build]
- **工具版本:** debug_scripts commit / UMR commit / ROCm 版本
```

#### 各欄位的填寫來源

| 欄位 | rockit 可以填嗎 | 來源 |
|------|----------------|------|
| Bug Description | 可以 | 使用者描述 + 匹配到的 log pattern + rocgdb backtrace |
| Failure Summary | 可以 | 症狀檔的「你會看到什麼」+ 實際觀察到的頻率 |
| Configuration | 可以 | bundle 的 `system_info.txt`；缺的用下方命令補 |
| Impacted Scope | 部分 | GPU 清單從 telemetry / queue_doctor 取得；workload 範圍要問 |
| Customer Impact | 幾乎不行 | 需人工補充，rockit 不知道客戶與時程 |
| Workaround | 部分 | 症狀檔若有 fix / workaround 就填，否則標 No |
| Diagnostic Evidence | 可以 | P3 每一輪的排除記錄 |
| Regression Info | 不行 | 需要 A/B build 測試 |

Configuration 欄位的取得命令：

```bash
amd-smi static                          # VBIOS, Device ID, ASIC
cat /sys/class/dmi/id/product_name      # OEM Model
lscpu | grep 'Model name'               # APU/CPU
cat /sys/class/dmi/id/bios_version      # BIOS
cat /etc/os-release                     # OS
modinfo amdgpu | grep -E '^version|srcversion'   # Graphics Driver
free -h                                 # Memory
uname -r                                # Kernel
cat /opt/rocm/.info/version             # ROCm
```

正式採集的 bundle 裡 `system_info.txt` 已含大部分欄位，優先從那裡取，
避免採集後環境變動造成不一致。

> **APU/CPU 欄位別跳過。** Intel 平台的 UMR instance index 要 -2，
> 這個欄位能讓後續分析的人知道暫存器是怎麼讀出來的。見
> [umr_safety.md](../../../tools/umr_safety.md)。

### P5 — WRITEBACK（寫回知識庫）

| | |
|---|---|
| **requires** | UNKNOWN report |
| **produces** | `knowledge/{layer}/cases/<issue_id>/case.md` |

```
knowledge/{runtime|driver}/cases/<issue_id>/
├── case.md          # status: unresolved
├── initial_log.md   # 初始採集關鍵輸出
└── tool_outputs.md  # 迭代工具輸出摘要
```

`case.md` frontmatter：

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

問題日後解決時，把 `status` 改為 `resolved` 並補上 root cause 與 fix，
若是新症狀類型再到 `symptoms/` 建條目。

---

## 安全禁令（任何 phase 都不可違反）

以下命令**永遠不可自動執行**，即使在本機全自動模式：

- `tools/debug_scripts/05_dump_all_cpc_info.sh` 預設模式
  （8 卡全迴圈 + `halt_if_hws_hang=1`，已知 host-killer）
- `umr --tool cpc` 跨 XCC 0-7 全範圍
- `umr -O bits,halt_waves` 對非 hung GPU
- 任何未加 `timeout` 的 cpc / halt_waves 呼叫

需要 cpc / waves 時先讀 `tools/umr_safety.md`，向使用者說明風險後才組裝安全版
（hung GPU only、XCC 0-3、獨立呼叫、`timeout 30`、每次檢查 uptime、nohup 背景跑）。

判定 hang 的鐵證是 queue_doctor 的 `wptr != rptr`，**不需要** cpc。

---

## 工具清單速查

**Runtime 層（按優先順序）：**
1. `rocgdb -batch -ex 'set pagination off' -ex 'info threads' -ex 'thread apply all bt' -ex 'info rocm-devices' -ex 'info rocm-waves' -p $PID`
2. `HIPER_LIGHT_MODE=1 LD_PRELOAD=libhiper.so ./app`（需事前掛載）
3. `HSA_ENABLE_DEBUG=1 LD_PRELOAD=/opt/rocm/lib/librocm-debug-agent.so ./app`

**Driver / GPU 層（按優先順序，全部走安全路徑）：**
1. `for f in $(sudo find /sys/kernel/debug/dri/ -name amdgpu_fence_info); do sudo cat $f; done`
2. `python3 tools/debug_scripts/02_umr_queue_doctor.py --pid $PID --samples 3 --interval 10`
3. `sudo tools/debug_scripts/04_dump_kfd_snapshots.sh --snapshots 3 --interval 5`
4. `sudo tools/debug_scripts/03_dump_sdma_registers.sh`
5. `echo 'file */amdkfd/kfd_device_queue_manager.c +p' | sudo tee /sys/kernel/debug/dynamic_debug/control && sudo cat /sys/kernel/debug/kfd/rls /sys/kernel/debug/kfd/hqds /sys/kernel/debug/kfd/mqds`

---

## 正式採集必做事項

要交付給他人分析的 bundle，必須走完整 SOP
（`knowledge/driver/playbooks/hang_collection_sop.md`），不可只跑 collector 就交件：

- **採集前後現場簽名**：記錄 PID / 業務 stats / GPU util 簽名並 diff。現場變了要建立
  `WARNING_LOG_MAY_BE_INVALID.txt`，bundle 保留不刪
- **記錄工具 commit**：`git -C tools/debug_scripts rev-parse HEAD` 與 UMR commit，
  不可只寫「latest」
- **bundle 完整性驗證**：`final_failures=0`、full-ring raw 數 == decoded 數、
  各 collector 產出非空
- **hang 判定不能只看 GPU=100%**：見 Gate 2
- **continuous trace 與 CLR log 必須在 workload 啟動前就設**。若 hang 後才開，
  報告要註明缺少 hang 形成過程的時序，不可把空 trace 解釋成「hang 前沒有 queue 操作」

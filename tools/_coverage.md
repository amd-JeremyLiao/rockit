# 工具覆蓋對照表

工具與系統部件的對應關係。

> 執行 UMR cpc / waves 前必讀 [umr_safety.md](umr_safety.md)。部分路徑會殺 host。

## 工具來源

| 位置 | 說明 |
|------|------|
| `tools/*.sh`、`tools/*.md` | rockit 自有工具與文件 |
| `tools/debug_scripts/` | submodule：[yuanwei2023/debug_scripts](https://github.com/yuanwei2023/debug_scripts)（ROCm Forensics Toolkit，編號 00-15 採集腳本 + cpc_parser + log_server） |
| `tools/hiper/` | submodule：HIPER（HIP API record/replay） |

採集時務必記錄 submodule 的實際 commit（`git -C tools/debug_scripts rev-parse HEAD`），
交付報告不要只寫「latest」。

## 工具 → 系統層級對照

| 部件 | collect_hang_info | 02 queue_doctor | 04 kfd_snapshots | 03 sdma_registers | fence_info (手動) | dyndbg+kfd (手動) | HIPER | Debug Agent | rocgdb |
|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **CLR / HIP Runtime** |
| App process/threads | * | | | | | | | | * |
| Env vars | * | | | | | | | | |
| CPU thread backtrace | * | | | | | | | | * |
| HIP API calls | | | | | | | * | | |
| Kernel binary/args | | | | | | | * | | |
| Stream/event ops | | | | | | | * | | |
| **ROCR / HSA Runtime** |
| ROCm version/packages | * | | | | | | | | |
| HSA Queue/Agent/mem | | | | | | | | * | * |
| HSA signal values | | * | | | | | | | |
| **KFD / Kernel Driver** |
| KFD proc/Queue/PASID | * | * | | | | | | | |
| Runlist (rls) | | | * | | | * | | | |
| HQDs (hqds) | | | * | | | * | | | |
| MQDs (mqds) | | * | * | | | * | | | |
| wptr/rptr + pending pkt | | * | | | | | | | |
| Full AQL ring dump | | * | | | | | | | |
| Fence (fence_info) | | | * | | * | | | | |
| SVM/eviction | * | | | | | | | | |
| Dynamic debug | * | | * | | | * | | | |
| drm_sched/dma_fence | | | * | | | | | | |
| dmesg/kernel log | * | | * | * | | | | | |
| **GPU Hardware** |
| CP/MEC/CPC | * | | | | | | | | |
| SDMA engines | * | | | * | | | | | |
| Ring buffer/Doorbell | | * | | * | | | | | |
| UTCL1/XNACK | | | | * | | | | | |
| Dispatch info | | | | | | | | * | |
| VRAM/clocks/util | * | | | | | | | | |
| GPU waves (HW) | * | | | | | | | * | * |

## 使用時機

| 工具 | 定位 | 使用時機 | 安全性 |
|------|------|---------|--------|
| `collect_hang_info.sh` | 輕量跨層概況 | 快速取得全貌 | 安全 |
| `06_collect_all_gpu_debug.sh` | 完整 bundle 採集 | 正式現場採集（記得加 `--skip-cpc --skip-waves`） | 安全（skip 危險項時） |
| `02_umr_queue_doctor.py` | queue 診斷主力 | 判定是否真 hang（wptr≠rptr 鐵證） | 安全 |
| `04_dump_kfd_snapshots.sh` | KFD 深度 + trace | 需要 fence diff / KFD queue 詳細 | 安全 |
| `03_dump_sdma_registers.sh` | SDMA 暫存器 dump | 懷疑 SDMA 引擎 hang | 安全 |
| `10_dump_full_user_queue_rings.sh` | 完整 ring dump | 需要看歷史 packet | 安全 |
| `13_dump_aql_queues_gdb.sh` | AQL queue via gdb | 需要 runtime 側 queue 結構 | 安全（會 attach） |
| `09_collect_docker_amd_log.sh` | container CLR log 收集 | workload 跑在 container 裡，要撈 AMD runtime log | 安全 |
| `15_trace_kfd_queue.sh` | continuous KFD trace | **必須在 workload 啟動前開**，記錄 queue 全生命週期時序 | 改系統 debug 狀態 |
| `11_configure_drm_debug.sh` | 選擇性開 drm.debug | 只想開特定 category / 檔案的 debug log，比全開安全 | 改系統 debug 狀態 |
| `cpc_parser` | CPC 輸出解析 | 離線分析已抓到的 CPC 資料 | 安全（離線） |
| `log_server` | log 瀏覽介面 | 檢視 bundle 內容 | 安全（離線） |
| `05_dump_all_cpc_info.sh` | CPC 狀態 | **僅在安全包裝下使用** | **致命（預設模式殺 host）** |
| `08_dump_all_gpu_waves.sh` | wave 狀態 | **僅在安全包裝下使用** | **致命（`--halt-waves`）** |
| fence_info (手動) | 快速確認 ring stuck | 快速判斷 fence 是否推進 | 安全 |
| dyndbg+kfd (手動) | KFD queue 即時狀態 | 需要看 runlist/HQD/MQD | 安全 |
| HIPER | HIP API 錄製+replay | 需要重現問題或分析 API timeline | 安全 |
| Debug Agent | crash/fault 自動診斷 | GPU exception（非 silent hang） | 安全 |
| rocgdb | 互動式/batch debug | 需要 CPU backtrace 或 GPU wave debug | 安全（會暫停 process） |

## 建置與輔助腳本

這些不是採集工具，是環境準備與資料解碼用：

| 腳本 | 用途 | 何時需要 |
|------|------|---------|
| `00_pull_build_umr.sh` | clone 並建置 UMR | 系統沒有 UMR 或版本低於 1.0.11。**不要用 root 跑整個 build** |
| `00_pull_build_gdb.sh` | 建置 upstream GDB（含 Python 支援） | script 13 出現 DWARF 5 警告，或 `rocgdb-py3.11` source 解碼腳本會 crash 時 |
| `aql_packet_decode_gdb.py` | AQL packet 解碼（GDB Python script） | 被 `13_dump_aql_queues_gdb.sh` 引用；也可手動 `gdb -ex "source ..."`，見 [rocgdb_cheatsheet.md](rocgdb_cheatsheet.md) |

```bash
# UMR 版本檢查
./tools/debug_scripts/00_pull_build_umr.sh
git -C "${UMR_DIR:-$HOME/umr}" rev-parse HEAD    # 交付要記錄此 commit
```

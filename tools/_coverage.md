# 工具覆蓋對照表

工具與系統部件的對應關係。

> 執行 UMR cpc / waves 前必讀 [umr_safety.md](umr_safety.md)。部分路徑會殺 host。

## 工具來源

| 位置 | 說明 |
|------|------|
| `tools/*.sh`、`tools/*.md` | rockit 自有工具與文件 |
| `tools/debug_scripts/` | submodule：ROCm Forensics Toolkit（編號 00-15 的採集腳本） |
| `tools/hiper/` | submodule：HIPER（HIP API record/replay） |

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
| `05_dump_all_cpc_info.sh` | CPC 狀態 | **僅在安全包裝下使用** | **致命（預設模式殺 host）** |
| `08_dump_all_gpu_waves.sh` | wave 狀態 | **僅在安全包裝下使用** | **致命（`--halt-waves`）** |
| fence_info (手動) | 快速確認 ring stuck | 快速判斷 fence 是否推進 | 安全 |
| dyndbg+kfd (手動) | KFD queue 即時狀態 | 需要看 runlist/HQD/MQD | 安全 |
| HIPER | HIP API 錄製+replay | 需要重現問題或分析 API timeline | 安全 |
| Debug Agent | crash/fault 自動診斷 | GPU exception（非 silent hang） | 安全 |
| rocgdb | 互動式/batch debug | 需要 CPU backtrace 或 GPU wave debug | 安全（會暫停 process） |

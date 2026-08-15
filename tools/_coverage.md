# 工具覆蓋對照表

工具與系統部件的對應關係。

## 工具 → 系統層級對照

| 部件 | ① collect_hang_info | ② dump_kfd_snapshots | ③ dump_sdma_registers | ④ fence_info (手動) | ⑤ dyndbg+kfd (手動) | ⑥ HIPER | ⑦ Debug Agent | ⑧ rocgdb |
|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **CLR / HIP Runtime** |
| App process/threads | * | | | | | | | * |
| Env vars | * | | | | | | | |
| CPU thread backtrace | * | | | | | | | * |
| HIP API calls | | | | | | * | | |
| Kernel binary/args | | | | | | * | | |
| Stream/event ops | | | | | | * | | |
| **ROCR / HSA Runtime** |
| ROCm version/packages | * | | | | | | | |
| HSA Queue/Agent/mem | | | | | | | * | * |
| **KFD / Kernel Driver** |
| KFD proc/Queue/PASID | * | | | | | | | |
| Runlist (rls) | | * | | | * | | | |
| HQDs (hqds) | | * | | | * | | | |
| MQDs (mqds) | | * | | | * | | | |
| Fence (fence_info) | | * | | * | | | | |
| SVM/eviction | * | | | | | | | |
| Dynamic debug | * | * | | | * | | | |
| drm_sched/dma_fence | | * | | | | | | |
| dmesg/kernel log | * | * | * | | | | | |
| **GPU Hardware** |
| CP/MEC/CPC | * | | | | | | | |
| SDMA engines | * | | * | | | | | |
| Ring buffer/Doorbell | | | * | | | | | |
| UTCL1/XNACK | | | * | | | | | |
| Dispatch info | | | | | | | * | |
| VRAM/clocks/util | * | | | | | | | |
| GPU waves (HW) | * | | | | | | * | * |

## 使用時機

| 工具 | 定位 | 使用時機 |
|------|------|---------|
| collect_hang_info.sh | 全面一次性收集 | 任何 hang 的第一步 |
| dump_kfd_snapshots.sh | KFD 深度 + trace | 需要 fence diff / KFD queue 詳細 |
| dump_sdma_registers.sh | SDMA 暫存器完整 dump | 懷疑 SDMA 引擎 hang |
| fence_info (手動) | 快速確認 ring stuck | 快速判斷 fence 是否推進 |
| dyndbg+kfd (手動) | KFD queue 即時狀態 | 需要看 runlist/HQD/MQD |
| HIPER | HIP API 錄製+replay | 需要重現問題或分析 API timeline |
| Debug Agent | crash/fault 自動診斷 | GPU exception（非 silent hang） |
| rocgdb | 互動式/batch debug | 需要 CPU backtrace 或 GPU wave/kernel debug |

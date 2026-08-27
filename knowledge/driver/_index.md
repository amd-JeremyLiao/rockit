# Driver / GPU Knowledge (KFD + Hardware)

涵蓋 KFD kernel driver（amdkfd / amdgpu）和 GPU hardware（CP, SDMA, GFX）層的問題。

## 症狀速查表

| 關鍵字 / Log pattern | 症狀檔案 | 嚴重度 |
|---|---|---|
| signaled < emitted, sdma timeout, ring timeout | [sdma_fence_stuck](symptoms/sdma_fence_stuck.md) | critical |
| queue evicted, amdkfd | [kfd_queue_eviction](symptoms/kfd_queue_eviction.md) | critical |
| RDMA pin rejected, pinned > max, 17592186044412 | [rdma_pin_rejected](symptoms/rdma_pin_rejected.md) | critical |
| GPU reset, whole chip reset, job timeout | [gpu_reset_timeout](symptoms/gpu_reset_timeout.md) | critical |
| svm restore failed, dma_fence_wait D-state | [svm_restore_failure](symptoms/svm_restore_failure.md) | critical |
| WAIT_EVENTS, kfd_wait, wall clock | [kfd_wait_events](symptoms/kfd_wait_events.md) | high |

## 推薦工具（按優先順序）

1. `collect_hang_info.sh` — 輕量跨層概況
2. 手動: `amdgpu_fence_info` — 快速確認哪個 ring stuck
3. `tools/debug_scripts/02_umr_queue_doctor.py` — wptr/rptr 鐵證 + MQD + pending packets
4. `tools/debug_scripts/04_dump_kfd_snapshots.sh` — 多輪 fence diff + rls/hqds/mqds + trace events
5. `tools/debug_scripts/03_dump_sdma_registers.sh` — SDMA 暫存器完整 dump (100+ 筆)
6. 手動: `dyndbg + rls/hqds/mqds` — KFD dynamic debug 即時狀態

正式現場採集走完整 SOP（含現場簽名與 bundle 驗證）：
`tools/debug_scripts/06_collect_all_gpu_debug.sh --skip-cpc --skip-waves`

## Playbook 索引

| 場景 | Playbook |
|---|---|
| **hang 現場完整採集**（含現場簽名、bundle 驗證、交付清單） | [hang_collection_sop](playbooks/hang_collection_sop.md) |
| SDMA fence 問題 | [sdma_fence_debug](playbooks/sdma_fence_debug.md) |
| Timeout 全路徑分析 | [timeout_death_map](playbooks/timeout_death_map.md) |
| Wait point 審計 | [wait_lifecycle](playbooks/wait_lifecycle.md) |

> 執行 UMR cpc / waves 前必讀 [tools/umr_safety.md](../../tools/umr_safety.md)：有些路徑會殺 host。

## 歷史案例

| 案例 | 狀態 |
|---|---|
| [alibaba_rdma_underflow](cases/alibaba_rdma_underflow/case.md) | resolved — RDMA counter 雙重遞減 → underflow |
| [sdma_fence_evidence](cases/sdma_fence_evidence/) | evidence — 2026-05-06 fence snapshot 實證 |
| [customer_config_risk](cases/customer_config_risk.md) | resolved — 33-ENV 過度設定導致 bad_alloc |

## 常見 driver 層 log patterns

```
# SDMA fence stuck (dmesg)
amdgpu: ring sdma0.0 timeout
amdgpu 0000:XX:00.0: [drm:amdgpu_job_timedout] *ERROR* ring sdma

# fence_info signaled != emitted
Last signaled fence          0x0001cee4
Last emitted                 0x0001cee6    ← stuck

# KFD queue eviction (dmesg)
amdkfd: queue evicted
amdkfd: Process ... evicted from GPU

# RDMA pin rejected (dmesg)
KFD RDMA pin rejected: pinned=...MB + new=...MB > max=...MB

# SVM restore failure
svm_range_restore_work failed
Freeing queue vital buffer
```

# Runtime Knowledge (CLR + ROCR)

涵蓋 HIP API 層（CLR / libamdhip64）和 HSA Runtime 層（ROCR / libhsa-runtime64）的問題。

## 症狀速查表

| 關鍵字 / Log pattern | 症狀檔案 | 嚴重度 |
|---|---|---|
| WaitRelaxed, stuck forever, signal wait, InterruptSignal | [waitrelaxed_hang](symptoms/waitrelaxed_hang.md) | critical |
| hipFree stall, hipFree hang, ihipFree | [hipfree_stall](symptoms/hipfree_stall.md) | high |
| hipDeviceSynchronize hang, SyncAllStreams | [hipdevicesync_hang](symptoms/hipdevicesync_hang.md) | high |
| std::bad_alloc, startup crash, hipHostMalloc | [bad_alloc_startup](symptoms/bad_alloc_startup.md) | high |

## 推薦工具（按優先順序）

1. `collect_hang_info.sh` — 一次性收集 process 狀態 + rocgdb backtrace (C/D 段)
2. `rocgdb -batch -p $PID` — CPU/GPU thread backtrace + wave 狀態
3. `HIPER` (LD_PRELOAD=libhiper.so) — HIP API timeline 錄製 + replay
4. `ROCm Debug Agent` — GPU crash/fault 自動診斷（非 silent hang）

## Playbook 索引

| 場景 | Playbook |
|---|---|
| 任何 hang 的初步分流 | [general_hang_triage](playbooks/general_hang_triage.md) |

## 歷史案例

| 案例 | 狀態 |
|---|---|
| [d2h_perm_hang](cases/d2h_perm_hang/case.md) | resolved — RDMA pin 飽和 → WaitRelaxed 永久 hang |
| [alibaba_waitrelaxed](cases/alibaba_waitrelaxed/case.md) | resolved — cross-ref → driver 層 RDMA counter underflow |

## 常見 runtime 層 log patterns

```
# WaitRelaxed 永久 hang
rocr::core::InterruptSignal::WaitRelaxed()   ← stuck forever
amd::roc::VirtualGPU::HwQueueTracker::CpuWaitForSignal()

# hipFree stall
amd::hip::ihipFree → SyncAllStreams blocked

# hipDeviceSynchronize stall
hip::getCurrentDevice()->SyncAllStreams() → unbounded

# bad_alloc
std::bad_alloc / terminate called after throwing
```

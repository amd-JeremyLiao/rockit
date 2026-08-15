---
symptom: WaitRelaxed Permanent Hang
severity: critical
layer: ROCR / HSA Runtime
components: [InterruptSignal, WaitRelaxed, CpuWaitForSignal, SDMA signal]
keywords: [WaitRelaxed, stuck forever, signal wait, InterruptSignal, CpuWaitForSignal, hipMemcpy hang]
log_patterns:
  - "InterruptSignal::WaitRelaxed"
  - "CpuWaitForSignal"
  - "hsaCopyStaged"
  - "copy_thread_fn"
cross_layer_ref: ../driver/symptoms/rdma_pin_rejected.md
---

# WaitRelaxed Permanent Hang

## 你會看到什麼

- process 卡在 `hipMemcpy` / `tensor.to('hip')` 永不返回
- rocgdb backtrace 顯示 thread 卡在：
  ```
  rocr::core::InterruptSignal::WaitRelaxed()
  amd::roc::VirtualGPU::HwQueueTracker::CpuWaitForSignal()
  amd::roc::DmaBlitManager::hsaCopyStaged()
  ```
- GPU util 可能維持 100%（其他 compute queue 仍在跑）
- `kill -9` 可以殺 process，但 GPU 可能需要 reset

## 快速判斷

```
rocgdb thread backtrace 卡在哪裡？
  ├─ WaitRelaxed → SDMA signal 沒回來
  │    ├─ fence_info signaled < emitted → 真正 SDMA stuck → 看 driver/symptoms/sdma_fence_stuck.md
  │    └─ fence_info signaled == emitted → SDMA 正常，問題在上游（AcquireWriteAddress / ROCr 層）
  ├─ hsaKmtWaitOnEvent → KFD wait，可能是 eviction → 看 driver/symptoms/kfd_queue_eviction.md
  └─ 其他 → 非典型，需要更多資訊
```

## 推薦工具（依優先順序）

1. **rocgdb batch attach** — 確認卡在哪個 function
   ```bash
   rocgdb -batch -ex 'set pagination off' -ex 'info threads' -ex 'thread apply all bt' -ex 'info rocm-waves' -p $PID
   ```
2. **手動: fence_info** — 確認 SDMA fence 是否 stuck
   ```bash
   for f in $(sudo find /sys/kernel/debug/dri/ -name amdgpu_fence_info); do sudo cat "$f"; done
   ```
3. **collect_hang_info.sh** — 全面收集
   ```bash
   sudo ./tools/collect_hang_info.sh $PID
   ```

## 可能的 Root Cause

1. **RDMA pin quota 滿** → SDMA staging pin 被 kernel 拒絕 → signal 永不 fire → cross-ref: [rdma_pin_rejected](../driver/symptoms/rdma_pin_rejected.md)
2. **RDMA counter underflow** → 所有 pin 永久被拒 → cross-ref: [alibaba_rdma_underflow](../driver/cases/alibaba_rdma_underflow/case.md)
3. **ROCr AcquireWriteAddress spin** → userspace while(true) spin，SDMA 正常但上游卡住
4. **KFD queue eviction** → queue 被 unmap → signal path 斷裂

## 修復 / Workaround

- V17.4.1: `ROCR_SIGNAL_WAIT_MAX_MS=2000` 讓 WaitRelaxed 有上限
- V17.5: `ROCR_SERVICE_SURVIVAL=1` + `HIP_SERVICE_SURVIVAL=1` + `ROCR_SIGNAL_WAIT_MAX_MS=4000`

## 客戶 call stack（參考）

```
tensor.to('hip')
  → at::native::copy_kernel_cuda()
  → hip::hipMemcpyWithStream()
  → amd::roc::DmaBlitManager::hsaCopyStaged()
  → amd::roc::VirtualGPU::HwQueueTracker::CpuWaitForSignal()
  → rocr::core::InterruptSignal::WaitRelaxed()   ← stuck forever
```

## 相關案例

- [d2h_perm_hang](../cases/d2h_perm_hang/case.md)
- [alibaba_waitrelaxed](../cases/alibaba_waitrelaxed/case.md) — cross-ref to driver

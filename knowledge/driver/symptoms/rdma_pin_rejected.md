---
symptom: RDMA Pin Rejected
severity: critical
layer: KFD driver
components: [RDMA, pin, dmabuf, rdma_pinned_bytes, quota]
keywords: [RDMA pin rejected, pinned, max, dmabuf_pin_max_mb, rdma_pinned_bytes, underflow, 17592186044412]
log_patterns:
  - "KFD RDMA pin rejected"
  - "pinned=.*MB.*new=.*MB.*max=.*MB"
  - "17592186044412"
cross_layer_ref: ../runtime/symptoms/waitrelaxed_hang.md
---

# RDMA Pin Rejected

## 你會看到什麼

- dmesg 出現 `KFD RDMA pin rejected: pinned=XXXMB + new=YYYMB > max=ZZZMB`
- 若 pinned 值為 `17592186044412MB`（≈ 2^64 / 2^20）→ counter underflow，所有 pin 永久被拒
- process 卡在 `hipMemcpy` → `WaitRelaxed()`，因為 SDMA staging pin 失敗

## 快速判斷

```
dmesg "RDMA pin rejected" 中的 pinned 值？
  ├─ 合理值（<= max）→ 正常 quota 飽和，減少 RDMA 並發或提高 max
  ├─ 極大值（17592186044412）→ counter underflow！需要 V17.4.1 patch
  └─ 找不到此訊息 → 不是 RDMA pin 問題
```

## 推薦工具

1. **dmesg 過濾**
   ```bash
   dmesg | grep 'RDMA pin rejected'
   ```
2. **collect_hang_info.sh** — E2 段會抓 RDMA 相關資訊

## Root Cause: Counter Underflow

orphan reaper（V15.5）與 `amd_put_pages` 對同一個 BO 做雙重 decrement：

```
Thread A: hipFree → amd_put_pages → atomic64_sub(bytes, rdma_pinned_bytes)  ← 第一次
Thread B: orphan_reaper → drain → atomic64_sub(op->bytes, rdma_pinned_bytes) ← 第二次
```

u64 counter 從小正數繞回 ~0ULL，之後所有 `pinned + new > max` 判斷永遠為 true。

## 修復

V17.4.1 三個 patch：
1. orphan reaper 先清 `rdma_quota_charged` 再 unpin → 防止雙重 decrement
2. `amdgpu_amdkfd_gpuvm_unpin_bo` 在 `pin_count==0` 時 early return
3. `kfd_wait_on_events` 加 2s schedule_timeout + reset check + 30s wall-clock deadline

## 相關案例

- [alibaba_rdma_underflow](../cases/alibaba_rdma_underflow/case.md)

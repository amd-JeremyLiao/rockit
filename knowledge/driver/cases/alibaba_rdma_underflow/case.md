---
status: resolved
created: 2026-04-28
resolved: 2026-05-01
layer: driver
root_cause: "rdma_pinned_bytes u64 counter double-decrement → underflow → all RDMA pin rejected"
fix: "V17.4.1 三個 patch: orphan reaper 清 rdma_quota_charged + unpin early return + kfd_wait timeout"
tools_used: [collect_hang_info.sh, rocgdb, dmesg, fence_info]
related_symptoms: [rdma_pin_rejected, sdma_fence_stuck, waitrelaxed_hang]
cross_layer_ref: ../../runtime/cases/alibaba_waitrelaxed/case.md
---

# Alibaba RDMA Counter Underflow

## 客戶現象

- 連續 RDMA 請求進入 inference service
- GPU util 突然 100% → 永久 hang，不自己恢復
- `kill -9` 或 GPU reset 才能解除

## 環境

- GPU: MI300X (192GB VRAM)
- 16 HIP streams (pipelined H2D + compute + D2H)
- cgroup memory.max = 32 GiB
- RDMA peer-direct 請求無 rate limit

## Root Cause

`rdma_pinned_bytes` u64 counter 雙重遞減 → underflow 到 `~0ULL`：

```
Thread A: hipFree → amd_put_pages → atomic64_sub(bytes, rdma_pinned_bytes)  ← 第一次
Thread B: orphan_reaper → drain → atomic64_sub(op->bytes, rdma_pinned_bytes) ← 第二次
```

之後所有 `pinned + new > max` 判斷為 true → 所有 RDMA pin 被拒 → SDMA staging pin 失敗 → `WaitRelaxed()` 永久 hang。

## 關鍵 dmesg 證據

```
amdgpu 0000:80:00.0: KFD RDMA pin rejected:
   pinned=17592186044412MB + new=2MB > max=4096MB
```

`17592186044412` = `(u64)-1 / (1024*1024)` ≈ `2^64 / 2^20` → 確認 counter underflow。

## 修復 (V17.4.1)

1. orphan reaper 先清 `rdma_quota_charged` 再 unpin → 防止雙重 decrement
2. `amdgpu_amdkfd_gpuvm_unpin_bo` 在 `pin_count==0` 時 early return
3. `kfd_wait_on_events` 加 2s schedule_timeout + reset check + 30s wall-clock deadline

## 驗證方式

```bash
sudo dmesg | grep 'RDMA pin rejected' | grep '17592186044412'  # 不應再出現
```

## 延伸漏洞（同場景可觸發但不需 underflow）

1. Suballocator `intr=false` 無 timeout (P1)
2. TTM error path fence wait 無 timeout (P1)
3. GTT slot lock 預設 timeout=0 (P2)
4. Pageable copy fallback 繞過 VRAM guard (P2)

詳見 `alibabaHang/docs/HANG_VULN_ANALYSIS.md`

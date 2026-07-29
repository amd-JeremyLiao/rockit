---
symptom: KFD Queue Eviction
severity: critical
layer: KFD driver
components: [KFD, queue, eviction, memcg, PASID]
keywords: [queue evicted, amdkfd, evict, eviction, memcg, cgroup, memory.max, unmap queue]
log_patterns:
  - "amdkfd.*queue evicted"
  - "Process.*evicted from GPU"
  - "evict_process_queues"
cross_layer_ref: ../runtime/symptoms/waitrelaxed_hang.md
---

# KFD Queue Eviction

## 你會看到什麼

- dmesg 出現 `amdkfd: queue evicted` 或 `Process ... evicted from GPU`
- KFD queue 從 GPU 上被 unmap，後續 SDMA/compute 操作卡住
- 通常伴隨 memory 壓力（cgroup limit 或系統 OOM）

## 快速判斷

```
dmesg 有 "queue evicted"?
  ├─ YES → 檢查 memory 壓力來源
  │    ├─ cgroup memory.max 太小 → 調大或減少 pinned memory
  │    └─ RDMA pin + KV cache 超過 cgroup limit → 減少並發 stream
  └─ NO → 不是 eviction 問題，看其他症狀
```

## 推薦工具

1. **dmesg 過濾**
   ```bash
   dmesg | grep -iE 'evict|unmap.*queue|map.*queue|amdkfd'
   ```
2. **KFD queue 狀態**
   ```bash
   sudo cat /sys/kernel/debug/kfd/hqds
   sudo cat /sys/kernel/debug/kfd/rls
   ```
3. **cgroup memory 檢查**
   ```bash
   cat /sys/fs/cgroup/memory/memory.usage_in_bytes
   cat /sys/fs/cgroup/memory/memory.limit_in_bytes
   ```

## 可能的 Root Cause

1. **cgroup memory.max 過低** — pinned host memory + ROCr ring buffers + libc heap 超過限制
2. **RDMA pin 壓力** — 大量 RDMA BO pin 佔用 host memory
3. **多 stream 並發** — 16+ stream 各自的 KV cache pin 合計超限
4. **SVM restore 失敗** — eviction 後 restore 失敗 → queue 永久 unmap → cross-ref: [svm_restore_failure](svm_restore_failure.md)

## 相關案例

- [alibaba_rdma_underflow](../cases/alibaba_rdma_underflow/case.md) — 32GB cgroup + 16 stream 觸發 eviction

---
symptom: SVM Restore Failure
severity: critical
layer: KFD driver
components: [SVM, svm_range_restore, dma_fence_wait, munmap, XNACK]
keywords: [svm restore failed, svm_range_restore_work, svm_range_unmap, dma_fence_wait, D-state, munmap, HSA_XNACK]
log_patterns:
  - "svm_range_restore.*failed"
  - "failed to restore svm range"
  - "Freeing queue vital buffer"
cross_layer_ref: null
---

# SVM Restore Failure (DEATH-A1)

## 你會看到什麼

- thread 進入 D-state（不可中斷等待）
- `/proc/<pid>/stack` 顯示 `dma_fence_wait` / `svm_range_unmap`
- dmesg 可能出現 `Freeing queue vital buffer`
- 只在 `HSA_XNACK=1` 環境下觸發（SVM 真正啟用時）

## 觸發路徑

```
hipMallocManaged → SVM range 建立
  ↓
GPU spin kernel + SDMA D2D（fence stuck）
  ↓
另一個 thread munmap managed VA
  → mmu_notifier → svm_range_unmap_from_cpu
  → svm_range_unmap_from_gpus → dma_fence_wait（無 timeout）
  → thread 進入 D-state，永久等待
```

## 推薦工具

1. **檢查 process stack**
   ```bash
   sudo cat /proc/$PID/stack
   ```
   看是否有 `dma_fence_wait` / `svm_range_unmap`
2. **dmesg**
   ```bash
   dmesg | grep -iE 'svm|restore|vital buffer'
   ```

## 修復

driver 的 `svm_range_unmap_from_gpus` 中的 `dma_fence_wait` 需要加 timeout。

## 相關

- reproducer: `alibabaHang/reproducers/svm_quiesce_hang/`
- 需要 `HSA_XNACK=1` 才能觸發

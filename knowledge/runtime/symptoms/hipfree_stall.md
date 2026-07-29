---
symptom: hipFree Stall
severity: high
layer: CLR / HIP Runtime
components: [hipFree, SyncAllStreams, ihipFree, HIP_FREE_SYNC_FAIL_MS]
keywords: [hipFree, stall, hang, free, SyncAllStreams, K-6, HIP_FREE_SYNC_FAIL_MS]
log_patterns:
  - "hipFree.*blocked"
  - "hipFree.*stall"
  - "ihipFree"
cross_layer_ref: null
---

# hipFree Stall (K-6)

## 你會看到什麼

- `hipFree()` 呼叫長時間不返回（數十秒到永久）
- rocgdb backtrace 顯示 thread 卡在 `amd::hip::ihipFree` → `SyncAllStreams`
- 通常在 GPU 高負載（多 stream 並發 kernel + SDMA copy）時觸發

## Root Cause

`hipFree` 在釋放記憶體前會呼叫 `SyncAllStreams` 等所有 stream 完成。
若任一 stream 的操作卡住（如 SDMA fence stuck），整個 `hipFree` 也跟著卡。

## 推薦工具

1. **rocgdb** — 確認 thread 卡在 `ihipFree` / `SyncAllStreams`
2. **HIPER** — timeline 中找 hipFree 前的 pending 操作

## 修復

K-6 patch：`SyncAllStreamsBounded` + `HIP_FREE_SYNC_FAIL_MS`

```bash
export HIP_FREE_SYNC_FAIL_MS=2000      # 2s wall-clock timeout
export HIP_FREE_REJECT_ON_ACTIVE=1     # reject free if stream still active
```

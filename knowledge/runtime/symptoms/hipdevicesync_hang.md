---
symptom: hipDeviceSynchronize Hang
severity: high
layer: CLR / HIP Runtime
components: [hipDeviceSynchronize, SyncAllStreams, HIP_FREE_SYNC_FAIL_MS]
keywords: [hipDeviceSynchronize, device sync, SyncAllStreams, unbounded, K-6.2]
log_patterns:
  - "hipDeviceSynchronize.*stall"
  - "SyncAllStreams"
cross_layer_ref: null
---

# hipDeviceSynchronize Unbounded Hang (K-6.2)

## 你會看到什麼

- `hipDeviceSynchronize()` 在 GPU 高負載 + 多 stream 下 hang 數十秒到數分鐘
- 常見於 PyTorch / TensorRT / 自家 inference engine 的 barrier 操作
- GPU util 可能 100%（spin kernel 或其他 compute 仍在跑）

## Root Cause

`hipDeviceSynchronize` 內部呼叫 `SyncAllStreams()`，此函式遍歷所有 stream 做 sync。
在 K-6 修了 `hipFree` 的 `SyncAllStreams` stall 後，`hipDeviceSynchronize` 的這條路徑仍是 unbounded：

```cpp
// hip_device_runtime.cpp:621 (修復前)
hipError_t hipDeviceSynchronize() {
    hip::getCurrentDevice()->SyncAllStreams(kDoWaitForCpu);  // <- unbounded
}
```

## 推薦工具

1. **rocgdb** — 確認 thread 卡在 `SyncAllStreams`
   ```bash
   rocgdb -batch -ex 'thread apply all bt' -p $PID | grep -i sync
   ```
2. **HIPER** — 看 HIP API timeline，確認最後一個 API 是 hipDeviceSynchronize

## 修復

K-6.2 patch：`hipDeviceSynchronize` 改用 `SyncAllStreamsBounded`，讀 `HIP_FREE_SYNC_FAIL_MS` env。

```bash
export HIP_FREE_SYNC_FAIL_MS=2000   # wall-clock 2s 後 break
```

## 驗證

```bash
export ROCR_SERVICE_SURVIVAL=1
export HIP_SERVICE_SURVIVAL=1
export HIP_FREE_SYNC_FAIL_MS=2000
export HIP_AWAIT_FAIL_MS=2000
./your_program
# 不應再出現 > 30s 的 hipDeviceSynchronize stall
```

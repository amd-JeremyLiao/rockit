---
symptom: Service Startup std::bad_alloc
severity: high
layer: CLR / HIP Runtime
components: [hipHostMalloc, HIP_UNIFIED_MEM_BUDGET, HIP_PAGEABLE_FALLBACK_MAX_MB]
keywords: [bad_alloc, startup, hipHostMalloc, HIP_UNIFIED_MEM_BUDGET, HIP_PAGEABLE_FALLBACK_MAX_MB, service crash]
log_patterns:
  - "std::bad_alloc"
  - "terminate called"
  - "hipHostMalloc.*failed"
cross_layer_ref: null
---

# Service Startup std::bad_alloc

## 你會看到什麼

- service 啟動時 crash，stderr 顯示 `std::bad_alloc` / `terminate called`
- 只在特定環境變數組合下觸發
- 不是 OOM（系統記憶體充足），是 HIP runtime guard 拒絕 allocation

## Root Cause

兩個環境變數合用時會把 host-pinned allocation 上限壓到 8 GiB：

```bash
HIP_UNIFIED_MEM_BUDGET=1
HIP_PAGEABLE_FALLBACK_MAX_MB=8192
```

若客戶 workload pin 超過 8 GiB（例如 16 stream x 1 GiB KV cache），第 9 個 `hipHostMalloc` 被拒絕 → `std::bad_alloc` → `terminate`。

## 修復

移除這兩個環境變數，改用最小 survival ENV：

```bash
export ROCR_SERVICE_SURVIVAL=1
export HIP_SERVICE_SURVIVAL=1
export ROCR_SIGNAL_WAIT_MAX_MS=4000
```

三行即可。客戶 scale 驗證（16-stream x 1 GiB KV in 32 GiB cgroup）正常完成 91 forward iterations。

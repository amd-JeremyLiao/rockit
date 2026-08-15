---
status: resolved
created: 2026-05-15
layer: driver
root_cause: "客戶 33-ENV recipe 過於保守，HIP_UNIFIED_MEM_BUDGET + HIP_PAGEABLE_FALLBACK_MAX_MB 壓低 pin limit 導致 bad_alloc"
fix: "改用 3-ENV 最小 recipe (ROCR_SERVICE_SURVIVAL + HIP_SERVICE_SURVIVAL + ROCR_SIGNAL_WAIT_MAX_MS)"
cross_layer_ref: ../../runtime/symptoms/bad_alloc_startup.md
---

# Customer Config Risk Audit

V17.5 客戶的 33-ENV 全設定中，部分參數組合產生意外副作用。

關鍵風險：
- `HIP_UNIFIED_MEM_BUDGET=1` + `HIP_PAGEABLE_FALLBACK_MAX_MB=8192` → pin 上限 8GB → 16 stream KV 時 bad_alloc
- `HSA_TOOLS_LIB=`（空值）→ 刻意關閉 debug agent
- `gtt_lock_timeout_ms=0`（預設）→ GTT slot deadlock 風險

建議：使用 3-ENV 最小 recipe，詳見 `alibabaHang/audits/V17_5_CUSTOMER_CONFIG_RISK_AUDIT.md`。

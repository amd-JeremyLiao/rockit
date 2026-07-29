---
status: resolved
created: 2026-04-28
layer: runtime (表現層) / driver (root cause 層)
root_cause: "RDMA pin quota 滿 → SDMA staging pin 被拒 → SDMA queue freeze → WaitRelaxed 永久 hang"
fix: "V17.5: ROCR_SERVICE_SURVIVAL + ROCR_SIGNAL_WAIT_MAX_MS + ROCR_SDMA_WRITE_ADDR_FAIL_MS"
tools_used: [rocgdb, dmesg, collect_hang_info.sh]
related_symptoms: [waitrelaxed_hang, rdma_pin_rejected, sdma_fence_stuck]
cross_layer_ref: ../../driver/cases/alibaba_rdma_underflow/case.md
---

# D2H Permanent Hang

## 現象

- `hipMemcpy(H2D)` 使用 pageable host buffer 時永久 hang
- rocgdb 顯示 thread 卡在 `InterruptSignal::WaitRelaxed()`
- GPU util 100%（spin kernel 仍在跑）
- `HIP_MAX_SIGNAL_WAIT=4` recovery 機制在 SDMA queue 完全 freeze 時失效

## 為什麼 recovery 救不了

```
正常 hang（recovery 有效）:
  SDMA fence 等待 → HIP_MAX_SIGNAL_WAIT timer → force signal → 出來（但慢 ~8s/copy）

永久 hang（recovery 無效）:
  SDMA pin 被 kernel 拒絕 → SDMA queue freeze
  → recovery 嘗試 KFD ioctl force signal
  → KFD SDMA queue 本身凍死，ioctl 無回應
  → process 卡在 kernel syscall → 永久 hang
```

## 修復

V17.5 三行 env：
```bash
export ROCR_SERVICE_SURVIVAL=1
export HIP_SERVICE_SURVIVAL=1
export ROCR_SIGNAL_WAIT_MAX_MS=4000
```

## 驗證

reproducer: `alibabaHang/reproducers/d2h_perm_hang/`
V17.5 結果: EXIT=0, PASS（原始 ROCm 6.3: EXIT=124, HANG）

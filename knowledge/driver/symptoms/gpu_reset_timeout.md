---
symptom: GPU Reset / Job Timeout
severity: critical
layer: GPU Hardware
components: [GPU reset, whole chip reset, job timeout, amdgpu_job_timedout]
keywords: [GPU reset, whole chip reset, job timeout, amdgpu_job_timedout, ring timeout, reset pending]
log_patterns:
  - "amdgpu.*job.*timed.*out"
  - "whole chip reset"
  - "GPU reset"
  - "reset pending"
cross_layer_ref: null
---

# GPU Reset / Job Timeout

## 你會看到什麼

- dmesg 出現 `amdgpu: ring XXX timeout` → `amdgpu_job_timedout`
- 嚴重時觸發 `whole chip reset`
- reset 後 GPU 可能恢復，也可能需要 reboot
- 所有 running process 的 GPU 操作都會中斷

## 快速判斷

```
dmesg 有 "job timedout" / "GPU reset"?
  ├─ 單一 ring timeout → 可能是該 engine 的問題（SDMA/GFX/compute）
  ├─ whole chip reset → 嚴重硬體或 firmware 問題
  └─ reset pending 持續存在 → reset 未成功完成
```

## 推薦工具

1. **dmesg 過濾**
   ```bash
   dmesg | grep -iE 'reset|timeout|job.*timed|whole chip'
   ```
2. **03_dump_sdma_registers.sh** — 看 SDMA STATUS_REG
   ```bash
   sudo tools/debug_scripts/03_dump_sdma_registers.sh
   ```
3. **fence_info** — 確認哪個 ring 的 fence stuck 導致 timeout

## 可能的 Root Cause

1. **SDMA engine hang** → fence 長時間 stuck → job timeout → reset
2. **Compute kernel infinite loop** → GFX ring timeout
3. **Memory fault** → GPU exception → timeout
4. **Firmware bug**

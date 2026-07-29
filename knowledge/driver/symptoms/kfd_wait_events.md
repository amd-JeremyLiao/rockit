---
symptom: KFD Wait Events Unbounded
severity: high
layer: KFD driver
components: [KFD, AMDKFD_IOC_WAIT_EVENTS, kfd_wait_on_events, wall clock]
keywords: [kfd_wait, WAIT_EVENTS, ioctl, wall clock, kfd_wait_max_ms_per_wall, P12]
log_patterns:
  - "WAIT_EVENTS.*timeout"
  - "kfd_wait_wall_timeout_count"
cross_layer_ref: null
---

# KFD Wait Events Unbounded (P1.2)

## 你會看到什麼

- `AMDKFD_IOC_WAIT_EVENTS` ioctl 在 signal 永不到來時，按 user timeout 等待（可能數十秒到數分鐘）
- 正常情況有 driver wall-clock cap（`kfd_wait_max_ms_per_wall`）會提前返回 ETIMEDOUT
- 若 wall cap 未啟用（值為 0），ioctl 會等到 user timeout 才返回

## 快速判斷

```bash
# 檢查 wall cap 是否啟用
cat /sys/module/amdgpu/parameters/kfd_wait_max_ms_per_wall
# 0 = 未啟用（危險），5000 = 5s cap（推薦）

# 檢查 fire counter（若 patch 有裝）
cat /sys/kernel/debug/dri/0/amdgpu_kfd_wait_wall_timeout_count
```

## 推薦工具

1. **collect_hang_info.sh** — E1 段的 KFD queue 狀態
2. **手動設定 wall cap**
   ```bash
   echo 5000 | sudo tee /sys/module/amdgpu/parameters/kfd_wait_max_ms_per_wall
   ```

## 修復

設定 `kfd_wait_max_ms_per_wall=5000`（P1.2 patch），讓 ioctl 在 wall-clock 超過 5s 時強制返回 ETIMEDOUT。

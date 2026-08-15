# GPU Debug Knowledge Index

本知識庫分為兩層，依問題表現位置選擇入口。

## 快速路由

| 看到什麼 | 去哪裡 |
|---|---|
| hipMemcpy / hipFree / hipDeviceSync 卡住 | → [runtime/_index.md](runtime/_index.md) |
| WaitRelaxed / HSA queue error | → [runtime/_index.md](runtime/_index.md) |
| rocgdb backtrace 卡在 libamdhip64 / libhsa-runtime64 | → [runtime/_index.md](runtime/_index.md) |
| dmesg 有 amdgpu / amdkfd / sdma / fence / evict | → [driver/_index.md](driver/_index.md) |
| amdgpu_fence_info signaled < emitted | → [driver/_index.md](driver/_index.md) |
| RDMA pin rejected / OOM / GPU reset | → [driver/_index.md](driver/_index.md) |
| 不確定在哪一層 | 先跑 [general_hang_triage](runtime/playbooks/general_hang_triage.md) |

## 跨層案例

有些問題 root cause 在 driver 但表現在 runtime（如 RDMA counter 溢位導致 WaitRelaxed hang）。
這類案例放在 root cause 所在層的 `cases/`，另一層有 cross-ref 指回。

症狀條目的 frontmatter 中 `cross_layer_ref` 欄位標示跨層引用。

## 目錄結構

```
knowledge/
├── _index.md           ← 你在這裡
├── runtime/            CLR (HIP) + ROCR (HSA)
│   ├── _index.md       runtime 層症狀索引
│   ├── symptoms/       症狀條目
│   ├── playbooks/      除錯 SOP
│   └── cases/          歷史案例 + 標註 log
└── driver/             KFD driver + GPU hardware
    ├── _index.md       driver/GPU 層症狀索引
    ├── symptoms/       症狀條目
    ├── playbooks/      除錯 SOP
    └── cases/          歷史案例 + 標註 log
```

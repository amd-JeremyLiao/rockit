---
status: resolved
created: 2026-04-28
layer: cross-layer (表現在 runtime，root cause 在 driver)
root_cause: "見 driver 層完整分析"
cross_layer_ref: ../../driver/cases/alibaba_rdma_underflow/case.md
---

# Alibaba WaitRelaxed Hang (Runtime 側觀點)

此案例的 root cause 在 driver 層（RDMA counter underflow），但表現在 runtime：
process 卡在 `InterruptSignal::WaitRelaxed()` 永不返回。

## Runtime 側的觀察

- rocgdb backtrace: 所有 copy thread 卡在 `WaitRelaxed`
- GPU util 100%（其他 compute queue 繼續）
- `info rocm-waves` 可能有 active compute waves（非 copy 相關）
- 無 HIP API error return（signal 永遠不 fire，不會 timeout）

## 如何判斷是跨層問題

1. rocgdb 看到 `WaitRelaxed` → runtime 層表現
2. fence_info 看到 sdma ring `signaled == emitted` → SDMA 本身沒 stuck
3. dmesg 看到 `RDMA pin rejected: pinned=17592186044412MB` → driver 層 root cause
4. → 確認是跨層：runtime 的 signal 等 driver 的 SDMA 完成，但 driver 因 counter 錯誤永遠不發 SDMA job

## 完整分析

見 [driver/cases/alibaba_rdma_underflow/case.md](../../driver/cases/alibaba_rdma_underflow/case.md)

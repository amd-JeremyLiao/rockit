---
symptom: SDMA Fence Stuck
severity: critical
layer: KFD / GPU Hardware
components: [SDMA, fence, amdgpu_fence_info, ring buffer]
keywords: [sdma, fence, stuck, signaled, emitted, ring timeout, sched timeout, sdma0.0]
log_patterns:
  - "Last signaled fence.*0x.* != .*Last emitted.*0x"
  - "amdgpu.*ring sdma.*timeout"
  - "amdgpu.*sched.*timeout"
cross_layer_ref: ../runtime/symptoms/waitrelaxed_hang.md
---

# SDMA Fence Stuck

## 你會看到什麼

- process 卡在 `hipMemcpy` / `hipStreamSynchronize`
- dmesg 出現 `amdgpu: ring sdma0.0 timeout` 或 `amdgpu_job_timedout`
- `amdgpu_fence_info` 中某個 sdma ring 的 `signaled < emitted` 持續不變
- 多次抓 fence_info（間隔 5 秒）比對，pending 數字完全沒推進

## 快速判斷

```
fence_info: signaled == emitted?
  ├─ YES → ring 健康，hang 不在 SDMA → 看 runtime 層 (WaitRelaxed / AcquireWriteAddress)
  └─ NO (signaled < emitted)
       ├─ 多次抓取都不變 → 真正的 SDMA fence stuck
       └─ 緩慢推進 → SDMA 繁忙但非 stuck，可能是 KIQ blocked
```

## 推薦工具（依優先順序）

1. **手動: amdgpu_fence_info** — 確認哪個 ring stuck
   ```bash
   for f in $(sudo find /sys/kernel/debug/dri/ -name amdgpu_fence_info); do echo "=== $f ==="; sudo cat "$f"; done
   ```
2. **dump_kfd_snapshots.sh** — 多輪 fence diff 確認是否推進
   ```bash
   sudo ./tools/dump_kfd_snapshots.sh -n 3 -i 5
   ```
3. **dump_sdma_registers.sh** — SDMA 暫存器完整 dump
   ```bash
   sudo ./tools/dump_sdma_registers.sh
   ```
4. **rocgdb** — 看 CPU thread 是否卡在 kernel wait
   ```bash
   rocgdb -batch -ex 'set pagination off' -ex 'thread apply all bt' -p $PID
   ```

## fence_info 正確解析（避免假陽性）

只比對每個 ring header 之後的**第一個** `Last emitted`（第二個是 trailing fence，正常為 0）：

```awk
/^--- ring/   { ring=$0; sig=""; emit=""; got_sig=0 }
/Last signaled fence/  { sig=$NF; got_sig=1 }
got_sig && /Last emitted/ {
    emit=$NF
    if (sig != emit)
        printf "%s sig=%s emit=%s pending=%d\n",
               ring, sig, emit, strtonum(emit) - strtonum(sig)
    got_sig=0
}
```

## 可能的 Root Cause

1. **SDMA engine 真的 hang**（hardware hang）— ring buffer 的 RPTR 不動
2. **KIQ blocked**（TLB invalidation / compute queue starvation）— SDMA 等 KIQ 完成
3. **RDMA pin quota 滿** → staging pin 被 kernel 拒絕 → fence 永遠不 signal → cross-ref: [rdma_pin_rejected](rdma_pin_rejected.md)
4. **Suballocator IB 槽耗盡**（`intr=false` 路徑無 timeout）→ kernel thread stuck → cross-ref: HANG_VULN_ANALYSIS 漏洞一
5. **TTM error path fence wait 無 timeout** → kernel worker 永久 blocked

## 相關案例

- [alibaba_rdma_underflow](../cases/alibaba_rdma_underflow/case.md) — RDMA counter 溢位導致所有 pin 被拒
- [sdma_fence_evidence](../cases/sdma_fence_evidence/) — 2026-05-06 fence snapshot 實證

## 參考

- [SDMA Fence Debug Playbook](../playbooks/sdma_fence_debug.md)

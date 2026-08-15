# Timeout death map — AQL/HSA request lifecycle × RDMA BO pin

> 從「一個請求如何走完 AQL→HSA→KFD→fence→return」出發，
> 列出每個階段可能產生 timeout 的原因，再疊加「多請求並發 × 無
> memory pool × 32 GiB cgroup」推演所有死法。最後評估當前最佳
> 保護組合仍留下的缺口。

## 1. 單一 D2H copy 請求的完整生命週期

客戶的核心路徑是 16-stream pipelined inference，每個 iter 做：

```
App: hipMemcpyAsync(host_dst, dev_src, size, D2H, stream[i])
  │
  ▼ ①
HIP/CLR: ihipMemcpyCommand → ReadMemoryCommand → enqueue
  │  如果 host_dst 不是 pinned → 走 staged pageable copy 路徑
  │  如果 host_dst 是 hipHostMalloc → 走 direct pinned copy
  │
  ▼ ②
ROCr/CLR blit manager: hsaCopyStaged / DmaBlitManager
  │  需要一塊 staging buffer (pinned host mem)
  │  → hipHostMalloc 或 suballoc pool 取得
  │  → amdgpu_pin (kernel: amdgpu_amdkfd_gpuvm_pin_bo)
  │    → dma_resv_wait (等任何 pending fence on this BO)
  │    → TTM validate (可能 evict 其他 BO)
  │    → pin_count++, rdma_pinned_bytes += size
  │
  ▼ ③
SDMA blit: submit AQL packet to SDMA queue
  │  HW queue descriptor → AQL doorbell → SDMA engine
  │  GPU 側 DMA: dev_src → staging_buf (pinned host page)
  │
  ▼ ④
ROCr signal: hsa_signal_store_screlease(completion_signal, 0)
  │  SDMA engine 完成 → interrupt → KFD event → signal fires
  │
  ▼ ⑤
ROCr wait: InterruptSignal::WaitRelaxed(signal, timeout)
  │  → KFD ioctl WAIT_EVENTS
  │  → schedule_timeout(timeout_ticks)
  │  → 等 signal 從 GPU interrupt 完成
  │
  ▼ ⑥
Return to HIP: hipStreamSynchronize / callback
  │
  ▼ ⑦ (最終)
hipHostFree / hipFree 釋放 staging 或 user buffer
  │  → ihipFree → SyncAllStreams (等所有 stream drain)
  │  → amdgpu_unpin → rdma_pinned_bytes -= size
```

### 同時間，RDMA BO pin 的生命週期（外部請求，隨時到達）

```
RDMA NIC: ibv_reg_mr(pd, gpu_buf, size, access)
  │
  ▼ ⓐ
IB core → peer_memory_client → amd_acquire
  │  查 kfd_process_find_bo_from_interval → 取 amdgpu_bo ref
  │
  ▼ ⓑ
amd_get_pages → amdgpu_amdkfd_gpuvm_pin_bo
  │  → dma_resv_wait (等 pending fence)
  │  → amdgpu_bo_pin(domain)
  │  → rdma_pinned_bytes += size (quota check)
  │  → 如果 rdma_pinned_bytes > dmabuf_pin_max_mb → reject -ENOSPC
  │  → 如果 TTM eviction 需要 → 可能 evict 其他 BO
  │  → 5× retry on -EAGAIN (gtt_lock_timeout_ms)
  │
  ▼ ⓒ
amd_dma_map → get_sg_table → NIC 拿到 DMA address
  │  RDMA NIC 現在可以直接 read/write GPU memory
  │
  ▼ (持續期間: 秒到分鐘，無上限)
  │  NIC 隨時做 RDMA READ/WRITE 到 pinned pages
  │
  ▼ ⓓ
ibv_dereg_mr → IB core → amd_dma_unmap
  │  → amdgpu_bo_reserve (可能阻塞等 fence)
  │  → amdgpu_bo_sync_wait (等 non-KFD fence drain)
  │  → put_sg_table
  │
  ▼ ⓔ
amd_put_pages → amdgpu_amdkfd_gpuvm_unpin_bo
  │  → amdgpu_bo_unpin → pin_count--
  │  → rdma_pinned_bytes -= size (只在 mem_type == VRAM 時)
  │
  ▼ ⓕ
amd_release → amdgpu_amdkfd_gpuvm_put_bo_ref → kfree(mem_context)
```

## 2. 每個階段的 timeout 死點

圖裡的 p99/max 數據對應到代碼位置：

### 階段 ① HIP enqueue (p99 19.33s / max 35.11s for hipMemcpyAsync)

| 死點 | 代碼位置 | timeout 來源 | 為什麼會卡 |
|---|---|---|---|
| **D2H-1: SyncAllStreams 在 enqueue 前** | `hip_memory.cpp:112` `SyncAllStreams()` inside `ihipFree` (如果 free 和 copy 交織) | 無 deadline — 等所有 stream 的所有 pending command 完成 | 16 streams 各有 pending blit，任一 blit 卡住 → 所有 free 卡住 |
| **D2H-2: staging buffer 分配** | CLR `DmaBlitManager::hsaCopyStaged` → `hipHostMalloc` 內部 | `amdgpu_pin` 的 `dma_resv_wait(MAX_SCHEDULE_TIMEOUT)` | 32GB cgroup 已滿，TTM 無法 evict 足夠空間，pin 等待其他 BO 的 fence |

### 階段 ② amdgpu_pin (p99 含在 hipMalloc 16.25s / max 24.93s)

| 死點 | 代碼位置 | timeout 來源 | 為什麼會卡 |
|---|---|---|---|
| **PIN-1: dma_resv_wait inside pin path** | `amdgpu_amdkfd_gpuvm.c:1636` → `amdgpu_bo_pin` → TTM validate → `dma_resv_wait_timeout(MAX_SCHEDULE_TIMEOUT)` | **無限** (kernel default) 或 `gtt_lock_timeout_ms` (V15.x) | 一個 BO 上的 fence 由另一個 stream 的 SDMA blit 持有，那個 blit 正在等 queue eviction 恢復 |
| **PIN-2: TTM eviction cascade** | `amdgpu_ttm.c` eviction path | 無 deadline — TTM 逐一 evict 直到騰出空間 | 32GB cgroup 下所有 host pinned pages 都被 16 streams + RDMA 佔滿，TTM 需要 evict 的 BO 也有 active fence |
| **PIN-3: rdma_pinned_bytes quota reject** | `amdgpu_amdkfd_gpuvm.c:1603-1604` | 立即 reject (-ENOSPC) | 好的死法——快速失敗，但呼叫者（ROCr blit）沒有 retry-with-backoff，直接把 error 變成 `hipErrorOutOfMemory` |

### 階段 ③ SDMA blit (硬體層)

| 死點 | 代碼位置 | timeout 來源 | 為什麼會卡 |
|---|---|---|---|
| **SDMA-1: suballoc slot exhaustion** | `amdgpu_sa_bo_new` → `wait_for_completion(fence)` | `suballoc_timeout_ms` (V15.x) 或 `MAX_SCHEDULE_TIMEOUT` | 所有 suballoc slots 被前面的 blit 佔住，那些 blit 的 fence 沒 signal（因為 queue evicted） |
| **SDMA-2: queue evicted mid-blit** | KFD: memcg reclaim → `svm_range_unmap_from_cpu` → `kgd2kfd_quiesce_mm` | `drm_sched_timeout` (10s) 是唯一的 hard watchdog | cgroup 32GB 超了 → kernel 回收 → evict KFD queue → SDMA fence 永不 signal |

### 階段 ④⑤ signal wait (WAIT_EVENTS max ~full 10min run; WaitRelaxed 對應 p99)

| 死點 | 代碼位置 | timeout 來源 | 為什麼會卡 |
|---|---|---|---|
| **WAIT-1: KFD WAIT_EVENTS infinite** | `kfd_events.c` `schedule_timeout(UINT_MAX)` | **原始：無限**；V17.4.1: 2s slice + 30s wall | queue 被 evict，fence 永遠不 signal，event 永遠不 fire |
| **WAIT-2: WaitRelaxed infinite** | `interrupt_signal.cpp` `WaitRelaxed(0xFFFFFFFF...)` | **原始：無限**；V17.4: `ROCR_SIGNAL_WAIT_MAX_MS` opt-in | 傳播 WAIT-1 — KFD 不回來，ROCr 永遠等 |
| **WAIT-3: signal 被 orphan** | `kfd_events.c` event 在 queue eviction 後沒有 mark done | 無 cleanup contract | queue evict 後 signal 還在 event_list，但沒有 consumer 會 fire 它 |

### 階段 ⑥⑦ hipFree / release (p99 3.96s / max 35.12s)

| 死點 | 代碼位置 | timeout 來源 | 為什麼會卡 |
|---|---|---|---|
| **FREE-1: SyncAllStreams** | `hip_memory.cpp:112` | 無 deadline — 等所有 stream drain | 任一 stream 有一個 stuck blit → 所有 hipFree 卡住 |
| **FREE-2: async→sync fallback** | CLR `hipFreeAsync` fallback to `ihipFree` | `HIP_FREE_SYNC_FAIL_MS` (V17.4, opt-in) | hipFreeAsync 找不到合適 stream → 退化為 sync free → 同 FREE-1 |

### 階段 ⓑ RDMA BO pin (external, 無限到達速率)

| 死點 | 代碼位置 | timeout 來源 | 為什麼會卡 |
|---|---|---|---|
| **RDMA-1: pin_bo dma_resv_wait** | `kfd_peerdirect.c:272` → `amdgpu_amdkfd_gpuvm_pin_bo` | `gtt_lock_timeout_ms` retry 5× with 10ms sleep | fence 等待一個 evicted queue |
| **RDMA-2: quota saturated (underflow)** | `amdgpu_amdkfd_gpuvm.c:1603` `rdma_pinned_bytes` is `(u64)-1` | 立即 reject | orphan reaper double-decrement → counter 永遠滿 → 所有後續 RDMA pin 都 reject |
| **RDMA-3: TTM eviction for RDMA pin** | `amdgpu_bo_pin → ttm_bo_validate` | 同 PIN-2 | RDMA pin 跟 16 streams 的 staging pin 搶 TTM 空間，在 32GB cgroup 下互相 evict |

### 階段 ⓓⓔ RDMA unpin (ibv_dereg_mr)

| 死點 | 代碼位置 | timeout 來源 | 為什麼會卡 |
|---|---|---|---|
| **DEREG-1: bo_sync_wait** | `kfd_peerdirect.c:396` `amdgpu_bo_sync_wait` | 無 deadline — 等 non-KFD fence drain | 如果 TTM 正在做 migration，fence 可能等很久 |
| **DEREG-2: orphan reaper race** | `amdgpu_kfd_rdma_v155.c:296-305` | reaper 和 unpin 同時 decrement → u64 underflow | 觸發 RDMA-2，所有後續 RDMA pin 永久死亡 |

### 階段 K-1: SVM/mmu_notifier (AMDKFD_IOC_SVM p99 69.37s / max 127.97s)

| 死點 | 代碼位置 | timeout 來源 | 為什麼會卡 |
|---|---|---|---|
| **SVM-1: prange mutex contention** | `kfd_svm.c:3024` `mutex_lock(&svms->lock)` | 無 deadline — D state mutex | 另一個 thread 持有 mutex 在做 `svm_range_set_attr`，裡面卡在 `dma_resv_wait` |
| **SVM-2: synchronous quiesce** | `kfd_svm.c:2473` `kgd2kfd_quiesce_mm` | 無 deadline — 等所有 queue drain | 在 mmu_notifier callback 裡同步等，但 queue 被 evict 了 drain 不了 |
| **SVM-3: mmu_notifier → dma_resv_wait** | `amdgpu_hmm.c:741` | `gtt_lock_timeout_ms` 或 `MAX_SCHEDULE_TIMEOUT` | invalidate callback 持 mm_sem + notifier_lock，等一個永遠不 signal 的 fence |

## 3. 多請求並發 × 無 memory pool → timeout 疊加效應

32GB cgroup 下的記憶體分配（無 pool 保護）：

```
Budget: 32 GiB cgroup memory.max

Consumers (steady state, 16 streams pipelined):
  16 × KV pinned host bufs   = 16 × 1 GiB = 16 GiB (hipHostMalloc Portable)
  16 × staging bufs (CLR)    = 16 × ~64 MB = 1 GiB (suballoc or per-copy pin)
  ROCr ring bufs + doorbell  = ~0.5 GiB
  libc heap + python runtime = ~2 GiB
  ─────────────────────────────────────────
  Subtotal compute:           ~19.5 GiB

RDMA (unbounded arrival, no pool):
  N × ibv_reg_mr             = N × 32 MB chunks (typical)
  每個 pin 持續秒到分鐘
  如果 N=400 → 400 × 32 MB = 12.8 GiB

  Total committed:            ~32.3 GiB → 超過 cgroup cap
```

### 超過 cgroup 的瀑布效應

```
Time T+0:   committed=31.5 GiB, 接近 cap
            ┌─ stream[7] 做 hipMemcpyAsync D2H (需要 64MB staging pin)
            │   → amdgpu_pin → TTM validate → 需要 evict
            │   → 但所有 pinned pages 都被 16 streams + RDMA 持有
            │   → dma_resv_wait 等 fence... (PIN-1)
            │
Time T+1s:  RDMA request #401 到達 (32MB ibv_reg_mr)
            │   → amd_get_pages → amdgpu_pin → quota check OK
            │   → TTM validate → 也需要 evict → 跟 stream[7] 搶
            │   → 或者 quota 剛好超了 → -ENOSPC → NIC 重試...
            │
Time T+2s:  committed=32.1 GiB → memcg reclaim 開始
            │   → kernel direct reclaim → pageout/pgpgin storm
            │   → 觸摸到 KFD SVM range → svm_range_unmap_from_cpu
            │   → queue_refcount > 0 → "Freeing queue vital buffer ... queue evicted"
            │   → kgd2kfd_quiesce_mm (SVM-2) — 但 queue 被 evict 了
            │   → prange mutex 被持有 (SVM-1)
            │
Time T+3s:  stream[7] 的 SDMA blit fence 永遠不 signal (SDMA-2)
            │   → WaitRelaxed 永遠等 (WAIT-2)
            │   → stream[7] 的 staging pin 永遠不釋放
            │
Time T+5s:  stream[0..6,8..15] 的 hipHostFree 嘗試 SyncAllStreams (FREE-1)
            │   → 等 stream[7]... 永遠等
            │   → 所有其他 stream 也卡住
            │
Time T+10s: hung_task_timeout fires
            │   → dmesg: "task pinned_host_rep blocked for more than 10 seconds"
            │   → dmesg: "Freeing queue vital buffer 0x..., queue evicted"
            │
Time T+12s: 新的 RDMA ibv_reg_mr → amd_get_pages → pin 也被 TTM eviction 阻塞
            │   → RDMA 通道也 stall
            │
Time T+∞:   全部 16 streams + RDMA 全部 stuck
            │   只有 kill -9 或 GPU reset 能解
```

**關鍵：只需要一個 stream 的一個 fence stuck，就足以通過 SyncAllStreams 級聯到所有 16 streams + 所有 hipFree + 所有新 pin。**

### RDMA orphan reaper 疊加

如果在上面的瀑布中，有一個 RDMA BO 的 owner 進程被 OOM-kill：

```
Time T+6s:  memcg OOM-killer → kill python3 (churner) 或 RDMA owner
            │   → kfd_process_destroy → BO release path
            │   → 但 BO 上有 active fence (stuck 的那個)
            │   → reaper 收走 BO → atomic64_sub(op->bytes, rdma_pinned_bytes)
            │   
Time T+7s:  同一 BO 的 ibv_dereg_mr 異步到達
            │   → amd_put_pages → amdgpu_amdkfd_gpuvm_unpin_bo
            │   → atomic64_sub(bo_size, rdma_pinned_bytes)  ← 第二次 sub！
            │   → rdma_pinned_bytes wraps to (u64)-1
            │
Time T+∞:   所有後續 RDMA pin: "pinned=17592186044412MB + new=2MB > max=4096MB"
            │   → 永久 reject → RDMA 通道永久死亡
            │   → 需要 module reload 才能恢復
```

## 4. 當前最佳保護組合 vs. 剩餘死法

### 最佳保護組合（V17.4 runtime + V17.4.1 driver + V15.5 modprobe）

```bash
# Driver
options amdgpu gtt_lock_timeout_ms=4000 dmabuf_pin_max_mb=4096 \
               rdma_pin_debug=1 gtt_multi_window=32 dmabuf_reject_new_pins=0
options amdkcl suballoc_timeout_ms=4000

# ROCr
export ROCR_SERVICE_SURVIVAL=1
export ROCR_SIGNAL_WAIT_MAX_MS=4000
export ROCR_KFD_PROGRESS_POLL_MS=50

# HIP
export HIP_SERVICE_SURVIVAL=1
export HIP_PAGEABLE_COPY_GUARD=1
export HIP_PAGEABLE_COPY_MIN_FREE_MB=8192
export HIP_PAGEABLE_COPY_WAIT_MS=0
export HIP_FREE_SYNC_FAIL_MS=4000
export HIP_FREE_REJECT_ON_ACTIVE=1
export HIP_HOST_GUARD_WAIT_MS=4000
export HIP_VRAM_GUARD_WAIT_MS=4000
```

### 套用後的保護效果 vs. 殘留死法

| 死點 | 最佳組合的保護 | 殘留風險 |
|---|---|---|
| **PIN-1** dma_resv_wait | `gtt_lock_timeout_ms=4000` → 4s 超時 | ✅ 有界。但 timeout 後 return `-ETIME`，CLR blit 把它變成 `hipErrorOutOfMemory`。**客戶代碼不檢查 → 繼續用 stale buffer → 資料靜默損壞** |
| **PIN-2** TTM eviction cascade | 無直接保護。`dmabuf_pin_max_mb` 只管 RDMA | ❌ **殘留**。16 streams 的 hipHostMalloc pin 不受 quota 限制（它們不是 RDMA pin），在 32GB 下仍會把 TTM 逼到 evict cascade |
| **PIN-3** rdma quota reject | `dmabuf_pin_max_mb=4096` → 快速 reject | ✅ 已保護。但 reject 被 NIC stack 看到是 -ENOSPC → **IB verb 層沒有 backoff 機制 → 立刻重試 → CPU spin** |
| **SDMA-1** suballoc | `suballoc_timeout_ms=4000` | ✅ 有界。但 slot 沒 reclaim — **timeout 後 slot 永久泄漏**，pool 容量逐步縮小 |
| **SDMA-2** queue evicted | 無直接保護 | ❌ **殘留**。32GB cgroup + 16 streams 仍會觸發 memcg eviction。eviction 本身是 kernel behavior，保護組合只管 userspace 的等待行為 |
| **WAIT-1** KFD WAIT_EVENTS | V17.4.1: 2s slice + 30s wall | ✅ 有界。但 30s 才返回 → **30s 的 service stall 對 LLM serving 不可接受**（SLA 通常 < 5s） |
| **WAIT-2** WaitRelaxed | `ROCR_SIGNAL_WAIT_MAX_MS=4000` | ✅ 有界 4s。**但 timeout 後 signal 不 cancel（F6）→ stale event 在 KFD event_list → 下次 wait 可能 spurious return** |
| **WAIT-3** signal orphan | 無直接保護 | ❌ **殘留**。queue evict 後 signal 不 mark done → 即使 WaitRelaxed timeout 了，kernel 側的 event 仍在 → 資源泄漏 |
| **FREE-1** SyncAllStreams | `HIP_FREE_SYNC_FAIL_MS=4000` | ✅ 4s 有界。但 fail 後 `ihipFree` 仍然需要 release memory → **如果 BO 上還有 active fence，release path 又會等** |
| **FREE-2** async→sync | `HIP_FREE_REJECT_ON_ACTIVE=1` | ✅ reject 而非等。但 reject 後 memory 泄漏 — **caller 不知道 free 失敗了，buffer 永久佔著 cgroup quota** |
| **RDMA-1** pin dma_resv | `gtt_lock_timeout_ms=4000` + 5× retry | ✅ 有界 ~20s max。但每次 retry sleep 10ms → **RDMA 通道 stall 20s 對 inference serving 太長** |
| **RDMA-2** counter underflow | V17.4.1: reaper ownership takeover | ✅ 已修。**但 fix 只在 AFDEAPAC/amdgpu 分支，upstream 未修** |
| **RDMA-3** TTM eviction | 同 PIN-2 | ❌ **殘留** |
| **DEREG-1** sync_wait | 無保護 | ❌ **殘留**。ibv_dereg_mr 時 `amdgpu_bo_sync_wait` 無 deadline → 在 fence stuck 時 dereg 也 hang |
| **SVM-1** prange mutex | 無保護 | ❌ **殘留**。kernel D-state mutex，不可被 kill |
| **SVM-2** synchronous quiesce | 無保護 | ❌ **殘留**。mmu_notifier callback 裡同步 quiesce，觸發 dmesg `queue evicted` |
| **SVM-3** hmm dma_resv_wait | `gtt_lock_timeout_ms=4000` | ✅ 有界。但 timeout 後 mmu_notifier 返回 `true`（"我處理好了"），**實際上 BO 映射未清理 → stale TLB → 後續 page fault** |

### 殘留死法分類

**A. 仍然會 permanent hang 的（kill -9 或 GPU reset 才能救）**

| ID | 路徑 | 為什麼最佳保護還擋不住 |
|---|---|---|
| **DEATH-A1** | SVM-1 → SVM-2 → SDMA-2 | prange mutex 是 kernel mutex，無 trylock。quiesce 在 mmu_notifier callback 裡，mm_sem 被持有。多層鎖形成不可解的 D-state chain。**保護組合完全碰不到 kernel mutex。** |
| **DEATH-A2** | DEREG-1 | ibv_dereg_mr 走 `amd_dma_unmap → amdgpu_bo_sync_wait`，無 deadline。如果 fence stuck，RDMA stack 的 teardown thread 永久 hang。**保護組合不管 RDMA unpin 路徑。** |

**B. 有界但仍會 service-level stall（> 5s SLA）的**

| ID | 路徑 | 最佳情況下的 stall 時間 |
|---|---|---|
| **DEATH-B1** | WAIT-1 → WAIT-2 chain | 30s (KFD wall) + 4s (ROCr) = **最多 34s per stream** |
| **DEATH-B2** | PIN-1 → FREE-1 chain | 4s (gtt_lock) + 4s (free sync) = **最多 8s，但 ×16 streams sequential** |
| **DEATH-B3** | RDMA-1 retry loop | 5 × (4s gtt_lock + 10ms sleep) = **~20s per RDMA pin** |

**C. 靜默損壞 / 資源泄漏（不 hang 但行為錯誤）**

| ID | 路徑 | 後果 |
|---|---|---|
| **DEATH-C1** | PIN-1 timeout → stale buffer | gtt_lock timeout 後 pin 返回 error，但 CLR blit 可能已經把 staging buffer 地址交給 SDMA → **DMA 到已 unpin 的 page → data corruption** |
| **DEATH-C2** | FREE-2 reject → memory leak | hipFree reject → buffer 永遠不 release → cgroup committed 只增不減 → **加速觸發下一次 cgroup eviction** |
| **DEATH-C3** | WAIT-2 timeout → signal leak | WaitRelaxed timeout → signal 不 cancel → **KFD event 泄漏 → event_list 無限增長 → KFD ioctl 越來越慢** |
| **DEATH-C4** | SVM-3 timeout → stale TLB | mmu_notifier 返回 true 但 BO 映射未清理 → **GPU 可能讀到已回收的 host page → 靜默錯誤資料** |
| **DEATH-C5** | suballoc slot leak (SDMA-1) | timeout 後 slot 不回收 → **SDMA suballoc pool 容量遞減 → 後續 blit 更容易 timeout → 正反饋 loop** |

## 5. 生命週期 × 多請求的 timeout 扇出圖

```
                    ┌────────────────────────────────────────────────┐
                    │            32 GiB cgroup memory.max            │
                    └──────────────────┬─────────────────────────────┘
                                       │
           ┌───────────────────────────┼───────────────────────────┐
           │                           │                           │
    16 × hipHostMalloc          N × ibv_reg_mr              memcg reclaim
    (no pool, per-iter)        (no pool, unbounded)         (kernel-driven)
           │                           │                           │
           ▼                           ▼                           ▼
     amdgpu_pin ×16             amdgpu_pin ×N            pgpgin/pgpgout storm
     (PIN-1,2)                  (RDMA-1,2,3)               │
           │                           │                   ▼
           │       ┌───────────────────┘            svm_range_unmap_from_cpu
           │       │                                (SVM-1,2,3)
           ▼       ▼                                       │
     TTM eviction battleground                             ▼
     (all pins fight for 32GB)                    "queue evicted" (SDMA-2)
           │                                               │
           ▼                                               ▼
     fence stuck on evicted queue ◄────────────────── fence never signals
           │
     ┌─────┴──────────────────────────────┐
     │                                    │
     ▼                                    ▼
  WaitRelaxed ×16                  ibv_dereg_mr stall
  (WAIT-1,2,3)                     (DEREG-1)
     │                                    │
     ▼                                    ▼
  SyncAllStreams hang              RDMA counter underflow
  (FREE-1)                         (RDMA-2) → permanent
     │
     ▼
  ALL 16 streams dead
  + ALL hipFree blocked
  + ALL future pins blocked
  = SERVICE-LEVEL PERMANENT STALL
```

**一個 cgroup eviction event 就能 fan out 到整個 service。**

## 6. 結論：真正需要修的三件事

| 優先級 | 修什麼 | 為什麼現有保護不夠 |
|---|---|---|
| **P0** | **kernel: `kgd2kfd_quiesce_mm` 必須異步化** | 這是 DEATH-A1 的唯一 root cause。在 mmu_notifier callback 裡同步等 queue drain，持 mm_sem，形成不可破的 D-state chain。沒有任何 userspace ENV 能救。 |
| **P0** | **kernel: `amd_dma_unmap` 的 `bo_sync_wait` 需要 deadline** | 這是 DEATH-A2 的唯一 root cause。RDMA teardown path 裡的 fence wait 完全不受 `gtt_lock_timeout_ms` 控制（那個只管 `amdgpu_hmm.c`）。 |
| **P1** | **runtime: hipHostMalloc 的 pin 需要受 budget 限制** | PIN-2 和 TTM eviction cascade 的 root cause 是 16 streams 的 pinned host memory 不受任何 quota 管理。它們不走 `dmabuf_pin_max_mb`（那只管 RDMA pin）。在 32GB cgroup 下，16 × 1GB pinned + RDMA churn = 必然超過 cap。`HIP_HOST_GUARD_MAX_MB` 只管 HIP 層的 accounting，**不管 kernel 層的 TTM/cgroup 互動**。 |

這三個修好之後，圖裡的 p99 69.37s (AMDKFD_IOC_SVM) 和 max 127.97s 會降到 < 4s（被 `gtt_lock_timeout_ms` bound），所有 DEATH-A 路徑消失，剩下的都是 DEATH-B（有界 stall）和 DEATH-C（可觀測的 degradation），對 LLM serving SLA 可接受。

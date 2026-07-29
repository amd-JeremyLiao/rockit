# Wait lifecycle — unbounded waits, missing cancel, deadline-budget proposal

> Companion to [`DESIGN_FLAWS.md`](./DESIGN_FLAWS.md) §F2.
> Per-wait audit of every wait point in the customer hang path.

## 1. The full wait stack (bottom → top)

When a customer inference process hangs, `cat /proc/<pid>/stack` shows
a stack from user space down to the kernel.  The wait-point chain,
from the deepest kernel wait to the topmost user-space block:

```
         USER SPACE
         ──────────
  L7  │  torch → at::native::copy_kernel_cuda → hip::hipMemcpyWithStream
  L6  │    └─ amd::roc::DmaBlitManager::hsaCopyStaged
  L5  │         └─ amd::roc::VirtualGPU::HwQueueTracker::CpuWaitForSignal
  L4  │              └─ rocr::core::InterruptSignal::WaitRelaxed
         ──────────
         KERNEL SPACE (via KFD ioctl / signal wait)
         ──────────
  L3  │              └─ kfd_wait_on_events (schedule_timeout INFINITE)
  L2  │    ──── OR ────
      │              └─ dma_resv_wait_timeout(MAX_SCHEDULE_TIMEOUT)
      │                   [inside amdgpu_hmm_invalidate_gfx mmu_notifier]
  L1  │    ──── OR ────
      │              └─ __mutex_lock(prange_mutex)
      │                   [inside svm_range_set_attr / svm_range_unmap_from_cpu]
  L0  │    ──── OR ────
      │              └─ wait_for_completion(suballoc_fence)
      │                   [inside amdgpu_sa_bo_new / amdkcl suballoc]
         ──────────
```

Every level waits on the level below.  **If any single level hangs
forever, every level above it hangs forever.**  Today the chain has
no mechanism to propagate a deadline or cancel downward.

## 2. Per-wait audit

### L0 — suballoc fence (`amdkcl`)

| property | value |
|---|---|
| code | `wait_for_completion(fence)` in `amdgpu_sa_bo_new` |
| default deadline | `MAX_SCHEDULE_TIMEOUT` (infinite) |
| V15.x fix | `suballoc_timeout_ms` module param, default 0 (off) |
| cancel/cleanup | none — if the GFX fence never completes, the suballoc is wedged |
| customer impact | blocks SDMA staging buffer allocation; upstream of L4 hang |

**Gap:** Even with `suballoc_timeout_ms=4000`, the timeout returns
`-ENOMEM` to the caller, which passes it up as "allocation failed",
but the pending fence **is still consuming a suballoc slot**.
Successive allocations from the same pool will also fail because the
wedged slot is not reclaimed.  A timeout without reclaim is a leak.

### L1 — prange mutex (`kfd_svm.c`)

| property | value |
|---|---|
| code | `__mutex_lock.constprop.0` in `svm_range_set_attr` (L1603) and `svm_range_unmap_from_cpu` (via `kgd2kfd_quiesce_mm`) |
| default deadline | none — kernel mutex, D-state |
| cancel/cleanup | none |
| customer impact | 4/23 stack: `task:pinned_host_rep state:D blocked for more than 10 seconds` |

**Gap:** `kgd2kfd_quiesce_mm` is called **synchronously** from
`svm_range_unmap_from_cpu` (kfd_svm.c:2473) while the mmu_notifier
invalidate callback holds mm_sem.  If the quiesce itself needs to
wait for a fence on a queue that was evicted, the whole path deadlocks.
This is the K-1 bug from `15_kernel_racelab.md`.

Source evidence:

```c
// kfd_svm.c:2468-2476 (amdgpu 6.14.14)
if (atomic_read(&prange->queue_refcount)) {
    int r;
    pr_warn("Freeing queue vital buffer 0x%lx, queue evicted\n",
            prange->start << PAGE_SHIFT);
    r = kgd2kfd_quiesce_mm(mm, KFD_QUEUE_EVICTION_TRIGGER_SVM);
    if (r)
        pr_debug("failed %d to quiesce KFD queues\n", r);
}
```

The `pr_warn` is the customer's `Freeing queue vital buffer ... queue evicted`.

### L2 — `dma_resv_wait_timeout` (`amdgpu_hmm.c`)

| property | value |
|---|---|
| code | `amdgpu_hmm_invalidate_gfx` line 741–742 |
| default deadline | `MAX_SCHEDULE_TIMEOUT` |
| V15.x fix | `gtt_lock_timeout_ms` module param (default 0 = infinite; V15.5 set 4000) |
| cancel/cleanup | none — if the DMA reservation fence never signals, the mmu_notifier callback blocks forever |
| customer impact | blocks mmu_notifier → blocks any `munmap` / `mremap` / page migration on that VA range |

Source evidence:

```c
// amdgpu_hmm.c:741-742
r = dma_resv_wait_timeout(amdkcl_ttm_resvp(&bo->tbo),
                          DMA_RESV_USAGE_BOOKKEEP,
                          false, MAX_SCHEDULE_TIMEOUT);
```

**Gap:** `amdgpu_hmm_invalidate_gfx` is an mmu_interval_notifier
callback.  It runs under mm_sem.  It holds `adev->notifier_lock`.
While it waits indefinitely on the fence, no other mmu_notifier for
the same device can proceed (the `notifier_lock` is device-wide).
This amplifies one stuck fence to a device-wide lockout.

With `gtt_lock_timeout_ms=4000` the wait is bounded, but the return
value `r <= 0` produces a `DRM_ERROR` and then returns `true` (meaning
"invalidation handled"), which tells the mm to continue tearing down
the VMA even though the fence never completed.  The BO retains a stale
reference to a now-unmapped user page.  This is safe **only** because
TTM has its own move-notify, but the interaction is fragile and
undocumented.

### L3 — `kfd_wait_on_events` (`kfd_events.c`)

| property | value |
|---|---|
| code | `schedule_timeout(timeout)` inside `kfd_wait_on_events` |
| default deadline | `KFD_SIGNAL_EVENT_LIMIT = 0xFFFFFFFF` (effectively infinite) |
| V17.4.1 fix | 2 s slice + 30 s wall clock + `amdgpu_reset_pending()` recheck |
| cancel/cleanup | returns `-ETIME` to ROCr; does **not** cancel the underlying fence |
| customer impact | infinite `WaitRelaxed` if the fix is not present |

**Gap:** The 30 s wall-clock deadline is hardcoded.  There is no way
for userspace to pass a different deadline via the ioctl.  A workload
that has a 100 ms SLA (LLM inference serving) will burn 30 s of latency
before ROCr sees `-ETIME`.  The fix should accept a per-call deadline
from ROCr via the ioctl argument struct.

V17.4.1 checks `amdgpu_reset_pending()` per attached GPU on every 2 s
wakeup.  This covers the "GPU hard-reset" case but not the "queue
evicted, fence never re-armed" case.  In the queue-eviction case, no
GPU-wide reset is pending, `amdgpu_reset_pending()` returns false, and
the 30 s deadline is the only escape.

### L4 — `WaitRelaxed` (ROCr `interrupt_signal.cpp`)

| property | value |
|---|---|
| code | `rocr::core::InterruptSignal::WaitRelaxed` |
| default deadline | `0xFFFFFFFFFFFFFFFF` ticks (passed from HIP layer) |
| V17.4 fix | `ROCR_SIGNAL_WAIT_MAX_MS` opt-in clamping |
| cancel/cleanup | returns `0` (signal value 0 = success) or the current value on timeout |
| customer impact | the actual "permanently parked thread" |

Source evidence (from `AFDEAPAC/rocr`, `interrupt_signal.cpp`):

```cpp
const bool survival_wait =
    core::Runtime::runtime_singleton_->flag().rocr_service_survival();
uint64_t effective_timeout = timeout;
if (survival_wait) {
  const uint64_t max_wait_ticks =
      (hsa_freq / 1000) *
      core::Runtime::runtime_singleton_->flag().rocr_signal_wait_max_ms();
  if (effective_timeout > max_wait_ticks) {
    effective_timeout = max_wait_ticks;
  }
}
```

**Gap:** When the timeout fires and ROCr returns the current signal
value, it does **not** issue a cancel to the kernel.  The KFD event
registered for this signal remains armed.  If the same signal is
reused (common in the SDMA blit pool), the stale KFD event fires
spuriously on the next unrelated fence completion.

### L5–L7 — HIP / CLR layers

These are pure wrappers.  They propagate the ROCr error code upward.
The critical gap is in `hipFree`: when `hipFreeAsync` cannot find a
suitable stream, it falls back to synchronous free, which calls
`amd::Memory::release()` → `roc::Memory::destroy()` → `dma_resv_wait`
loop.  This is the F7 "silent shape change" documented in
`DESIGN_FLAWS.md`.

V17.4 gated this with `HIP_FREE_SYNC_FAIL_MS` (opt-in).

## 3. Cross-layer interactions that produce the customer hang

The customer's 4/23 hang is a **L1 ↔ L2 lock inversion**:

```
Thread A (user):  hipMallocManaged → kfd_ioctl → svm_range_set_attr
                  → takes prange mutex
                  → issues dma_resv_wait_timeout(MAX_SCHEDULE_TIMEOUT)
                  → blocked on fence F owned by SDMA blit B

Thread B (kernel): mmu_notifier fires → svm_range_unmap_from_cpu
                  → wants prange mutex (Thread A holds it)
                  → blocked in __mutex_lock

Thread C (user):  hipMemcpyAsync D2H via SDMA → CpuWaitForSignal
                  → kfd_wait_on_events → schedule_timeout INFINITE
                  → waiting for blit B to complete so fence F signals

SDMA blit B:     waiting for suballoc slot freed by an earlier blit
                  whose fence depends on a KFD queue that was evicted
                  by memcg.  → circular wait → deadlock.
```

No single fix at any one level breaks this.  The structural fix is to
impose **deadline budgets** that flow downward: if ROCr has a 100 ms
budget, the KFD ioctl must know it has at most 100 ms, and the
`dma_resv_wait` inside the ioctl must use `min(gtt_lock_timeout_ms,
remaining_budget)`.

## 4. Deadline-budget proposal

Add a `u64 deadline_ns` field to the KFD ioctl argument struct for:

- `KFD_IOC_WAIT_EVENTS` (currently `timeout` is in ticks, per-signal)
- `KFD_IOC_SVM_ATTR` (currently no timeout at all)
- `KFD_IOC_ALLOC_MEMORY` / `KFD_IOC_MAP_MEMORY` (fence waits inside)

Rules:

1. **`deadline_ns = 0` means "use system default"** (current behavior,
   backward compat).
2. **`deadline_ns > 0` is an absolute `CLOCK_MONOTONIC` deadline.**
   Every internal `schedule_timeout` / `dma_resv_wait_timeout` call
   computes `remaining = deadline_ns - ktime_get_ns()` and uses
   `min(remaining, system_default)`.
3. **Userspace ROCr sets `deadline_ns` from**
   `ktime_get_ns() + ROCR_SIGNAL_WAIT_MAX_MS * 1e6`.  This propagates
   the user's deadline all the way to the deepest kernel wait.
4. **If `remaining <= 0` at any wait point, return `-ETIME`
   immediately** without sleeping.

This is analogous to `io_uring_sqe::timeout` or gRPC's
`grpc_deadline_from_millis`.

The per-ioctl change is small:

```c
// kfd_chardev.c — KFD_IOC_WAIT_EVENTS handler
static int kfd_ioctl_wait_events(struct kfd_process *p, void *data)
{
    struct kfd_ioctl_wait_events_args *args = data;
    ktime_t deadline = args->deadline_ns
                       ? ns_to_ktime(args->deadline_ns)
                       : KTIME_MAX;
    return kfd_wait_on_events(p, args->num_events, args->events_ptr,
                              (args->wait_for_all != 0),
                              &args->wait_timeout,
                              &args->result,
                              deadline);
}
```

And inside `kfd_wait_on_events`:

```c
// before each schedule_timeout:
s64 remain_ns = ktime_to_ns(ktime_sub(deadline, ktime_get()));
if (remain_ns <= 0) {
    ret = -ETIME;
    break;
}
unsigned long jiffies_remain = nsecs_to_jiffies(remain_ns);
timeout = min(timeout, jiffies_remain);
```

This is backward-compatible (`deadline_ns = 0` → old path), minimal
diff, and solves the "timeout at one layer, still blocked at another"
problem structurally.

## 5. Cancel-signal ioctl (complementary to deadlines)

When ROCr gives up waiting (timeout or process exit), it should notify
the kernel so the KFD event can be disarmed:

```c
// new ioctl: KFD_IOC_CANCEL_SIGNAL
// Input: { signal_handle, reason }
// Effect: walks kfd_process->event_list, finds matching event,
//         marks it signaled with error value, wakes any waiter.
```

Without this, the following sequence leaks:

1. ROCr calls `WaitRelaxed(signal, 100ms)` → KFD registers event.
2. Timeout fires, ROCr returns error to HIP.
3. HIP retries with a new signal → KFD registers second event.
4. Original signal's fence completes → KFD fires the **first** event.
5. No consumer reads the first event → it is consumed by the next
   `kfd_wait_on_events` call that happens to match, producing a
   spurious early-return.

`KFD_IOC_CANCEL_SIGNAL` after step 2 prevents step 5.

## 6. Per-wait fix map (what exists vs. what is needed)

| wait | existing fix | still needed |
|---|---|---|
| L0 suballoc fence | `suballoc_timeout_ms` (V15.x) | slot reclaim on timeout |
| L1 prange mutex | none | async quiesce (K-1) or a trylock with `-EAGAIN` fallback |
| L2 dma_resv_wait | `gtt_lock_timeout_ms` (V15.x) | propagate BO state on timeout (currently logs error + continues) |
| L3 kfd_wait_on_events | 2s slice + 30s wall (V17.4.1) | per-ioctl `deadline_ns` from user, queue-eviction check |
| L4 WaitRelaxed | `ROCR_SIGNAL_WAIT_MAX_MS` (V17.4) | should be default-on for MI300; cancel-signal on timeout |
| L5–L7 HIP wrappers | `HIP_FREE_SYNC_FAIL_MS`, etc. (V17.4) | should be default-on; error codes need distinction (F7) |

## 7. Testing strategy for wait-bounded behavior

A proper test for this chain:

1. Inject a **stuck fence** at L0 (suballoc) or L2 (dma_resv) using
   the `amdgpu_ttm_debugfs_inject_stuck_fence` interface (exists on
   debug builds).
2. Start a 16-stream inference-like workload that will eventually wait
   on the stuck fence.
3. Assert that the workload **returns an error within `deadline_ns`
   (e.g. 5 s)** and does not hang.
4. Assert that `dmesg` does **not** show `blocked for more than 10 seconds`.
5. Assert that after the error, a subsequent clean workload on the
   same GPU succeeds (i.e. the stuck-fence cleanup reclaimed the slot).

Today only step 2 is tested (by the customer's production workload).
Steps 1, 3, 4, 5 are all untested.

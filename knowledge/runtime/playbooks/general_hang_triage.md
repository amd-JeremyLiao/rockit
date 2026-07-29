# General Hang Triage — 通用 GPU Hang 初步分流

遇到任何 GPU hang，按此 SOP 做初步分流，判斷問題在 runtime 還是 driver 層。

## Step 1: 初始收集

```bash
sudo ./tools/collect_hang_info.sh <pid|name|all>
```

## Step 2: 看 dmesg (F2_dmesg_gpu_errors.txt)

```bash
grep -iE 'amdgpu|amdkfd|sdma|fence|evict|reset|timeout' F2_dmesg_gpu_errors.txt
```

| 有什麼 | 判斷 | 下一步 |
|--------|------|--------|
| `ring sdma timeout` | → driver: SDMA fence stuck | [sdma_fence_debug](../../driver/playbooks/sdma_fence_debug.md) |
| `queue evicted` | → driver: KFD eviction | [kfd_queue_eviction](../../driver/symptoms/kfd_queue_eviction.md) |
| `RDMA pin rejected` | → driver: RDMA quota | [rdma_pin_rejected](../../driver/symptoms/rdma_pin_rejected.md) |
| `GPU reset` / `whole chip reset` | → driver: GPU reset | [gpu_reset_timeout](../../driver/symptoms/gpu_reset_timeout.md) |
| 無 GPU 錯誤 | → 可能是 runtime 層 | 繼續 Step 3 |

## Step 3: 看 rocgdb backtrace (D_rocgdb_*_pid*.txt)

```bash
grep -E 'WaitRelaxed|SyncAllStreams|ihipFree|hsaCopyStaged|hsaKmtWait' D_rocgdb_*_pid*.txt
```

| 卡在哪 | 判斷 | 下一步 |
|--------|------|--------|
| `WaitRelaxed` | → runtime: signal wait hang | [waitrelaxed_hang](../symptoms/waitrelaxed_hang.md) |
| `SyncAllStreams` | → runtime: hipFree/hipDeviceSync stall | [hipdevicesync_hang](../symptoms/hipdevicesync_hang.md) |
| `hsaKmtWaitOnEvent` | → driver: KFD wait | [kfd_wait_events](../../driver/symptoms/kfd_wait_events.md) |

## Step 4: 看 GPU waves

```bash
grep -c 'AMDGPU Wave' D_rocgdb_*_pid*.txt
```

| Wave 數 | 判斷 |
|---------|------|
| > 0 | compute 在跑，hang 可能在 runtime（kernel spin / sync 問題） |
| 0 | 無 active compute，hang 可能在 driver/SDMA/firmware 層 |

## Step 5: 跑 fence_info 確認 SDMA

```bash
for f in $(sudo find /sys/kernel/debug/dri/ -name amdgpu_fence_info); do sudo cat "$f"; done
```

比對 `signaled` vs `emitted`，判斷是否有 ring stuck。

## 結果

經過以上 5 步，應該能判斷：
- **runtime 層問題** → 看 `knowledge/runtime/symptoms/` 對應條目
- **driver 層問題** → 看 `knowledge/driver/symptoms/` 對應條目
- **跨層問題** → 兩邊都看，注意 cross_layer_ref

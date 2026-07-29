# 手動診斷命令參考

## 1. amdgpu_fence_info — 確認哪個 ring stuck

```bash
for file in $(sudo find /sys/kernel/debug/dri/ -name amdgpu_fence_info); do
  echo "===== $file ====="
  sudo cat "$file"
done
```

**判讀重點：**
- `Last signaled fence` vs 第一個 `Last emitted`
- `signaled == emitted` → ring 健康
- `signaled < emitted` 持續不變 → ring stuck

**正確的 pending-fence parser：**
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

## 2. KFD Dynamic Debug + rls/hqds/mqds

```bash
# 開啟 KFD dynamic debug
echo 'file */amdkfd/kfd_device_queue_manager.c +p' | sudo tee /sys/kernel/debug/dynamic_debug/control
echo 'file */amdkfd/kfd_packet_manager.c +p'       | sudo tee /sys/kernel/debug/dynamic_debug/control
echo 'file */amdkfd/kfd_packet_manager_v9.c +p'    | sudo tee /sys/kernel/debug/dynamic_debug/control

# 讀取 KFD debugfs
sudo cat /sys/kernel/debug/kfd/rls    # Runlist 狀態
sudo cat /sys/kernel/debug/kfd/hqds   # HW Queue Descriptors
sudo cat /sys/kernel/debug/kfd/mqds   # Memory Queue Descriptors
```

**判讀重點：**
- rls：哪些 process 在 runlist 上
- hqds：每個 pipe/queue slot 的 mapping
- mqds：queue 的 base addr、rptr vs wptr（rptr != wptr → queue 有未消化的命令）

## 3. dmesg GPU 關鍵字過濾

```bash
dmesg | grep -iE 'amdgpu|amdkfd|kfd|sdma|fence|evict|timeout|reset|gpu.*(fault|error|hang)'
```

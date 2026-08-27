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

## 3. UMR 使用注意事項

UMR 的安全分級、cpc/waves 鐵律、Intel/AMD CPU 的 instance index 差異，全部整理在
**[umr_safety.md](umr_safety.md)**。執行任何 UMR 命令前先讀那份。

重點摘要：
- debugfs 路徑（`-r`、`--script instances`、queue_doctor）永遠安全
- `--tool cpc` 和 `-O bits,halt_waves` 是 MMIO 直讀，**條件性殺 host**
- Intel CPU 平台 instance index 要 -2（AMD CPU 自動 +2）
- 不要用 PID 判斷 GPU instance，用 PCI BDF 對應

## 4. 讀取 HSA Signal Value（從 process memory 直接讀）

當需要確認某個 HSA signal 的當前值（例如判斷 SDMA copy 的 completion signal 是否已被 signal），可以直接從 `/proc/$PID/mem` 讀取 signal value 的 host address：

```bash
#!/bin/bash
PID=2367319           # 目標 process 的 PID
ADDR=0x7ffff73ffa88   # signal value 的 host address

sudo dd if="/proc/$PID/mem" \
  iflag=skip_bytes,count_bytes \
  skip="$((ADDR))" count=8 status=none |
  xxd -e -g8
```

**如何取得 ADDR：**
- 從 rocgdb attach 後用 `print signal->val` 或 `x/gx &signal->value`
- 從 ROCm Debug Agent 輸出的 queue/dispatch 資訊
- 從 HIPER trace 的 signal metadata

**判讀重點：**
- signal value = 0 → signal 已完成（已被 signal）
- signal value > 0 → 還有 N 個未完成的操作
- signal value 長時間不變（多次讀取比對）→ 對應的 SDMA/compute 操作可能 stuck

**用途：**
- 不需要 attach debugger 就能確認 signal 狀態，對 production process 干擾最小
- 搭配 fence_info 使用：fence stuck + signal value 不動 = 確認 SDMA hang

## 5. dmesg GPU 關鍵字過濾

```bash
dmesg | grep -iE 'amdgpu|amdkfd|kfd|sdma|fence|evict|timeout|reset|gpu.*(fault|error|hang)'
```

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

## 3. UMR 暫存器讀取注意事項

### GPU instance index 與 CPU 平台的關係

UMR 內部會根據 CPU 平台調整 GPU instance index：

| CPU 平台 | UMR index 行為 | 你要做什麼 |
|---------|---------------|-----------|
| **AMD CPU** | UMR 自動 +2 | 直接用，不需調整 |
| **Intel CPU** | 需要手動 -2 | 執行時 instance index 要減 2 |

**為什麼：** UMR 設計時假設 AMD CPU 平台（iGPU 等佔了前面的 index），Intel CPU 沒有這些裝置，不做 -2 會指到錯誤的 XCC（compute chiplet），讀到的暫存器值是錯的。

**範例：**
```bash
# AMD CPU 機器 — 直接用 instance 0
sudo umr -i 0 -r sdma0.mmSDMA0_STATUS_REG

# Intel CPU 機器 — 實際 GPU 0 要用 instance -2（或確認 umr --script instances 的輸出）
sudo umr --script instances    # 先看實際 instance 編號
sudo umr -i <correct_instance> -r sdma0.mmSDMA0_STATUS_REG
```

### 不要用 PID 判斷 GPU instance

用 PID 來推斷 GPU instance 不可靠。應該用 KFD topology 或 `umr --script instances` 搭配 PCI BDF 做對應：

```bash
# 正確做法：用 BDF 對應
umr --script instances                    # 取得 UMR instance 列表
ls -l /sys/class/drm/card*/device         # 取得 DRM card → PCI BDF 對應
cat /sys/class/kfd/kfd/topology/nodes/*/properties | grep -E 'node_id|location_id'
```

詳細的 UMR 暫存器讀取 SOP 見 `dump_sdma_registers.sh` 原始碼。

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

# GPU Hang 現場採集 SOP

> 適用於 MI300X / MI308X (gfx942) 多卡節點的 hang 現場資料採集。
> 本 SOP 已實測成功（三顆 GPU 全卡、host 全程存活、資料齊全、HOST DEAD = 0）。
>
> **執行前必讀** [tools/umr_safety.md](../../../tools/umr_safety.md)。

## 環境佔位符

本文用佔位符描述現場資訊，實際值請依你的環境替換：

| 佔位符 | 說明 |
|--------|------|
| `<TARGET_HOST>` | 發生 hang 的目標機器 |
| `<GPU_BMC>` / `<CPU_BMC>` | GPU box / CPU box 的 BMC 位址 |
| `<DATA_DIR>` | 落盤目錄（獨立資料碟，非 root fs） |
| `<UPLOAD_HOST>` | 收檔機器 |
| `<PID>` | 目標 process PID |

## 1. 確認是不是真 hang

**鐵證判準：** `wptr ≠ rptr` 且跨多次 snapshot 凍結不動。

從安全路徑就能取得：

```bash
python3 tools/debug_scripts/02_umr_queue_doctor.py --pid <PID> --samples 3 --interval 10
```

**soft-freeze 特徵：**
- GPU util 出現 0% / 100% 混合（hung 的卡 100% spin，其餘 0%）
- QPS 掉到 0

cpc 不是確認 hang 的必要條件，不要為了拿 cpc 冒殺 host 的風險。

## 2. 三階段採集順序

順序是「安全 → 應用層 log → 致命」，確保即使致命階段 abort，前面的資料都已落盤。

### STAGE 1：安全 debugfs 採集

```bash
tools/debug_scripts/06_collect_all_gpu_debug.sh \
  --pid <PID> \
  --skip-cpc --skip-waves --skip-aql-queue
```

收集內容：queue_doctor（3 GPU × 3 snapshot + full-ring，約 13 分鐘）+ sdma registers + kfd snapshots。

`--skip-cpc/--skip-waves` **不是放棄 cpc**，而是把 cpc 移到 STAGE 3 用安全方式跑。UMR 內部的 queue_doctor / kfd / sdma / full-ring 一個都沒有 skip。

### STAGE 2：應用層 log 快照

在 STAGE 3 之前做，確保即使 cpc 階段 abort 也有 runtime log：

```bash
cp <APP_LOG_PATH> <DATA_DIR>/<BUNDLE>/
```

ROCclr log 在高 log level 下漲得很快（LEVEL=5 單份約 1.8GB vs LEVEL=4 約 1GB），跑多輪要盯著磁碟空間。

### STAGE 3：cpc / waves（背景執行）

嚴格遵守 [umr_safety.md](../../../tools/umr_safety.md) 的鐵律：hung GPU only、XCC 0-3、獨立呼叫、timeout 30、每次檢查 uptime、nohup 背景跑。

```bash
nohup bash -c '
for INST in <HUNG_GPU_INSTANCES>; do
  for XCC in 0 1 2 3; do
    timeout 30 sudo umr -i $INST -vmp $XCC --tool cpc -O no_backtrace \
      > cpc_inst${INST}_xcc${XCC}.txt 2>&1
    uptime >/dev/null || { echo "HOST DEAD ABORT"; exit 1; }
  done
done
' > collect.log 2>&1 &
```

然後輪詢 `collect.log`，不要前景等待。

## 3. 判斷 host 死活（防誤殺）

**絕不憑單次 ping / SSH 失敗就判定 host 死了。** soft-freeze 或 scandump 期間 host 網路會間歇不可達，這是正常現象。

判死三步驟：

1. 至少 5 次 ping、有間隔地重試
2. SSH 重連數次
3. 讀 host 上 `collect.log` 是否有 `HOST DEAD ABORT` 標記

scandump 進行中 host ping 不通是預期的（帶外存取），此時一律不要碰 host。

BMC power cycle 是最後手段，動之前務必先跑完上面三步。誤判而 cycle 會清掉正在跑的採集和 hang 事件本身。

## 4. 落盤規範

- 一律寫獨立資料碟 `<DATA_DIR>`，不要寫 root fs
- 不要碰其他用途的儲存裝置
- 高 log level 時注意空間，跑多輪前先確認餘量

## 5. 重開機 SOP

前置條件：已依照第 3 節確認 host 真的死了，或使用者明確下令。

1. **BMC power cycle：** GPU box `<GPU_BMC>` 先，等 30 秒，CPU box `<CPU_BMC>` 後。**順序不可反。**
2. **等開機 3-5 分鐘：** 連續多次 ping 都有回應才算好。
3. **載入 driver：**
   ```bash
   sudo modprobe amdgpu     # 開機時被 modprobe.blacklist 擋住，必做
   ls /dev/kfd              # 確認 KFD 存在
   amd-smi list             # 確認 8 顆 GPU 都在
   ```
4. **重啟 repro：** 清掉 stale 狀態（清空 monitor log、移除 HANG_DETECTED 標記）後再啟動。
5. **排程檢查：** 用輪詢讀 log 判斷進度，等下一輪 hang。

## 6. 資料上傳

- 檔案格式對齊既有 bundle 結構：queue_doctor / kfd 扁平展開、cpc_waves 放子目錄、runtime log 放 capture 目錄頂層
- 最外層額外放整包 `.tar.gz`
- 大檔（1-2GB）傳輸要帶斷點續傳 + 自動重連，單一 SSH channel 容易斷

## 相關

- [UMR 安全分級](../../../tools/umr_safety.md) — 執行前必讀
- [SDMA Fence Debug Playbook](sdma_fence_debug.md) — fence 判讀
- [KFD Queue Debug](kfd_queue_debug.md) — queue 狀態判讀

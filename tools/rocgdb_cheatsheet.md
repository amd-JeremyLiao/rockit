# rocgdb 常用命令速查

## Batch Attach（hang 現場取證，最常用）

```bash
rocgdb -batch \
  -ex 'set pagination off' \
  -ex 'info threads' \
  -ex 'thread apply all bt' \
  -ex 'info rocm-devices' \
  -ex 'info rocm-waves' \
  -p $PID
```

## 互動式 Debug

```bash
# 啟動程式
HIP_LAUNCH_BLOCKING=1 rocgdb --args ./your_program arg1 arg2

# Attach 到 running process
rocgdb -p $PID
```

## Heterogeneous 結構命令

| 命令 | 功能 |
|------|------|
| `info agents` | GPU agent 列表（arch, device name, PCI BDF） |
| `info queues` | HSA / PM4 / DMA / XGMI queue |
| `info dispatches` | kernel dispatch, work-group grid |
| `info threads` | CPU threads + AMDGPU Wave |
| `info lanes` | SIMT lane（work-item 級） |

## GPU Wave 相關

| 命令 | 功能 |
|------|------|
| `info rocm-waves` | 所有 active wavefront |
| `info rocm-devices` | GPU device 資訊 |
| `info registers reggroup general` | GPU 通用暫存器 |
| `info registers reggroup vector` | GPU vector 暫存器 |
| `set amdgpu precise-memory on` | 精確 memory fault 位置 |

## 常用 GDB 基本命令

| 命令 | 功能 |
|------|------|
| `bt` | backtrace |
| `frame N` | 切到第 N 層 stack frame |
| `thread apply all bt` | 所有 thread backtrace |
| `thread N` | 切到 thread N |
| `print var` | 印變數 |
| `break file.cpp:123` | 設 breakpoint |
| `continue` / `next` / `step` | 執行控制 |
| `detach` | 離開（不殺 process） |

## 判讀要點

- **AMDGPU Wave 數量 > 0**：compute kernel 在跑，hang 可能在 kernel 層
- **AMDGPU Wave = 0**：沒有 active compute，hang 可能在 SDMA / driver / firmware
- **Thread 卡在 `WaitRelaxed`**：ROCr signal wait，可能是 SDMA fence 沒回來
- **Thread 卡在 `hsaKmtWaitOnEvent`**：KFD wait，可能是 queue eviction / SVM issue
- **Attach 會暫停 process**（ptrace），可能改變 GPU 狀態

## 搭配 Debug Agent

```bash
HSA_ENABLE_DEBUG=1 \
HIP_LAUNCH_BLOCKING=1 \
LD_PRELOAD=/opt/rocm/lib/librocm-debug-agent.so \
rocgdb --args ./your_program
```

## AQL packet 解碼（container 內手動版）

`tools/debug_scripts/13_dump_aql_queues_gdb.sh` 的輕量替代方案，適合直接在 container
裡跑。需要 `aql_packet_decode_gdb.py`（在 `tools/debug_scripts/` 裡）。

```bash
# 1. container 內安裝 gdb（需支援 Python scripting）
# 2. 把 aql_packet_decode_gdb.py 放進 container
# 3. hang 發生後進 container 執行
/usr/bin/gdb -p $(pidof my_app) \
  -ex "source aql_packet_decode_gdb.py" \
  -batch
```

輸出檔路徑會顯示在執行提示中。

**注意：** `/opt/rocm/bin/rocgdb-py3.11` 目前 source `aql_packet_decode_gdb.py` 會 crash，
用系統 `/usr/bin/gdb` 或自建的 upstream GDB（`00_pull_build_gdb.sh`）。

搭配記憶體 dump 取得 packet 原始內容：

```bash
# 依需要指定 offset 與長度，見 manual_commands.md 的 signal 讀取段落
sudo dd if=/proc/$(pidof my_app)/mem \
  iflag=skip_bytes,count_bytes \
  skip=$((ADDR)) count=<LEN> status=none | xxd -e -g8
```

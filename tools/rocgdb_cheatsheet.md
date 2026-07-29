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

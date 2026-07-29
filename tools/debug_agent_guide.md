# ROCm Debug Agent 使用指南

## 是什麼

ROCm Debug Agent (`librocm-debug-agent.so`) 是一個被動式 HSA Tool library。
當 GPU kernel crash / fault 時，自動輸出 wavefront 狀態、暫存器、反組譯到 stderr。
**不是**互動式 debugger，不適用 silent hang（用 rocgdb 或 UMR）。

## 啟用方式

```bash
HSA_ENABLE_DEBUG=1 \
HSA_TOOLS_LIB=/opt/rocm/lib/librocm-debug-agent.so.2 \
./your_program 2>&1 | tee debug-agent.log
```

或使用 LD_PRELOAD：
```bash
HSA_ENABLE_DEBUG=1 \
LD_PRELOAD=/opt/rocm/lib/librocm-debug-agent.so \
./your_program
```

## 觸發條件

| 事件 | 說明 |
|------|------|
| Memory violation | GPU 非法記憶體存取 |
| Assert trap (`s_trap 2`) | `__builtin_trap()` 或 assert |
| Illegal instruction | 硬體偵測到非法指令 |
| SIGQUIT (`Ctrl-\`) | 手動觸發全 wave dump |

## 輸出判讀

### GPU Agent
```
* 1  A  AMDGPU Agent ... gfx942 ... 0000:0a:00.0
```
- `*`：目前選中的 GPU
- `gfx942`：GPU 架構
- `0000:0a:00.0`：PCIe BDF

### Queue
```
* 32 AMDGPU Queue 1:32 ... HSA Read 565215 Write 565232
```
- `Write > Read`：queue 尚有未消費的 packet
- `Write - Read` = pending packet 數量

### Dispatch
```
AMDGPU Dispatch 1:32:1 (PKID 565218)
Grid      [20480,1,1]
Workgroup [256,1,1]
```
- Grid / Workgroup 大小
- PKID = queue packet ID

### 常見錯誤訊息
- `Cannot get amd_mem_obj for ptr: 0x...` → pointer 已被 free 或無效
- `MEMORY_VIOLATION` → GPU page fault
- `ASSERT_TRAP` → kernel 裡觸發 assert

## 選項（透過 ROCM_DEBUG_AGENT_OPTIONS）

| 選項 | 功能 |
|------|------|
| `-a, --all` | 印出所有 wavefront |
| `-p, --precise-memory` | 精確 memory fault PC |
| `-s DIR, --save-code-objects` | 儲存 loaded code objects |
| `-o FILE, --output=FILE` | 輸出到檔案 |
| `-d, --disable-linux-signals` | 不攔截 SIGQUIT |

## 限制

- GPU hang（無 exception）時通常不會輸出 → 用 rocgdb / UMR / KFD debugfs
- 需要相容的 amdgpu driver + firmware + ROCm runtime
- 不支援 SR-IOV

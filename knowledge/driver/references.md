# Driver / GPU 參考資料索引

診斷過程中可能需要查閱的參考文件。這些文件本身不在此 repo 中，此處僅記錄位置與用途。

## 硬體規格

| 文件 | 位置 | 什麼時候需要查 |
|------|------|--------------|
| Graphics IP Register Specifications | AMD internal / 筆記本 | 需要確認特定暫存器的 bit field 定義（如 SDMA_STATUS_REG 各 bit 含義） |
| AMD IP Register Database (ADC) | [https://adcweb05.amd.com/](https://adcweb05.amd.com/) (AMD intranet) | 線上查詢各 IP block（SDMA, GFX, MMHUB 等）的完整暫存器定義、bit field、reset value |
| SDMA Microcode Spec | AMD internal | 追蹤 SDMA engine 行為、packet format |
| GFX/Compute IP Spec | AMD internal | CP/MEC/CPC 暫存器定義 |

## Driver 原始碼

| 文件 | 位置 | 什麼時候需要查 |
|------|------|--------------|
| amdgpu driver (KFD) | kernel tree / ROCK-Kernel-Driver | 追蹤 KFD queue management、eviction、fence 邏輯 |
| amdgpu driver (TTM/SDMA) | kernel tree `drivers/gpu/drm/amd/amdgpu/` | 追蹤 SDMA ring、suballocator、TTM copy 路徑 |
| ROCR runtime | ROCm/ROCR-Runtime | 追蹤 HSA signal wait、AcquireWriteAddress、queue 管理 |
| CLR (HIP runtime) | ROCm/clr | 追蹤 hipMemcpy、SyncAllStreams、hipFree 路徑 |

## 工具文件

| 文件 | 位置 | 什麼時候需要查 |
|------|------|--------------|
| UMR user guide | `/opt/rocm/share/doc/umr/` 或 [GitHub](https://github.com/ROCm/umr) | UMR 命令用法、支援的 IP block 列表 |
| ROCm Debug Agent README | `/opt/rocm/share/doc/rocm-debug-agent/README.md` | Debug Agent 選項與輸出格式 |
| ROCgdb manual | [rocm.docs.amd.com](https://rocm.docs.amd.com/projects/ROCgdb/) | rocgdb heterogeneous debug 命令 |

## 注意事項

- Graphics IP Register Spec 是 AMD confidential，不可放進公開 repo
- 查暫存器定義時，注意 IP version（如 sdma 4.4.5 vs 6.0）對應不同的 register layout
- UMR 的暫存器名稱可能與 spec 不完全一致（如 PREEMPT vs RB_PREEMPT），見 `tools/debug_scripts/03_dump_sdma_registers.sh` 中的 alias 處理
- UMR 安全分級（哪些路徑會殺 host）見 [tools/umr_safety.md](../../tools/umr_safety.md)

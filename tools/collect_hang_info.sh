#!/bin/bash
# =============================================================================
# GPU Hang Diagnostic Collector
#
# One-shot script to collect all relevant info when a GPU hang is detected.
# Works from inside a container or on bare metal.
#
# Usage:
#   ./collect_hang_info.sh <pid|name|all> [pid2 pid3 ...] [-o output_dir] [--upload [username]]
#
# Examples:
#   ./collect_hang_info.sh 12345                          # single PID
#   ./collect_hang_info.sh 12345 67890 11111              # multiple PIDs
#   ./collect_hang_info.sh python3                         # all matching by name
#   ./collect_hang_info.sh all                             # auto-detect GPU processes
#   ./collect_hang_info.sh 12345 67890 -o /tmp/diag        # custom output dir
#   ./collect_hang_info.sh 12345 --upload                  # collect + upload to S3
#   ./collect_hang_info.sh 12345 --upload myname           # upload under s3://home/myname/
# =============================================================================
set -uo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: $0 <pid|name|all> [pid2 pid3 ...] [-o output_dir]"
    exit 1
fi

OUTDIR="/tmp/hang_diag_$(date +%Y%m%d_%H%M%S)"
TARGETS=()
UPLOAD=0
UPLOAD_USER=""

while [ $# -gt 0 ]; do
    case "$1" in
        -o)       OUTDIR="$2"; shift 2 ;;
        --upload) UPLOAD=1; shift
                  if [ $# -gt 0 ] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ ^[0-9]+$ ]] && [ "$1" != "all" ]; then
                      UPLOAD_USER="$1"; shift
                  fi ;;
        *)        TARGETS+=("$1"); shift ;;
    esac
done

if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "Usage: $0 <pid|name|all> [pid2 pid3 ...] [-o output_dir] [--upload [username]]"
    exit 1
fi

APP_TARGET="${TARGETS[0]}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN:${NC} $*"; }
fail() { echo -e "${RED}[$(date +%H:%M:%S)] FAIL:${NC} $*"; }
hdr()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }

mkdir -p "$OUTDIR"
log "Output directory: $OUTDIR"

# =========================================================================
# Step 0: Find target PIDs
# =========================================================================
log "Finding target process(es)..."

PIDS=()

if [ "$APP_TARGET" = "all" ]; then
    # Auto-detect: use rocm-smi --showpids to find GPU processes,
    # then find matching container PIDs
    log "  Mode: auto-detect all GPU processes"
    ROCM_PIDS=$(rocm-smi --showpids 2>/dev/null | grep -E '^[0-9]' | awk '{print $1}')

    if [ -z "$ROCM_PIDS" ]; then
        # Fallback: check KFD
        ROCM_PIDS=$(ls /sys/class/kfd/kfd/proc/ 2>/dev/null | tr '\n' ' ')
    fi

    if [ -z "$ROCM_PIDS" ]; then
        fail "No GPU processes found"
        exit 1
    fi

    # rocm-smi shows host PIDs; try to map to container PIDs
    for hpid in $ROCM_PIDS; do
        if [ -d "/proc/$hpid" ]; then
            PIDS+=("$hpid")
        else
            # We're in a container — host PID not visible in /proc.
            # Fall back to finding high-CPU processes
            :
        fi
    done

    # If inside container, host PIDs won't be in /proc. Use CPU-based detection.
    if [ ${#PIDS[@]} -eq 0 ]; then
        log "  Host PIDs not visible (inside container). Finding by CPU usage..."
        mapfile -t PIDS < <(ps aux --sort=-%cpu 2>/dev/null | awk 'NR>1 && $3+0 > 50 {print $2}')
    fi

elif [ ${#TARGETS[@]} -gt 1 ] || [[ "$APP_TARGET" =~ ^[0-9]+$ ]]; then
    # Direct PID(s) — could be one or many: ./collect.sh 111 222 333
    for t in "${TARGETS[@]}"; do
        if [[ "$t" =~ ^[0-9]+$ ]]; then
            PIDS+=("$t")
        else
            warn "Skipping non-numeric argument: $t"
        fi
    done
else
    # Find all matching processes by name
    mapfile -t PIDS < <(pgrep -f "$APP_TARGET" 2>/dev/null | while read pid; do
        # Skip bash wrappers and self
        cmdline=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ')
        if echo "$cmdline" | grep -qv "^bash"; then
            echo "$pid"
        fi
    done)

    if [ ${#PIDS[@]} -eq 0 ]; then
        mapfile -t PIDS < <(pgrep -f "$APP_TARGET" 2>/dev/null)
    fi
fi

if [ ${#PIDS[@]} -eq 0 ]; then
    fail "Cannot find process(es) for '$APP_TARGET'"
    exit 1
fi

log "Found ${#PIDS[@]} process(es): ${PIDS[*]}"
echo "${PIDS[*]}" > "$OUTDIR/00_target_pids.txt"

# =========================================================================
# A. Environment Baseline (once)
# =========================================================================
log "=============================="
log "A. Environment Baseline"
log "=============================="

log "[A1] GPU state (rocm-smi --showall + --showtopo)..."
{
    rocm-smi --showall 2>&1
    echo ""
    rocm-smi --showtopo 2>&1
} > "$OUTDIR/A1_gpu_state.txt"
log "  -> A1_gpu_state.txt ($(wc -c < "$OUTDIR/A1_gpu_state.txt") bytes)"

log "[A2] ROCm / driver version..."
{
    echo "=== ROCm version ==="
    cat /opt/rocm/.info/version 2>/dev/null || echo 'not found'
    echo ""
    echo "=== dpkg rocm packages ==="
    dpkg -l 2>/dev/null | grep -i rocm | head -20 || echo 'N/A'
    echo ""
    echo "=== modinfo amdgpu ==="
    modinfo amdgpu 2>/dev/null | head -20 || echo "N/A (may need host access)"
} > "$OUTDIR/A2_rocm_driver.txt"
log "  -> A2_rocm_driver.txt"

log "[A3] dmesg snapshot..."
dmesg > "$OUTDIR/A3_dmesg.txt" 2>&1
log "  -> A3_dmesg.txt ($(wc -c < "$OUTDIR/A3_dmesg.txt") bytes)"

# =========================================================================
# B. GPU Utilization Snapshot (once)
# =========================================================================
log "=============================="
log "B. GPU Utilization"
log "=============================="

log "[B1] GPU utilization (CSV)..."
rocm-smi --showuse --csv 2>&1 > "$OUTDIR/B1_gpu_use.txt"
log "  -> B1_gpu_use.txt"

log "[B2] GPU clocks..."
rocm-smi --showclocks 2>&1 > "$OUTDIR/B2_gpu_clocks.txt"
log "  -> B2_gpu_clocks.txt"

log "[B3] GPU PIDs..."
rocm-smi --showpids 2>&1 > "$OUTDIR/B3_gpu_pids.txt"
log "  -> B3_gpu_pids.txt"

# =========================================================================
# C + D: Per-process collection
# =========================================================================

ROCGDB_BIN=""
if command -v rocgdb > /dev/null 2>&1; then
    ROCGDB_BIN="rocgdb"
elif command -v gdb > /dev/null 2>&1; then
    ROCGDB_BIN="gdb"
fi

for i in "${!PIDS[@]}"; do
    PID="${PIDS[$i]}"
    IDX=$((i + 1))

    log "=============================="
    hdr "Process $IDX/${#PIDS[@]}: PID $PID"
    log "=============================="

    # Get process name for logging
    PNAME=$(cat /proc/$PID/comm 2>/dev/null || echo "unknown")
    PCMD=$(cat /proc/$PID/cmdline 2>/dev/null | tr '\0' ' ' | head -c 120)
    log "  Name: $PNAME"
    log "  Cmd:  $PCMD"

    # --- C. Thread State ---
    log "[C-$IDX] /proc/$PID/status + threads..."
    {
        echo "=== PID $PID ($PNAME) ==="
        echo "=== cmdline: $PCMD ==="
        echo ""
        echo "=== /proc/$PID/status ==="
        cat "/proc/$PID/status" 2>&1
        echo ""
        echo "=== threads + wchan ==="
        if [ -d "/proc/$PID/task" ]; then
            for tid in $(ls "/proc/$PID/task/" 2>/dev/null); do
                wchan=$(cat "/proc/$PID/task/$tid/wchan" 2>/dev/null || echo "N/A")
                stat=$(cat "/proc/$PID/task/$tid/stat" 2>/dev/null | awk '{print $3}' || echo "?")
                echo "TID $tid: state=$stat wchan=$wchan"
            done
        else
            echo "(task dir not accessible)"
        fi
    } > "$OUTDIR/C_proc_${IDX}_pid${PID}.txt" 2>&1
    log "  -> C_proc_${IDX}_pid${PID}.txt"

    # --- D. rocgdb ---
    if [ -n "$ROCGDB_BIN" ]; then
        log "[D-$IDX] $ROCGDB_BIN batch attach (PID=$PID)..."
        warn "  NOTE: rocgdb attach may affect GPU state."
        {
            $ROCGDB_BIN -batch \
                -ex 'set pagination off' \
                -ex 'info threads' \
                -ex 'thread apply all bt' \
                -ex 'info rocm-devices' \
                -ex 'info rocm-waves' \
                -p "$PID" 2>&1
        } > "$OUTDIR/D_rocgdb_${IDX}_pid${PID}.txt" 2>&1
        log "  -> D_rocgdb_${IDX}_pid${PID}.txt ($(wc -c < "$OUTDIR/D_rocgdb_${IDX}_pid${PID}.txt") bytes)"
    else
        warn "[D-$IDX] No rocgdb or gdb found — skipping"
        echo "rocgdb/gdb not available" > "$OUTDIR/D_rocgdb_${IDX}_pid${PID}.txt"
    fi

done

# =========================================================================
# E. KFD Queue State
# =========================================================================
log "=============================="
log "E. KFD Queue State"
log "=============================="

collect_kfd_for_pid() {
    local pid=$1
    echo "=== KFD proc dir (PID=$pid) ==="
    ls -la "/sys/class/kfd/kfd/proc/$pid/" 2>&1

    echo ""
    echo "=== queues ==="
    for q in "/sys/class/kfd/kfd/proc/$pid/queues/"*/; do
        [ -d "$q" ] || continue
        qname=$(basename "$q")
        echo "--- queue $qname ---"
        for f in "$q"*; do
            [ -f "$f" ] && echo "  $(basename "$f"): $(cat "$f" 2>&1)"
        done
    done

    echo ""
    echo "=== SDMA usage ==="
    for f in "/sys/class/kfd/kfd/proc/$pid/sdma_"*; do
        [ -f "$f" ] && echo "$(basename "$f"): $(cat "$f" 2>&1)"
    done

    echo ""
    echo "=== VRAM usage ==="
    for f in "/sys/class/kfd/kfd/proc/$pid/vram_"*; do
        [ -f "$f" ] && echo "$(basename "$f"): $(cat "$f" 2>&1)"
    done

    echo ""
    echo "=== PASID ==="
    cat "/sys/class/kfd/kfd/proc/$pid/pasid" 2>&1
}

KFD_PIDS=$(ls /sys/class/kfd/kfd/proc/ 2>/dev/null)
KFD_COUNT=$(echo "$KFD_PIDS" | wc -w)

if [ "$KFD_COUNT" -gt 0 ]; then
    log "[E1] KFD queues for $KFD_COUNT GPU process(es)..."
    {
        for kpid in $KFD_PIDS; do
            [ -d "/sys/class/kfd/kfd/proc/$kpid" ] || continue
            echo "========================================="
            echo "=== KFD PID $kpid ==="
            echo "========================================="
            collect_kfd_for_pid "$kpid"
            echo ""
        done
    } > "$OUTDIR/E1_kfd_queues.txt" 2>&1
    log "  -> E1_kfd_queues.txt"
else
    warn "[E1] No KFD proc entries found — skipping"
    echo "KFD proc dir empty or not accessible" > "$OUTDIR/E1_kfd_queues.txt"
fi

# =========================================================================
# E2. KFD Dynamic Debug — SVM restore failures (ref: Alibaba soft-hang doc)
# The Alibaba investigation found KFD SVM restore failures caused queue
# unmapping from GPU CP. This captures the current state.
# =========================================================================
log "=============================="
log "E2. KFD SVM / Eviction Debug"
log "=============================="

{
    echo "=== HSA_USE_SVM environment ==="
    for PID in "${PIDS[@]}"; do
        svm_val=$(cat /proc/$PID/environ 2>/dev/null | tr '\0' '\n' | grep HSA_USE_SVM || echo "not set")
        echo "PID $PID: HSA_USE_SVM=$svm_val"
    done

    echo ""
    echo "=== amdgpu debug_evictions status ==="
    cat /sys/module/amdgpu/parameters/debug_evictions 2>&1 || echo "N/A"

    echo ""
    echo "=== KFD svm_range_restore_work dynamic debug status ==="
    grep svm_range_restore_work /sys/kernel/debug/dynamic_debug/control 2>&1 || echo "N/A (no debugfs access)"

    echo ""
    echo "=== KFD eviction-related dmesg (last 200 lines) ==="
    dmesg 2>/dev/null | grep -i 'evict\|restore\|svm\|unmap.*queue\|map.*queue' | tail -200

    echo ""
    echo "=== /sys/kernel/debug/kfd/ topology ==="
    ls /sys/kernel/debug/kfd/ 2>&1 || echo "N/A"
    for f in /sys/kernel/debug/kfd/hqds /sys/kernel/debug/kfd/rls /sys/kernel/debug/kfd/mqds; do
        if [ -f "$f" ]; then
            echo ""
            echo "=== $(basename $f) ==="
            cat "$f" 2>&1 | head -200
        fi
    done

} > "$OUTDIR/E2_kfd_svm_debug.txt" 2>&1
log "  -> E2_kfd_svm_debug.txt"

# =========================================================================
# E3. UMR — GPU Command Processor status (ref: Alibaba soft-hang doc)
# If umr is available, dump CP/CPC status. The Alibaba case found
# CP completely idle + VMID=0 = queue unmapped from hardware.
# =========================================================================
log "=============================="
log "E3. UMR CP Status"
log "=============================="

UMR_BIN=""
if command -v umr > /dev/null 2>&1; then
    UMR_BIN="umr"
elif [ -x /opt/rocm/bin/umr ]; then
    UMR_BIN="/opt/rocm/bin/umr"
elif [ -x /tmp/static_umr_mi308x/umr ]; then
    UMR_BIN="/tmp/static_umr_mi308x/umr"
fi

if [ -n "$UMR_BIN" ]; then
    log "[E3] UMR CP register dump..."
    {
        echo "=== UMR binary: $UMR_BIN ==="
        echo ""

        echo "=== CPC status (Command Processor - Compute) ==="
        $UMR_BIN -O bits,named -r cpc 2>&1 | head -100
        echo ""

        echo "=== MEC queue status ==="
        $UMR_BIN -O bits,named -r grbm 2>&1 | head -50
        echo ""

        echo "=== CP busy/idle status ==="
        $UMR_BIN --read gfx1200.grbm.GRBM_STATUS 2>&1 || \
        $UMR_BIN --read gfx942.grbm.GRBM_STATUS 2>&1 || \
        echo "Could not read GRBM_STATUS"
        echo ""

        echo "=== SDMA status ==="
        $UMR_BIN -O bits,named -r sdma0 2>&1 | head -50

    } > "$OUTDIR/E3_umr_cp_status.txt" 2>&1
    log "  -> E3_umr_cp_status.txt"
else
    warn "[E3] UMR not found — skipping (install static_umr for deeper CP debugging)"
    echo "UMR not available. For deeper debug, get static UMR from:" > "$OUTDIR/E3_umr_cp_status.txt"
    echo "https://github.com/Yuechguo/debug_tools/tree/main/static_umr_mi308x" >> "$OUTDIR/E3_umr_cp_status.txt"
fi

# =========================================================================
# F. dmesg diff (new errors since baseline)
# =========================================================================
log "=============================="
log "F. dmesg (hang time)"
log "=============================="

log "[F1] dmesg at hang time..."
dmesg > "$OUTDIR/F1_dmesg_hang.txt" 2>&1
log "  -> F1_dmesg_hang.txt"

log "[F2] GPU-related dmesg entries..."
grep -iP '\bamdgpu\b|\bkfd\b|\bgpu[ _]?fault\b|\bgpu[ _]?error\b|\bgpu[ _]?reset\b|\bxgmi\b|\bras[: ].*err|\bsquhang\b|\bhang\b.*gpu|\bgpu.*\bhang\b' "$OUTDIR/F1_dmesg_hang.txt" > "$OUTDIR/F2_dmesg_gpu_errors.txt" 2>&1
NERR=$(wc -l < "$OUTDIR/F2_dmesg_gpu_errors.txt")
log "  -> F2_dmesg_gpu_errors.txt ($NERR lines)"

# =========================================================================
# G. Post-rocgdb Check (did app resume?)
# =========================================================================
log "=============================="
log "G. Post-Collection Check"
log "=============================="

sleep 2
{
    for PID in "${PIDS[@]}"; do
        alive=$(kill -0 "$PID" 2>/dev/null && echo YES || echo NO)
        echo "PID $PID alive: $alive"
    done
    echo ""
    echo "=== GPU utilization ==="
    rocm-smi --showuse --csv 2>&1 | grep card
} > "$OUTDIR/G1_post_check.txt"
cat "$OUTDIR/G1_post_check.txt" | while read -r line; do log "  $line"; done

# =========================================================================
# Summary
# =========================================================================
echo ""
log "=============================="
log "COLLECTION COMPLETE"
log "=============================="
log "Output: $OUTDIR"
echo ""
ls -lhS "$OUTDIR/"
echo ""

TOTAL_SIZE=$(du -sh "$OUTDIR" | awk '{print $1}')
FILE_COUNT=$(ls "$OUTDIR" | wc -l)
log "Total: $FILE_COUNT files, $TOTAL_SIZE"
log ""
log "Quick check:"

# Per-process rocgdb summary
for f in "$OUTDIR"/D_rocgdb_*.txt; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    WAVE_COUNT=$(grep -c "AMDGPU Wave" "$f" 2>/dev/null || echo 0)
    if [ "$WAVE_COUNT" -gt 0 ]; then
        log "  [$fname] GPU Waves: $WAVE_COUNT"
        grep "AMDGPU Wave" "$f" | head -3 | while read -r line; do
            log "    $line"
        done
    else
        warn "  [$fname] No GPU waves — hang may be at driver/firmware/SDMA level"
    fi

    MAIN_FRAME=$(grep -A1 "Thread 1 " "$f" | grep "#0" | head -1)
    if [ -n "$MAIN_FRAME" ]; then
        log "  [$fname] Main thread: $MAIN_FRAME"
    fi
done

GPU_100=$(grep "100" "$OUTDIR/B1_gpu_use.txt" 2>/dev/null | head -3)
if [ -n "$GPU_100" ]; then
    log "  GPUs at 100%:"
    echo "$GPU_100" | while read -r line; do log "    $line"; done
fi

if [ "$NERR" -gt 0 ]; then
    warn "  GPU-related dmesg errors: $NERR lines (check F2_dmesg_gpu_errors.txt)"
else
    log "  No GPU errors in dmesg"
fi

# Alibaba soft-hang pattern check: SVM restore failures
SVM_RESTORE=$(grep -c "restore failed\|restore_work.*fail\|failed to restore" "$OUTDIR/E2_kfd_svm_debug.txt" 2>/dev/null || echo 0)
if [ "$SVM_RESTORE" -gt 0 ]; then
    warn "  KFD SVM restore failures: $SVM_RESTORE (Alibaba soft-hang pattern!)"
    warn "  Try: HSA_USE_SVM=0 to verify if this is the cause"
fi

# CP idle check
if [ -f "$OUTDIR/E3_umr_cp_status.txt" ]; then
    CP_IDLE=$(grep -ci "idle\|CP_BUSY.*0" "$OUTDIR/E3_umr_cp_status.txt" 2>/dev/null || echo 0)
    if [ "$CP_IDLE" -gt 0 ]; then
        warn "  GPU CP appears idle (queue may be unmapped from hardware)"
    fi
fi

# Eviction related
EVICT_COUNT=$(grep -c "evict" "$OUTDIR/E2_kfd_svm_debug.txt" 2>/dev/null || echo 0)
if [ "$EVICT_COUNT" -gt 0 ]; then
    log "  KFD eviction events: $EVICT_COUNT (check E2_kfd_svm_debug.txt)"
fi

log ""

# =========================================================================
# H. Upload (optional)
# =========================================================================
if [ "$UPLOAD" -eq 1 ]; then
    log "=============================="
    log "H. Upload to S3"
    log "=============================="

    TARBALL="/tmp/$(basename "$OUTDIR").tar.gz"
    log "Packing $TARBALL ..."
    tar czf "$TARBALL" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")"
    log "  -> $(du -h "$TARBALL" | awk '{print $1}')"

    # S3 endpoint — set S3_ENDPOINT env var or configure DNS before using --upload
    S3_ENDPOINT="${S3_ENDPOINT:-https://amd-afde.top}"

    # Ensure awscli is available
    if ! command -v aws > /dev/null 2>&1; then
        log "Installing awscli..."
        pip install --user awscli 2>&1 | tail -1
        export PATH="$HOME/.local/bin:$PATH"
    fi

    export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:?Set AWS_ACCESS_KEY_ID before using --upload}"
    export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:?Set AWS_SECRET_ACCESS_KEY before using --upload}"
    FNAME=$(basename "$TARBALL")
    HOSTNAME_TAG=$(hostname | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')
    DATE_TAG=$(date +%Y%m%d)

    if [ -z "$UPLOAD_USER" ]; then
        UPLOAD_USER=$(whoami)
    fi

    USER_S3_PATH="${UPLOAD_USER}/hang_diag/${HOSTNAME_TAG}/${DATE_TAG}/${FNAME}"
    log "Uploading to s3://home/$USER_S3_PATH ..."
    if aws s3 cp "$TARBALL" "s3://home/$USER_S3_PATH" --endpoint-url "$S3_ENDPOINT" 2>&1; then
        log "  Uploaded: s3://home/$USER_S3_PATH"
    else
        fail "  Upload to s3://home/ failed"
    fi

    log "Upload done."
else
    log "To share: tar czf hang_diag.tar.gz -C $(dirname "$OUTDIR") $(basename "$OUTDIR")"
    log "To upload: re-run with --upload [username]"
fi

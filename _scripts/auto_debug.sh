#!/bin/bash
# ============================================================
# auto_debug.sh - ARM64 Fully Automated Debug Script
#
# Usage:
#   ./auto_debug.sh <device> [obscura args]
#
# Examples:
#   ./auto_debug.sh 30.207.82.136:61385
#   ./auto_debug.sh 30.207.82.136:61385 "fetch https://www.baidu.com --dump text"
#   ./auto_debug.sh 30.207.82.136:61385 "fetch https://example.com --dump html --output page.html"
#
# Features:
#   - Fully automated, no manual intervention required
#   - Uses debug version only
#   - Auto build, deploy, debug, and analysis
#   - Generates complete analysis report
# ============================================================

set -e

# Resolve project root directory (realpath handles symlinks cross-platform) and cd to it
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"
cd "$OBSCURA_DIR"

# ===================== Configuration =====================
DEVICE="${1:?Please provide device address, e.g. 30.207.82.136:61385}"
shift
TARGET_DIR="./target/aarch64"
OBSCURA_ARGS=""
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ADB="/mnt/d/.sdk/tools/adb/linux/adb"

# Match V8 directory precisely (v8-X.Y.Z format, e.g. v8-137.3.0, not v8-137.3.0.bak or v8-137.3.0_xx)
V8_SRC_DIR=$(ls -td "${OBSCURA_DIR}"/third_party/v8-* 2>/dev/null | grep -E '/v8-[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
if [[ -z "$V8_SRC_DIR" ]]; then
    echo "Error: V8 source directory not found (third_party/v8-*)"
    exit 1
fi
SYSROOT="${V8_SRC_DIR}/build/linux/debian_bullseye_arm64-sysroot"

# Argument parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-dir)
            TARGET_DIR="$2"
            shift 2
            ;;
        --target-dir=*)
            TARGET_DIR="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 <device> [options] [obscura args]"
            echo ""
            echo "Options:"
            echo "  --target-dir DIR    Specify build output directory (default: ./target/aarch64)"
            echo "  -h, --help          Show help"
            echo ""
            echo "Examples:"
            echo "  $0 30.207.82.136:61385"
            echo "  $0 30.207.82.136:61385 --target-dir ./target2"
            echo "  $0 30.207.82.136:61385 \"fetch https://www.baidu.com --dump text\""
            echo "  $0 30.207.82.136:61385 --target-dir ./target2 \"fetch https://example.com\""
            exit 0
            ;;
        *)
            # First non-option argument as obscura args
            if [[ -z "$OBSCURA_ARGS" ]]; then
                OBSCURA_ARGS="$1"
            fi
            shift
            ;;
    esac
done

# Set defaults
OBSCURA_ARGS="${OBSCURA_ARGS:-fetch https://www.baidu.com --dump text}"
LOG_DIR="${TARGET_DIR}/debug_logs"

mkdir -p "$LOG_DIR"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ===================== Cleanup Function =====================
cleanup() {
    log_info "Cleaning up resources..."
    # Kill potentially leftover gdbserver
    "$ADB" -host -s "$DEVICE" shell "pkill -f gdbserver 2>/dev/null" || true
    # Clean up temp files
    rm -f /tmp/gdb_auto_${TIMESTAMP}.gdb
}

trap cleanup EXIT

# ===================== Main Flow =====================
echo "========================================"
echo " ARM64 Fully Automated Debug"
echo " Device:  $DEVICE"
echo " Args:    $OBSCURA_ARGS"
echo " Time:    $(date '+%Y-%m-%d %H:%M:%S')"
echo " Version: debug"
echo "========================================"
echo ""

# 1. Clean and build
#log_info "[1/6] Clean and build debug version..."
#./_scripts/build.sh --debug clean > "$LOG_DIR/clean_${TIMESTAMP}.log" 2>&1
#if [[ $? -ne 0 ]]; then
#    log_error "Clean failed"
#    exit 1
#fi

log_info "[1/6] Building debug version..."
./_scripts/build.sh --debug --target-dir "$TARGET_DIR" > "$LOG_DIR/build_${TIMESTAMP}.log" 2>&1 &
BUILD_PID=$!

# Monitor build progress
while kill -0 $BUILD_PID 2>/dev/null; do
    sleep 30
    if [[ -f build.log ]]; then
        LAST_LINE=$(tail -1 build.log)
        echo "  Building... $(date '+%H:%M:%S') - $LAST_LINE"
    fi
done

wait $BUILD_PID
BUILD_EXIT=$?

if [[ $BUILD_EXIT -ne 0 ]]; then
    log_error "Build failed, check log: $LOG_DIR/build_${TIMESTAMP}.log"
    tail -20 build.log
    exit 1
fi

# Verify build artifacts
BINARY="${TARGET_DIR}/aarch64-unknown-linux-gnu/debug/obscura"
WORKER_BINARY="${TARGET_DIR}/aarch64-unknown-linux-gnu/debug/obscura-worker"

if [[ ! -f "$BINARY" ]]; then
    log_error "Build artifact not found: $BINARY"
    exit 1
fi

BINARY_SIZE=$(stat -c%s "$BINARY" 2>/dev/null || stat -f%z "$BINARY" 2>/dev/null)
log_info "✓ obscura built (size: $((BINARY_SIZE / 1024 / 1024))M)"

# Check obscura-worker (optional but recommended)
if [[ -f "$WORKER_BINARY" ]]; then
    WORKER_SIZE=$(stat -c%s "$WORKER_BINARY" 2>/dev/null || stat -f%z "$WORKER_BINARY" 2>/dev/null)
    log_info "✓ obscura-worker built (size: $((WORKER_SIZE / 1024 / 1024))M)"
else
    log_warn "obscura-worker not built, parallel scrape will be unavailable"
fi

# 2. Connect device
log_info "[2/6] Connecting device..."
"$ADB" -host connect "$DEVICE" > /dev/null 2>&1
sleep 2

# Verify connection
for i in {1..3}; do
    STATE=$("$ADB" -host -s "$DEVICE" get-state 2>&1)
    if [[ "$STATE" == *"device"* ]]; then
        break
    elif [[ "$STATE" == *"unauthorized"* ]]; then
        log_warn "Device unauthorized, retrying connection ($i/3)..."
        "$ADB" kill-server
        sleep 2
        "$ADB" -host connect "$DEVICE" > /dev/null 2>&1
        sleep 3
    else
        log_error "Device connection failed: $STATE"
        exit 1
    fi
done

STATE=$("$ADB" -host -s "$DEVICE" get-state 2>&1)
if [[ "$STATE" != *"device"* ]]; then
    log_error "Device connection failed, please click 'Allow USB debugging' on the car device"
    exit 1
fi
log_info "✓ Device connected"

# 3. Clean old processes
log_info "[3/6] Cleaning old processes..."
"$ADB" -host -s "$DEVICE" shell "pkill -f gdbserver 2>/dev/null; pkill -f obscura 2>/dev/null" > /dev/null 2>&1
sleep 2
log_info "✓ Old processes cleaned"

# 4. Start gdbserver
log_info "[4/6] Starting gdbserver..."
./_scripts/debug.sh "$DEVICE" --debug --target-dir "$TARGET_DIR" --gdbserver-only $OBSCURA_ARGS > "$LOG_DIR/debug_${TIMESTAMP}.log" 2>&1
sleep 3

# Verify gdbserver
LATEST_GDBSERVER_LOG=$(ls -t ${TARGET_DIR}/debug_logs/gdbserver_*.log 2>/dev/null | head -1)
if [[ -z "$LATEST_GDBSERVER_LOG" ]] || ! grep -q "Listening" "$LATEST_GDBSERVER_LOG"; then
    log_error "gdbserver failed to start"
    if [[ -n "$LATEST_GDBSERVER_LOG" ]]; then
        cat "$LATEST_GDBSERVER_LOG"
    fi
    exit 1
fi
log_info "✓ gdbserver started (port 12345)"

# 5. GDB automated analysis
log_info "[5/6] Running GDB automated analysis..."
GDB_LOG="$LOG_DIR/gdb_auto_${TIMESTAMP}.log"

# Create GDB script
cat > /tmp/gdb_auto_${TIMESTAMP}.gdb << 'GDBEOF'
set pagination off
set height 0
set width 0
set confirm off
set solib-search-path ./
GDBEOF
echo "set sysroot ${SYSROOT}" >> /tmp/gdb_auto_${TIMESTAMP}.gdb
cat >> /tmp/gdb_auto_${TIMESTAMP}.gdb << 'GDBEOF'
target remote localhost:12345
echo \n=== [AUTO] Starting execution ===\n
continue
echo \n=== [AUTO] Program stopped ===\n
echo \n=== [AUTO] Stop reason ===\n
info program
echo \n=== [AUTO] Register state ===\n
info registers
echo \n=== [AUTO] Call stack (30 frames) ===\n
bt 30
echo \n=== [AUTO] Thread list ===\n
info threads
echo \n=== [AUTO] All thread backtraces ===\n
thread apply all bt 10
echo \n=== [AUTO] Analysis complete ===\n
quit
GDBEOF

# Run GDB (with timeout)
timeout 30 gdb-multiarch -q -x /tmp/gdb_auto_${TIMESTAMP}.gdb \
  "$BINARY" 2>&1 | tee "$GDB_LOG"

GDB_EXIT=$?
if [[ $GDB_EXIT -eq 124 ]]; then
    log_warn "GDB timed out (30s)"
elif [[ $GDB_EXIT -ne 0 ]]; then
    log_warn "GDB exit code: $GDB_EXIT"
fi
log_info "✓ GDB analysis complete"

# 6. Generate report
log_info "[6/6] Generating analysis report..."
REPORT="$LOG_DIR/ANALYSIS_REPORT_${TIMESTAMP}.md"

cat > "$REPORT" << EOF
# ARM64 Automated Debug Analysis Report

**Generated**: $(date '+%Y-%m-%d %H:%M:%S')
**Device**: $DEVICE
**Binary**: debug version ($((BINARY_SIZE / 1024 / 1024))M)
**Args**: $OBSCURA_ARGS
**GDB Log**: gdb_auto_${TIMESTAMP}.log

## Executive Summary

EOF

# Analyze crash type
if grep -q "received signal" "$GDB_LOG"; then
    SIGNAL=$(grep "received signal" "$GDB_LOG" | head -1 | sed 's/.*received signal /Signal: /')
    echo "**Status**: ❌ Program crashed" >> "$REPORT"
    echo "**$SIGNAL**" >> "$REPORT"
elif grep -q "exited normally" "$GDB_LOG"; then
    echo "**Status**: ✅ Program exited normally" >> "$REPORT"
else
    echo "**Status**: ⚠️ Unknown state" >> "$REPORT"
fi

cat >> "$REPORT" << EOF

## Crash Details

### Signal and Stop Reason
\`\`\`
$(grep -A 3 "=== \[AUTO\] Stop reason ===" "$GDB_LOG" | head -5 || echo "No info")
\`\`\`

### Call Stack
\`\`\`
$(grep -A 35 "=== \[AUTO\] Call stack" "$GDB_LOG" | head -35 || echo "No call stack")
\`\`\`

### Register State
\`\`\`
$(grep -A 35 "=== \[AUTO\] Register state ===" "$GDB_LOG" | head -35 || echo "No register info")
\`\`\`

### Thread Info
\`\`\`
$(grep -A 15 "=== \[AUTO\] Thread list ===" "$GDB_LOG" | head -15 || echo "No thread info")
\`\`\`

## Automated Analysis

### Suspicious Patterns
EOF

# Detect suspicious patterns
if grep -q "0x8080808080808080" "$GDB_LOG"; then
    echo "- ⚠️ Uninitialized memory pattern detected (0x8080808080808080)" >> "$REPORT"
fi
if grep -q "0xdeadbeef" "$GDB_LOG"; then
    echo "- ⚠️ Use-after-free pattern detected (0xdeadbeef)" >> "$REPORT"
fi
if grep -q "v8::internal" "$GDB_LOG"; then
    echo "- 🔍 V8 engine related crash" >> "$REPORT"
    if grep -q "Snapshot\|Deserialize" "$GDB_LOG"; then
        echo "- 📸 Snapshot deserialization issue" >> "$REPORT"
    fi
fi

# Statistics
if [[ $(grep -c "detected" "$REPORT" 2>/dev/null || echo 0) -eq 0 ]]; then
    echo "- ✓ No obvious suspicious patterns detected" >> "$REPORT"
fi

cat >> "$REPORT" << EOF

### Root Cause Hypothesis
EOF

if grep -q "0x8080808080808080" "$GDB_LOG"; then
    cat >> "$REPORT" << 'EOF'
1. **Uninitialized Memory Access**
   - Read uninitialized pointer or object
   - Possibly a V8 snapshot configuration issue
   - Check `v8_enable_snapshot` configuration

EOF
elif grep -q "v8::internal::Snapshot\|Deserialize" "$GDB_LOG"; then
    cat >> "$REPORT" << 'EOF'
1. **V8 Snapshot Deserialization Failed**
   - Snapshot data corrupted or incompatible
   - Check V8 build configuration
   - Consider regenerating snapshot

EOF
else
    cat >> "$REPORT" << 'EOF'
1. Further manual analysis required
2. Review full GDB log
3. Consider interactive debugging

EOF
fi

cat >> "$REPORT" << EOF

## Related Files

- **GDB Log**: \`$LOG_DIR/gdb_auto_${TIMESTAMP}.log\`
- **Debug Session**: \`$LOG_DIR/debug_${TIMESTAMP}.log\`
- **GDBServer**: \`$LATEST_GDBSERVER_LOG\`
- **Build Log**: \`$LOG_DIR/build_${TIMESTAMP}.log\`

## Next Steps

- [ ] Review this report
- [ ] Confirm root cause
- [ ] Implement fix
- [ ] Retest

## Interactive Debugging

For further debugging:

\`\`\`bash
# Start interactive GDB
tmux new-session -s debug "gdb-multiarch -q ${TARGET_DIR}/aarch64-unknown-linux-gnu/debug/obscura"

# Connect in GDB
(gdb) target remote localhost:12345
(gdb) continue
\`\`\`

---
**Report auto-generated by arm64-auto-debug skill**
**Generated**: $(date '+%Y-%m-%d %H:%M:%S')
EOF

log_info "✓ Report generated: $REPORT"

# Done
echo ""
echo "========================================"
echo " ✓ Automated debug complete"
echo "========================================"
echo ""
echo "Log directory: $LOG_DIR"
echo "Analysis report: $REPORT"
echo "GDB log: $GDB_LOG"
echo ""
echo "View report:"
echo "  cat $REPORT"
echo ""
echo "View GDB output:"
echo "  cat $GDB_LOG"

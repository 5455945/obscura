#!/bin/bash
# ============================================================
# debug.sh - Remote debug obscura (WSL ↔ car device)
#
# Usage:
#   ./debug.sh <device>                    # Default: push + gdbserver + gdb-multiarch
#   ./debug.sh <device> --gdbserver-only   # Only start gdbserver, don't connect gdb
#   ./debug.sh <device> --push-only        # Only push binaries
#   ./debug.sh <device> --on-device-gdb    # Use gdb on the car device
#   ./debug.sh <device> --no-push          # Skip push (already pushed)
#
# Examples:
#   ./debug.sh 30.207.92.65:61104
#   ./debug.sh 30.207.92.65:61104 --on-device-gdb
#   ./debug.sh 30.207.92.65:61104 --gdbserver-only --no-push
#   ./debug.sh 30.207.92.65:61104 --gdbserver-only --no-push fetch https://www.baidu.com --dump text --output page.txt
# ============================================================

set -e

# Resolve project root directory (realpath handles symlinks cross-platform) and cd to it
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"
cd "$OBSCURA_DIR"

# ===================== Configuration =====================
ADB="/mnt/d/.sdk/tools/adb/linux/adb"
BUILD_TYPE="release"     # release | debug
TARGET_DIR="./target/aarch64"
OBSURA_REMOTE="/data/obscura"
GDBSERVER_REMOTE=`which gdbserver`
echo =========== $GDBSERVER_REMOTE ===========
GDBSERVER_PORT=12345
GDB_FORWARD_PORT=12345

# Set local binary paths based on BUILD_TYPE and TARGET_DIR
update_binary_path() {
    if [[ "$BUILD_TYPE" == "debug" ]]; then
        OBSURA_LOCAL="${TARGET_DIR}/aarch64-unknown-linux-gnu/debug/obscura"
        OBSURA_WORKER_LOCAL="${TARGET_DIR}/aarch64-unknown-linux-gnu/debug/obscura-worker"
    else
        OBSURA_LOCAL="${TARGET_DIR}/aarch64-unknown-linux-gnu/release/obscura"
        OBSURA_WORKER_LOCAL="${TARGET_DIR}/aarch64-unknown-linux-gnu/release/obscura-worker"
    fi
}
update_binary_path

# ===================== Log Initialization =====================
LOG_DIR="${TARGET_DIR}/debug_logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
LOG_FILE="${LOG_DIR}/debug_${TIMESTAMP}.log"

# Print to log before each command (with timestamp prefix)
exec 4>>"$LOG_FILE"
export BASH_XTRACEFD=4
set -x

log() {
    set +x
    local msg="[$(date "+%H:%M:%S")] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
    set -x
}

# Run command, output displayed and recorded to log
run() {
    log ">>> $*"
    set +x
    "$@" 2>&1 | tee -a "$LOG_FILE"
    local exit_code=${PIPESTATUS[0]}
    set -x
    return $exit_code
}

# ===================== Argument Parsing =====================
DEVICE=""
MODE="full"          # full | gdbserver-only | push-only | on-device-gdb
NO_PUSH=0
DEBUG_ARGS=""        # Arguments passed to obscura

usage() {
    echo "Usage: $0 <device> [options] [-- obscura args...]"
    echo ""
    echo "Options:"
    echo "  --debug            Use debug version (default: release)"
    echo "  --target-dir DIR   Specify build output directory (default: ./target/aarch64)"
    echo "  --gdbserver-only   Only start gdbserver, don't connect local gdb"
    echo "  --push-only        Only push binaries to car device"
    echo "  --on-device-gdb    Use gdb on the car device for debugging"
    echo "  --no-push          Skip push (use existing binaries on device)"
    echo "  --port PORT        gdbserver port (default: ${GDBSERVER_PORT})"
    echo ""
    echo "Examples:"
    echo "  $0 30.207.92.65:61104 --debug"
    echo "  $0 30.207.92.65:61104 --debug --target-dir ./target2"
    echo "  $0 30.207.92.65:61104 --debug --gdbserver-only fetch https://www.baidu.com"
    echo "  $0 30.207.92.65:61104 --on-device-gdb"
    echo "  $0 30.207.92.65:61104 -- fetch https://www.baidu.com --dump text"
    exit 0
}

[[ $# -lt 1 ]] && usage

DEVICE="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)          BUILD_TYPE="debug"; update_binary_path; shift ;;
        --target-dir)     TARGET_DIR="$2"; update_binary_path; LOG_DIR="${TARGET_DIR}/debug_logs"; mkdir -p "$LOG_DIR"; shift 2 ;;
        --target-dir=*)   TARGET_DIR="${1#*=}"; update_binary_path; LOG_DIR="${TARGET_DIR}/debug_logs"; mkdir -p "$LOG_DIR"; shift ;;
        --gdbserver-only) MODE="gdbserver-only"; shift ;;
        --push-only)      MODE="push-only"; shift ;;
        --on-device-gdb)  MODE="on-device-gdb"; shift ;;
        --no-push)        NO_PUSH=1; shift ;;
        --port)           GDBSERVER_PORT="$2"; GDB_FORWARD_PORT="$2"; shift 2 ;;
        --port=*)         GDBSERVER_PORT="${1#*=}"; GDB_FORWARD_PORT="${1#*=}"; shift ;;
        --)               shift; DEBUG_ARGS="$*"; break ;;
        -h|--help)        usage ;;
        *)                DEBUG_ARGS="$*"; break ;;
    esac
done

# ===================== Pre-checks =====================
if [[ ! -f "$ADB" ]]; then
    echo "Error: adb not found: $ADB"
    exit 1
fi

if [[ "$NO_PUSH" -eq 0 ]]; then
    if [[ ! -f "$OBSURA_LOCAL" ]]; then
        echo "Error: obscura binary not found: $OBSURA_LOCAL"
        if [[ "$BUILD_TYPE" == "debug" ]]; then
            echo "Please build first: ./_scripts/build.sh --debug"
        else
            echo "Please build first: ./_scripts/build.sh --release"
        fi
        exit 1
    fi
    if [[ ! -f "$OBSURA_WORKER_LOCAL" ]]; then
        echo "Warning: obscura-worker binary not found: $OBSURA_WORKER_LOCAL"
        echo "Parallel scrape will be unavailable, recommend rebuilding"
    fi
fi

echo "========================================"
echo " obscura Remote Debug"
echo " Device:  $DEVICE"
echo " Version: $BUILD_TYPE"
echo " Mode:    $MODE"
echo " Log:     $LOG_FILE"
echo "========================================"
echo ""

# ===================== ADB Connection =====================
log "=== Connecting device ==="
run "$ADB" -host connect "$DEVICE"
sleep 1

# Verify connection
if ! "$ADB" -host -s "$DEVICE" get-state 2>&1 | tee -a "$LOG_FILE" | grep -q "device"; then
    log "Error: Device connection failed"
    exit 1
fi
log "Device connected"
echo ""

# ===================== Push Binaries =====================
if [[ "$NO_PUSH" -eq 0 ]]; then
    log "=== Pushing binaries ==="
    # Push obscura main program
    run "$ADB" -host -s "$DEVICE" push "$OBSURA_LOCAL" "$OBSURA_REMOTE"
    run "$ADB" -host -s "$DEVICE" shell chmod +x "$OBSURA_REMOTE"
    log "obscura pushed: $OBSURA_REMOTE"

    # Push obscura-worker (if exists)
    if [[ -f "$OBSURA_WORKER_LOCAL" ]]; then
        OBSURA_WORKER_REMOTE="/data/obscura-worker"
        run "$ADB" -host -s "$DEVICE" push "$OBSURA_WORKER_LOCAL" "$OBSURA_WORKER_REMOTE"
        run "$ADB" -host -s "$DEVICE" shell chmod +x "$OBSURA_WORKER_REMOTE"
        log "obscura-worker pushed: $OBSURA_WORKER_REMOTE"
    else
        log "Skipping obscura-worker (file not found)"
    fi
else
    log "Skipping push (--no-push)"
fi
echo ""

if [[ "$MODE" == "push-only" ]]; then
    log "push-only mode, done"
    exit 0
fi

# ===================== Check gdbserver =====================
log "=== Checking gdbserver ==="

# Detect gdbserver path on car device
set +x
CAR_GDBSERVER=$("$ADB" -host -s "$DEVICE" shell "which gdbserver 2>/dev/null" | tr -d '\r')
set -x

if [[ -n "$CAR_GDBSERVER" ]]; then
    GDBSERVER_REMOTE="$CAR_GDBSERVER"
    log "Device gdbserver: $GDBSERVER_REMOTE"
else
    log "No gdbserver on device, trying to push..."
    # Find local gdbserver
    GDBSERVER_LOCAL=""
    for candidate in \
        "$HOME/android-ndk"*/prebuilt/android-arm64/gdbserver/gdbserver \
        "/usr/bin/gdbserver"; do
        if [[ -f "$candidate" ]]; then
            GDBSERVER_LOCAL="$candidate"
            break
        fi
    done

    if [[ -n "$GDBSERVER_LOCAL" ]]; then
        log "Pushing: $GDBSERVER_LOCAL → $GDBSERVER_REMOTE"
        run "$ADB" -host -s "$DEVICE" push "$GDBSERVER_LOCAL" "$GDBSERVER_REMOTE"
        run "$ADB" -host -s "$DEVICE" shell chmod +x "$GDBSERVER_REMOTE"
    else
        log "Error: gdbserver not found locally either"
        exit 1
    fi
fi
echo ""

# ===================== Start gdbserver =====================
log "=== Starting gdbserver (port: ${GDBSERVER_PORT}) ==="

# Kill old gdbserver and obscura
log "Killing old processes..."
"$ADB" -host -s "$DEVICE" shell "pkill -f gdbserver 2>/dev/null || true; pkill -f obscura 2>/dev/null || true" 2>&1 | tee -a "$LOG_FILE"
sleep 1

# Build obscura command
OBSURA_CMD="$OBSURA_REMOTE"
if [[ -n "$DEBUG_ARGS" ]]; then
    OBSURA_CMD="$OBSURA_CMD $DEBUG_ARGS"
fi

# Start gdbserver in local background mode (keep adb session to avoid process kill)
log "gdbserver command: ${GDBSERVER_REMOTE} :${GDBSERVER_PORT} $OBSURA_CMD"
GDBSERVER_LOG="${LOG_DIR}/gdbserver_${TIMESTAMP}.log"
log "gdbserver output log: $GDBSERVER_LOG"

"$ADB" -host -s "$DEVICE" shell "${GDBSERVER_REMOTE} :${GDBSERVER_PORT} ${OBSURA_CMD}" > "$GDBSERVER_LOG" 2>&1 &
GDBSERVER_ADB_PID=$!
log "Local adb process PID: $GDBSERVER_ADB_PID"
sleep 2

# Check if local adb process is still alive (if gdbserver exits immediately, adb will also exit)
if ! kill -0 "$GDBSERVER_ADB_PID" 2>/dev/null; then
    log "Error: gdbserver failed to start (adb process exited)"
    log "--- gdbserver output ---"
    cat "$GDBSERVER_LOG" | tee -a "$LOG_FILE"
    exit 1
fi

# Check if log contains "Listening"
set +x
if grep -q "Listening" "$GDBSERVER_LOG" 2>/dev/null; then
    log "gdbserver started"
    grep "Listening\|Process" "$GDBSERVER_LOG" | tee -a "$LOG_FILE"
elif grep -q "Cannot\|error\|Error\|failed\|Permission" "$GDBSERVER_LOG" 2>/dev/null; then
    log "Error: gdbserver reported error"
    cat "$GDBSERVER_LOG" | tee -a "$LOG_FILE"
    kill "$GDBSERVER_ADB_PID" 2>/dev/null || true
    exit 1
else
    log "gdbserver started (waiting for connection)"
fi
set -x
echo ""

# ===================== Port Forwarding =====================
log "=== Port forwarding ${GDBSERVER_PORT} ==="
run "$ADB" -host -s "$DEVICE" forward "tcp:${GDB_FORWARD_PORT}" "tcp:${GDBSERVER_PORT}"
log "Port forward: localhost:${GDB_FORWARD_PORT} → device:${GDBSERVER_PORT}"
echo ""

# ===================== Exit in gdbserver-only mode =====================
if [[ "$MODE" == "gdbserver-only" ]]; then
    log "========================================"
    log " gdbserver running in background"
    log " Local adb PID: $GDBSERVER_ADB_PID"
    log " Log: $GDBSERVER_LOG"
    log "========================================"
    log ""
    log "Connect debugger:"
    log "  gdb-multiarch $OBSURA_LOCAL"
    log "  (gdb) target remote localhost:${GDB_FORWARD_PORT}"
    log ""
    log "View gdbserver output:"
    log "  tail -f $GDBSERVER_LOG"
    log ""
    log "Stop gdbserver:"
    log "  kill $GDBSERVER_ADB_PID"
    log "  or: $ADB -host -s $DEVICE shell pkill -f gdbserver"
    exit 0
fi

# ===================== Start gdb =====================
if [[ "$MODE" == "on-device-gdb" ]]; then
    log "=== Using device gdb ==="
    log "Entering device shell for debugging..."
    echo ""
    run "$ADB" -host -s "$DEVICE" shell "gdb $OBSURA_REMOTE"
else
    log "=== Starting gdb-multiarch ==="

    # Check gdb-multiarch
    if ! command -v gdb-multiarch &>/dev/null; then
        log "Error: gdb-multiarch not installed"
        log "Install: sudo apt install gdb-multiarch"
        exit 1
    fi

    # Create gdb init script
    GDB_INIT=$(mktemp /tmp/gdb_init_XXXXXX.gdb)
    cat > "$GDB_INIT" << EOF
set solib-search-path ./
set sysroot
target remote localhost:${GDB_FORWARD_PORT}
EOF

    log "gdb init script: $GDB_INIT"
    log "Connecting: localhost:${GDB_FORWARD_PORT}"
    echo ""

    # Start gdb-multiarch
    set +x
    gdb-multiarch \
        -x "$GDB_INIT" \
        "$OBSURA_LOCAL" \
        2>&1 | tee -a "$LOG_FILE"
    set -x

    # Cleanup
    rm -f "$GDB_INIT"
fi

# ===================== Cleanup =====================
log "=== Debug session ended ==="
log "Log: $LOG_FILE"
log "gdbserver output: $GDBSERVER_LOG"

# Kill local background adb process (will also terminate gdbserver on device)
set +x
read -p "Stop gdbserver? [Y/n] " answer
set -x
if [[ "$answer" != "n" ]] && [[ "$answer" != "N" ]]; then
    kill "$GDBSERVER_ADB_PID" 2>/dev/null || true
    run "$ADB" -host -s "$DEVICE" shell "pkill -f gdbserver 2>/dev/null" || true
    log "gdbserver stopped"
fi

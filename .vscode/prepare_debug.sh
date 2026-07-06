#!/bin/bash
set -e

TARGET_DIR="target/aarch64"
PUSH_MODE="push"

# 解析选项
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-dir) TARGET_DIR="$2"; shift 2 ;;
        --target-dir=*) TARGET_DIR="${1#*=}"; shift ;;
        --push-mode) PUSH_MODE="$2"; shift 2 ;;
        --push-mode=*) PUSH_MODE="${1#*=}"; shift ;;
        --no-push) PUSH_MODE="no-push"; shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done

DEVICE="$1"
shift || true
OBSCURA_ARGS="$*"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADB="/mnt/d/.sdk/tools/adb/linux/adb"
BIN="$PROJECT_ROOT/$TARGET_DIR/aarch64-unknown-linux-gnu/debug/obscura"

echo ""
echo "========================================"
echo "  目标目录: $TARGET_DIR"
echo "========================================"
echo ""
echo "========================================"
echo "  [1/5] 连接车机"
echo "========================================"
"$ADB" -host connect "$DEVICE"

if [[ "$PUSH_MODE" != "no-push" ]]; then
    echo ""
    echo "========================================"
    echo "  [2/5] 推送二进制"
    echo "========================================"
    "$ADB" -host -s "$DEVICE" push "$BIN" /data/obscura
    "$ADB" -host -s "$DEVICE" shell chmod +x /data/obscura
    echo "  -> 推送完成"
else
    echo ""
    echo "========================================"
    echo "  [2/5] 跳过推送 (--no-push)"
    echo "========================================"
fi

echo ""
echo "========================================"
echo "  [3/5] 清理旧进程"
echo "========================================"
"$ADB" -host -s "$DEVICE" shell 'pkill -f gdbserver 2>/dev/null || true; pkill -f obscura 2>/dev/null || true'
echo "  -> 清理完成"

echo ""
echo "========================================"
echo "  [4/5] 端口转发"
echo "========================================"
"$ADB" -host -s "$DEVICE" forward tcp:12345 tcp:12345
echo "  -> 转发完成: localhost:12345 -> 车机:12345"

echo ""
echo "========================================"
echo "  [5/5] 启动 gdbserver"
echo "========================================"
LOG_DIR="$PROJECT_ROOT/target/dbg"
mkdir -p "$LOG_DIR"
GDBSERVER_LOG="$LOG_DIR/gdbserver_$(date +%Y%m%d_%H%M%S).log"
echo "  -> 日志: $GDBSERVER_LOG"

# 本地后台启动 adb，保持连接
# 使用 nohup 避免 VS Code 关闭任务终端时发送 SIGHUP 杀死 adb 进程
echo "$ADB" -host -s "$DEVICE" shell "/usr/bin/gdbserver :12345 /data/obscura $OBSCURA_ARGS" > "$GDBSERVER_LOG" 2>&1 &
nohup "$ADB" -host -s "$DEVICE" shell "/usr/bin/gdbserver :12345 /data/obscura $OBSCURA_ARGS" > "$GDBSERVER_LOG" 2>&1 &
ADB_PID=$!
sleep 2

if kill -0 "$ADB_PID" 2>/dev/null; then
    echo "  -> gdbserver 已启动 ✅"
    grep -E 'Listening|Process' "$GDBSERVER_LOG" 2>/dev/null || true
else
    echo "  -> gdbserver 启动失败 ❌"
    cat "$GDBSERVER_LOG" 2>/dev/null
    exit 1
fi

echo ""
echo "========================================"
echo "  等待 GDB 连接..."
echo "========================================"
echo ""

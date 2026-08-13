#!/bin/bash
# ============================================================
# debug.sh - 远程调试 obscura（WSL ↔ 车机）
#
# 用法:
#   ./debug.sh <device>                    # 默认: push + gdbserver + gdb-multiarch
#   ./debug.sh <device> --gdbserver-only   # 只启动 gdbserver，不连接 gdb
#   ./debug.sh <device> --push-only        # 只 push 二进制
#   ./debug.sh <device> --on-device-gdb    # 使用车机上的 gdb
#   ./debug.sh <device> --no-push          # 跳过 push（已推送过）
#
# 示例:
#   ./debug.sh 30.207.92.65:61104
#   ./debug.sh 30.207.92.65:61104 --on-device-gdb
#   ./debug.sh 30.207.92.65:61104 --gdbserver-only --no-push
#   ./debug.sh 30.207.92.65:61104 --gdbserver-only --no-push fetch https://www.baidu.com --dump text --output page.txt
# ============================================================

set -e

# 解析项目根目录（realpath 跨平台处理软链接）并 cd 到项目根
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"
cd "$OBSCURA_DIR"

# ===================== 配置 =====================
ADB="/mnt/d/.sdk/tools/adb/linux/adb"
BUILD_TYPE="release"     # release | debug
TARGET_DIR="./target/aarch64"
OBSURA_REMOTE="/data/obscura"
GDBSERVER_REMOTE=`which gdbserver`
echo =========== $GDBSERVER_REMOTE ===========
GDBSERVER_PORT=12345
GDB_FORWARD_PORT=12345

# 根据 BUILD_TYPE 和 TARGET_DIR 设置本地二进制路径
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

# ===================== 日志初始化 =====================
LOG_DIR="${TARGET_DIR}/debug_logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
LOG_FILE="${LOG_DIR}/debug_${TIMESTAMP}.log"

# 每条命令执行前打印到日志（带时间戳前缀）
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

# 运行命令，输出同时显示并记录到日志
run() {
    log ">>> $*"
    set +x
    "$@" 2>&1 | tee -a "$LOG_FILE"
    local exit_code=${PIPESTATUS[0]}
    set -x
    return $exit_code
}

# ===================== 参数解析 =====================
DEVICE=""
MODE="full"          # full | gdbserver-only | push-only | on-device-gdb
NO_PUSH=0
DEBUG_ARGS=""        # 传给 obscura 的参数

usage() {
    echo "用法: $0 <device> [选项] [-- obscura参数...]"
    echo ""
    echo "选项:"
    echo "  --debug            使用 debug 版本（默认: release）"
    echo "  --target-dir DIR   指定编译输出目录（默认: ./target/aarch64）"
    echo "  --gdbserver-only   只启动 gdbserver，不连接本地 gdb"
    echo "  --push-only        只 push 二进制到车机"
    echo "  --on-device-gdb    使用车机上的 gdb 调试"
    echo "  --no-push          跳过 push（使用车上已有二进制）"
    echo "  --port PORT        gdbserver 端口（默认: ${GDBSERVER_PORT}）"
    echo ""
    echo "示例:"
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

# ===================== 前置检查 =====================
if [[ ! -f "$ADB" ]]; then
    echo "错误: adb 不存在: $ADB"
    exit 1
fi

if [[ "$NO_PUSH" -eq 0 ]]; then
    if [[ ! -f "$OBSURA_LOCAL" ]]; then
        echo "错误: obscura 二进制不存在: $OBSURA_LOCAL"
        if [[ "$BUILD_TYPE" == "debug" ]]; then
            echo "请先编译: ./_scripts/build.sh --debug"
        else
            echo "请先编译: ./_scripts/build.sh --release"
        fi
        exit 1
    fi
    if [[ ! -f "$OBSURA_WORKER_LOCAL" ]]; then
        echo "警告: obscura-worker 二进制不存在: $OBSURA_WORKER_LOCAL"
        echo "并行 scrape 功能将不可用，建议重新编译"
    fi
fi

echo "========================================"
echo " obscura 远程调试"
echo " 设备:    $DEVICE"
echo " 版本:    $BUILD_TYPE"
echo " 模式:    $MODE"
echo " 日志:    $LOG_FILE"
echo "========================================"
echo ""

# ===================== ADB 连接 =====================
log "=== 连接设备 ==="
run "$ADB" -host connect "$DEVICE"
sleep 1

# 验证连接
if ! "$ADB" -host -s "$DEVICE" get-state 2>&1 | tee -a "$LOG_FILE" | grep -q "device"; then
    log "错误: 设备连接失败"
    exit 1
fi
log "设备已连接"
echo ""

# ===================== Push 二进制 =====================
if [[ "$NO_PUSH" -eq 0 ]]; then
    log "=== 推送二进制 ==="
    # 推送 obscura 主程序
    run "$ADB" -host -s "$DEVICE" push "$OBSURA_LOCAL" "$OBSURA_REMOTE"
    run "$ADB" -host -s "$DEVICE" shell chmod +x "$OBSURA_REMOTE"
    log "obscura 已推送: $OBSURA_REMOTE"

    # 推送 obscura-worker（如果存在）
    if [[ -f "$OBSURA_WORKER_LOCAL" ]]; then
        OBSURA_WORKER_REMOTE="/data/obscura-worker"
        run "$ADB" -host -s "$DEVICE" push "$OBSURA_WORKER_LOCAL" "$OBSURA_WORKER_REMOTE"
        run "$ADB" -host -s "$DEVICE" shell chmod +x "$OBSURA_WORKER_REMOTE"
        log "obscura-worker 已推送: $OBSURA_WORKER_REMOTE"
    else
        log "跳过 obscura-worker（文件不存在）"
    fi
else
    log "跳过 push（--no-push）"
fi
echo ""

if [[ "$MODE" == "push-only" ]]; then
    log "push-only 模式，完成"
    exit 0
fi

# ===================== 检查 gdbserver =====================
log "=== 检查 gdbserver ==="

# 检测车机上的 gdbserver 路径
set +x
CAR_GDBSERVER=$("$ADB" -host -s "$DEVICE" shell "which gdbserver 2>/dev/null" | tr -d '\r')
set -x

if [[ -n "$CAR_GDBSERVER" ]]; then
    GDBSERVER_REMOTE="$CAR_GDBSERVER"
    log "车机 gdbserver: $GDBSERVER_REMOTE"
else
    log "车机无 gdbserver，尝试推送..."
    # 查找本地 gdbserver
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
        log "推送: $GDBSERVER_LOCAL → $GDBSERVER_REMOTE"
        run "$ADB" -host -s "$DEVICE" push "$GDBSERVER_LOCAL" "$GDBSERVER_REMOTE"
        run "$ADB" -host -s "$DEVICE" shell chmod +x "$GDBSERVER_REMOTE"
    else
        log "错误: 本地也找不到 gdbserver"
        exit 1
    fi
fi
echo ""

# ===================== 启动 gdbserver =====================
log "=== 启动 gdbserver (端口: ${GDBSERVER_PORT}) ==="

# 杀掉旧的 gdbserver 和 obscura
log "杀掉旧进程..."
"$ADB" -host -s "$DEVICE" shell "pkill -f gdbserver 2>/dev/null || true; pkill -f obscura 2>/dev/null || true" 2>&1 | tee -a "$LOG_FILE"
sleep 1

# 构造 obscura 命令
OBSURA_CMD="$OBSURA_REMOTE"
if [[ -n "$DEBUG_ARGS" ]]; then
    OBSURA_CMD="$OBSURA_CMD $DEBUG_ARGS"
fi

# 用本地后台方式启动 gdbserver（保持 adb 会话，避免进程被杀）
log "gdbserver 命令: ${GDBSERVER_REMOTE} :${GDBSERVER_PORT} $OBSURA_CMD"
GDBSERVER_LOG="${LOG_DIR}/gdbserver_${TIMESTAMP}.log"
log "gdbserver 输出日志: $GDBSERVER_LOG"

"$ADB" -host -s "$DEVICE" shell "${GDBSERVER_REMOTE} :${GDBSERVER_PORT} ${OBSURA_CMD}" > "$GDBSERVER_LOG" 2>&1 &
GDBSERVER_ADB_PID=$!
log "本地 adb 进程 PID: $GDBSERVER_ADB_PID"
sleep 2

# 检查本地 adb 进程是否还活着（如果 gdbserver 立即退出，adb 也会退出）
if ! kill -0 "$GDBSERVER_ADB_PID" 2>/dev/null; then
    log "错误: gdbserver 启动失败（adb 进程已退出）"
    log "--- gdbserver 输出 ---"
    cat "$GDBSERVER_LOG" | tee -a "$LOG_FILE"
    exit 1
fi

# 检查日志中是否有 "Listening" 字样
set +x
if grep -q "Listening" "$GDBSERVER_LOG" 2>/dev/null; then
    log "gdbserver 已启动"
    grep "Listening\|Process" "$GDBSERVER_LOG" | tee -a "$LOG_FILE"
elif grep -q "Cannot\|error\|Error\|failed\|Permission" "$GDBSERVER_LOG" 2>/dev/null; then
    log "错误: gdbserver 报告错误"
    cat "$GDBSERVER_LOG" | tee -a "$LOG_FILE"
    kill "$GDBSERVER_ADB_PID" 2>/dev/null || true
    exit 1
else
    log "gdbserver 已启动（等待连接中）"
fi
set -x
echo ""

# ===================== 端口转发 =====================
log "=== 端口转发 ${GDBSERVER_PORT} ==="
run "$ADB" -host -s "$DEVICE" forward "tcp:${GDB_FORWARD_PORT}" "tcp:${GDBSERVER_PORT}"
log "端口转发: localhost:${GDB_FORWARD_PORT} → device:${GDBSERVER_PORT}"
echo ""

# ===================== gdbserver-only 模式退出 =====================
if [[ "$MODE" == "gdbserver-only" ]]; then
    log "========================================"
    log " gdbserver 已在后台运行"
    log " 本地 adb PID: $GDBSERVER_ADB_PID"
    log " 日志: $GDBSERVER_LOG"
    log "========================================"
    log ""
    log "连接调试:"
    log "  gdb-multiarch $OBSURA_LOCAL"
    log "  (gdb) target remote localhost:${GDB_FORWARD_PORT}"
    log ""
    log "查看 gdbserver 输出:"
    log "  tail -f $GDBSERVER_LOG"
    log ""
    log "停止 gdbserver:"
    log "  kill $GDBSERVER_ADB_PID"
    log "  或: $ADB -host -s $DEVICE shell pkill -f gdbserver"
    exit 0
fi

# ===================== 启动 gdb =====================
if [[ "$MODE" == "on-device-gdb" ]]; then
    log "=== 使用车机 gdb ==="
    log "进入车机 shell 进行调试..."
    echo ""
    run "$ADB" -host -s "$DEVICE" shell "gdb $OBSURA_REMOTE"
else
    log "=== 启动 gdb-multiarch ==="

    # 检查 gdb-multiarch
    if ! command -v gdb-multiarch &>/dev/null; then
        log "错误: gdb-multiarch 未安装"
        log "安装: sudo apt install gdb-multiarch"
        exit 1
    fi

    # 创建 gdb 初始化脚本
    GDB_INIT=$(mktemp /tmp/gdb_init_XXXXXX.gdb)
    cat > "$GDB_INIT" << EOF
set solib-search-path ./
set sysroot
target remote localhost:${GDB_FORWARD_PORT}
EOF

    log "gdb 初始化脚本: $GDB_INIT"
    log "连接: localhost:${GDB_FORWARD_PORT}"
    echo ""

    # 启动 gdb-multiarch
    set +x
    gdb-multiarch \
        -x "$GDB_INIT" \
        "$OBSURA_LOCAL" \
        2>&1 | tee -a "$LOG_FILE"
    set -x

    # 清理
    rm -f "$GDB_INIT"
fi

# ===================== 清理 =====================
log "=== 调试结束 ==="
log "日志: $LOG_FILE"
log "gdbserver 输出: $GDBSERVER_LOG"

# 杀掉本地后台 adb 进程（会同时终止车机上的 gdbserver）
set +x
read -p "是否停止 gdbserver? [Y/n] " answer
set -x
if [[ "$answer" != "n" ]] && [[ "$answer" != "N" ]]; then
    kill "$GDBSERVER_ADB_PID" 2>/dev/null || true
    run "$ADB" -host -s "$DEVICE" shell "pkill -f gdbserver 2>/dev/null" || true
    log "gdbserver 已停止"
fi

#!/bin/bash
# ============================================================
# auto_debug.sh - ARM64 完全自动化调试脚本
#
# 用法:
#   ./auto_debug.sh <device> [obscura参数]
#
# 示例:
#   ./auto_debug.sh 30.207.82.136:61385
#   ./auto_debug.sh 30.207.82.136:61385 "fetch https://www.baidu.com --dump text"
#   ./auto_debug.sh 30.207.82.136:61385 "fetch https://example.com --dump html --output page.html"
#
# 特性:
#   - 完全自动化，无需人工干预
#   - 仅使用 debug 版本
#   - 自动编译、部署、调试、分析
#   - 生成完整的分析报告
# ============================================================

set -e

# 解析项目根目录（realpath 跨平台处理软链接）并 cd 到项目根
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"
cd "$OBSCURA_DIR"

# ===================== 配置 =====================
DEVICE="${1:?请提供设备地址，如 30.207.82.136:61385}"
shift
TARGET_DIR="./target/aarch64"
OBSCURA_ARGS=""
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ADB="/mnt/d/.sdk/tools/adb/linux/adb"

# 精确匹配 V8 目录（v8-X.Y.Z 格式，如 v8-137.3.0，不匹配 v8-137.3.0.bak 或 v8-137.3.0_xx）
V8_SRC_DIR=$(ls -td "${OBSCURA_DIR}"/third_party/v8-* 2>/dev/null | grep -E '/v8-[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
if [[ -z "$V8_SRC_DIR" ]]; then
    echo "错误: 未找到 V8 源代码目录 (third_party/v8-*)"
    exit 1
fi
SYSROOT="${V8_SRC_DIR}/build/linux/debian_bullseye_arm64-sysroot"

# 参数解析
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
            echo "用法: $0 <device> [选项] [obscura参数]"
            echo ""
            echo "选项:"
            echo "  --target-dir DIR    指定编译输出目录（默认: ./target/aarch64）"
            echo "  -h, --help          显示帮助信息"
            echo ""
            echo "示例:"
            echo "  $0 30.207.82.136:61385"
            echo "  $0 30.207.82.136:61385 --target-dir ./target2"
            echo "  $0 30.207.82.136:61385 \"fetch https://www.baidu.com --dump text\""
            echo "  $0 30.207.82.136:61385 --target-dir ./target2 \"fetch https://example.com\""
            exit 0
            ;;
        *)
            # 第一个非选项参数作为 obscura 参数
            if [[ -z "$OBSCURA_ARGS" ]]; then
                OBSCURA_ARGS="$1"
            fi
            shift
            ;;
    esac
done

# 设置默认值
OBSCURA_ARGS="${OBSCURA_ARGS:-fetch https://www.baidu.com --dump text}"
LOG_DIR="${TARGET_DIR}/debug_logs"

mkdir -p "$LOG_DIR"

# 颜色输出
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

# ===================== 清理函数 =====================
cleanup() {
    log_info "清理资源..."
    # 杀死可能残留的 gdbserver
    "$ADB" -host -s "$DEVICE" shell "pkill -f gdbserver 2>/dev/null" || true
    # 清理临时文件
    rm -f /tmp/gdb_auto_${TIMESTAMP}.gdb
}

trap cleanup EXIT

# ===================== 主流程 =====================
echo "========================================"
echo " ARM64 完全自动化调试"
echo " 设备:    $DEVICE"
echo " 参数:    $OBSCURA_ARGS"
echo " 时间:    $(date '+%Y-%m-%d %H:%M:%S')"
echo " 版本:    debug"
echo "========================================"
echo ""

# 1. 清理并编译
#log_info "[1/6] 清理并编译 debug 版本..."
#./_scripts/build.sh --debug clean > "$LOG_DIR/clean_${TIMESTAMP}.log" 2>&1
#if [[ $? -ne 0 ]]; then
#    log_error "清理失败"
#    exit 1
#fi

log_info "[1/6] 编译 debug 版本..."
./_scripts/build.sh --debug --target-dir "$TARGET_DIR" > "$LOG_DIR/build_${TIMESTAMP}.log" 2>&1 &
BUILD_PID=$!

# 监控编译进度
while kill -0 $BUILD_PID 2>/dev/null; do
    sleep 30
    if [[ -f build.log ]]; then
        LAST_LINE=$(tail -1 build.log)
        echo "  编译中... $(date '+%H:%M:%S') - $LAST_LINE"
    fi
done

wait $BUILD_PID
BUILD_EXIT=$?

if [[ $BUILD_EXIT -ne 0 ]]; then
    log_error "编译失败，查看日志: $LOG_DIR/build_${TIMESTAMP}.log"
    tail -20 build.log
    exit 1
fi

# 验证编译产物
BINARY="${TARGET_DIR}/aarch64-unknown-linux-gnu/debug/obscura"
WORKER_BINARY="${TARGET_DIR}/aarch64-unknown-linux-gnu/debug/obscura-worker"

if [[ ! -f "$BINARY" ]]; then
    log_error "编译产物不存在: $BINARY"
    exit 1
fi

BINARY_SIZE=$(stat -c%s "$BINARY" 2>/dev/null || stat -f%z "$BINARY" 2>/dev/null)
log_info "✓ obscura 编译完成 (大小: $((BINARY_SIZE / 1024 / 1024))M)"

# 检查 obscura-worker（可选，但推荐）
if [[ -f "$WORKER_BINARY" ]]; then
    WORKER_SIZE=$(stat -c%s "$WORKER_BINARY" 2>/dev/null || stat -f%z "$WORKER_BINARY" 2>/dev/null)
    log_info "✓ obscura-worker 编译完成 (大小: $((WORKER_SIZE / 1024 / 1024))M)"
else
    log_warn "obscura-worker 未编译，并行 scrape 功能将不可用"
fi

# 2. 连接设备
log_info "[2/6] 连接设备..."
"$ADB" -host connect "$DEVICE" > /dev/null 2>&1
sleep 2

# 验证连接
for i in {1..3}; do
    STATE=$("$ADB" -host -s "$DEVICE" get-state 2>&1)
    if [[ "$STATE" == *"device"* ]]; then
        break
    elif [[ "$STATE" == *"unauthorized"* ]]; then
        log_warn "设备未授权，尝试重新连接 ($i/3)..."
        "$ADB" kill-server
        sleep 2
        "$ADB" -host connect "$DEVICE" > /dev/null 2>&1
        sleep 3
    else
        log_error "设备连接失败: $STATE"
        exit 1
    fi
done

STATE=$("$ADB" -host -s "$DEVICE" get-state 2>&1)
if [[ "$STATE" != *"device"* ]]; then
    log_error "设备连接失败，请在车机上点击'允许 USB 调试'"
    exit 1
fi
log_info "✓ 设备已连接"

# 3. 清理旧进程
log_info "[3/6] 清理旧进程..."
"$ADB" -host -s "$DEVICE" shell "pkill -f gdbserver 2>/dev/null; pkill -f obscura 2>/dev/null" > /dev/null 2>&1
sleep 2
log_info "✓ 旧进程已清理"

# 4. 启动 gdbserver
log_info "[4/6] 启动 gdbserver..."
./_scripts/debug.sh "$DEVICE" --debug --target-dir "$TARGET_DIR" --gdbserver-only $OBSCURA_ARGS > "$LOG_DIR/debug_${TIMESTAMP}.log" 2>&1
sleep 3

# 验证 gdbserver
LATEST_GDBSERVER_LOG=$(ls -t ${TARGET_DIR}/debug_logs/gdbserver_*.log 2>/dev/null | head -1)
if [[ -z "$LATEST_GDBSERVER_LOG" ]] || ! grep -q "Listening" "$LATEST_GDBSERVER_LOG"; then
    log_error "gdbserver 启动失败"
    if [[ -n "$LATEST_GDBSERVER_LOG" ]]; then
        cat "$LATEST_GDBSERVER_LOG"
    fi
    exit 1
fi
log_info "✓ gdbserver 已启动 (端口 12345)"

# 5. GDB 自动化分析
log_info "[5/6] 运行 GDB 自动化分析..."
GDB_LOG="$LOG_DIR/gdb_auto_${TIMESTAMP}.log"

# 创建 GDB 脚本
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
echo \n=== [AUTO] 开始执行 ===\n
continue
echo \n=== [AUTO] 程序已停止 ===\n
echo \n=== [AUTO] 停止原因 ===\n
info program
echo \n=== [AUTO] 寄存器状态 ===\n
info registers
echo \n=== [AUTO] 调用栈（30层）===\n
bt 30
echo \n=== [AUTO] 线程列表 ===\n
info threads
echo \n=== [AUTO] 所有线程调用栈 ===\n
thread apply all bt 10
echo \n=== [AUTO] 分析完成 ===\n
quit
GDBEOF

# 运行 GDB（带超时）
timeout 30 gdb-multiarch -q -x /tmp/gdb_auto_${TIMESTAMP}.gdb \
  "$BINARY" 2>&1 | tee "$GDB_LOG"

GDB_EXIT=$?
if [[ $GDB_EXIT -eq 124 ]]; then
    log_warn "GDB 超时（30秒）"
elif [[ $GDB_EXIT -ne 0 ]]; then
    log_warn "GDB 退出码: $GDB_EXIT"
fi
log_info "✓ GDB 分析完成"

# 6. 生成报告
log_info "[6/6] 生成分析报告..."
REPORT="$LOG_DIR/ANALYSIS_REPORT_${TIMESTAMP}.md"

cat > "$REPORT" << EOF
# ARM64 自动调试分析报告

**生成时间**: $(date '+%Y-%m-%d %H:%M:%S')
**设备**: $DEVICE
**二进制**: debug 版本 ($((BINARY_SIZE / 1024 / 1024))M)
**参数**: $OBSCURA_ARGS
**GDB 日志**: gdb_auto_${TIMESTAMP}.log

## 执行摘要

EOF

# 分析崩溃类型
if grep -q "received signal" "$GDB_LOG"; then
    SIGNAL=$(grep "received signal" "$GDB_LOG" | head -1 | sed 's/.*received signal /信号: /')
    echo "**状态**: ❌ 程序崩溃" >> "$REPORT"
    echo "**$SIGNAL**" >> "$REPORT"
elif grep -q "exited normally" "$GDB_LOG"; then
    echo "**状态**: ✅ 程序正常退出" >> "$REPORT"
else
    echo "**状态**: ⚠️ 未知状态" >> "$REPORT"
fi

cat >> "$REPORT" << EOF

## 崩溃详情

### 信号和停止原因
\`\`\`
$(grep -A 3 "=== \[AUTO\] 停止原因 ===" "$GDB_LOG" | head -5 || echo "无信息")
\`\`\`

### 调用栈
\`\`\`
$(grep -A 35 "=== \[AUTO\] 调用栈" "$GDB_LOG" | head -35 || echo "无调用栈")
\`\`\`

### 寄存器状态
\`\`\`
$(grep -A 35 "=== \[AUTO\] 寄存器状态 ===" "$GDB_LOG" | head -35 || echo "无寄存器信息")
\`\`\`

### 线程信息
\`\`\`
$(grep -A 15 "=== \[AUTO\] 线程列表 ===" "$GDB_LOG" | head -15 || echo "无线程信息")
\`\`\`

## 自动分析

### 可疑模式
EOF

# 检测可疑模式
if grep -q "0x8080808080808080" "$GDB_LOG"; then
    echo "- ⚠️ 发现未初始化内存模式 (0x8080808080808080)" >> "$REPORT"
fi
if grep -q "0xdeadbeef" "$GDB_LOG"; then
    echo "- ⚠️ 发现 Use-after-free 模式 (0xdeadbeef)" >> "$REPORT"
fi
if grep -q "v8::internal" "$GDB_LOG"; then
    echo "- 🔍 V8 引擎相关崩溃" >> "$REPORT"
    if grep -q "Snapshot\|Deserialize" "$GDB_LOG"; then
        echo "- 📸 快照反序列化问题" >> "$REPORT"
    fi
fi

# 统计信息
if [[ $(grep -c "发现" "$REPORT" 2>/dev/null || echo 0) -eq 0 ]]; then
    echo "- ✓ 未发现明显可疑模式" >> "$REPORT"
fi

cat >> "$REPORT" << EOF

### 根本原因推测
EOF

if grep -q "0x8080808080808080" "$GDB_LOG"; then
    cat >> "$REPORT" << 'EOF'
1. **未初始化内存访问**
   - 读取到未初始化的指针或对象
   - 可能是 V8 快照配置问题
   - 检查 `v8_enable_snapshot` 配置

EOF
elif grep -q "v8::internal::Snapshot\|Deserialize" "$GDB_LOG"; then
    cat >> "$REPORT" << 'EOF'
1. **V8 快照反序列化失败**
   - 快照数据损坏或不兼容
   - 检查 V8 编译配置
   - 考虑重新生成快照

EOF
else
    cat >> "$REPORT" << 'EOF'
1. 需要进一步人工分析
2. 查看完整的 GDB 日志
3. 考虑使用交互式调试

EOF
fi

cat >> "$REPORT" << EOF

## 相关文件

- **GDB 日志**: \`$LOG_DIR/gdb_auto_${TIMESTAMP}.log\`
- **调试会话**: \`$LOG_DIR/debug_${TIMESTAMP}.log\`
- **GDBServer**: \`$LATEST_GDBSERVER_LOG\`
- **编译日志**: \`$LOG_DIR/build_${TIMESTAMP}.log\`

## 下一步

- [ ] 审查本报告
- [ ] 确认根本原因
- [ ] 实施修复
- [ ] 重新测试

## 交互式调试

如需进一步调试：

\`\`\`bash
# 启动交互式 GDB
tmux new-session -s debug "gdb-multiarch -q ${TARGET_DIR}/aarch64-unknown-linux-gnu/debug/obscura"

# 在 GDB 中连接
(gdb) target remote localhost:12345
(gdb) continue
\`\`\`

---
**报告自动生成 by arm64-auto-debug skill**
**生成时间**: $(date '+%Y-%m-%d %H:%M:%S')
EOF

log_info "✓ 报告已生成: $REPORT"

# 完成
echo ""
echo "========================================"
echo " ✓ 自动调试完成"
echo "========================================"
echo ""
echo "日志目录: $LOG_DIR"
echo "分析报告: $REPORT"
echo "GDB 日志: $GDB_LOG"
echo ""
echo "查看报告:"
echo "  cat $REPORT"
echo ""
echo "查看 GDB 输出:"
echo "  cat $GDB_LOG"

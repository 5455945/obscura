#!/bin/bash
# ============================================================
# run-arm64-debug-task.sh - 启动 ARM64 调试修复任务
#
# 用法:
#   ./run-arm64-debug-task.sh [选项]
#
# 选项:
#   --device <ip:port>              调试设备地址（默认: 30.207.82.116:62472）
#   --target-dir <dir>              目标目录（默认: target/aarch64）
#   --args <command>                obscura 运行参数
#   --success-check <file>          成功判据文件路径（默认: 自动从 --args 提取）
#   -h, --help                      显示帮助
#
# 示例:
#   # 使用默认参数
#   ./run-arm64-debug-task.sh
#
#   # 只修改设备
#   ./run-arm64-debug-task.sh --device 30.207.82.116:62471
#
#   # 修改目标目录
#   ./run-arm64-debug-task.sh --target-dir target/dbg
#
#   # 修改运行参数
#   ./run-arm64-debug-task.sh --args "fetch https://www.baidu.com --dump links"
#
#   # 完整参数
#   ./run-arm64-debug-task.sh \
#     --device 30.207.82.116:62471 \
#     --target-dir target/dbg \
#     --args "fetch https://www.baidu.com --dump html --output page.html"
# ============================================================

set -e

# 解析项目根目录（realpath 跨平台处理软链接）并 cd 到项目根
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"
cd "$OBSCURA_DIR"

# ===================== 默认值 =====================
DEVICE="30.207.82.116:62472"
TARGET_DIR="target/aarch64"
OBSCURA_ARGS="fetch https://www.baidu.com --dump html --output page.html"
SUCCESS_CHECK=""

# ===================== 帮助信息 =====================
usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --device <ip:port>              调试设备地址（默认: 30.207.82.116:62472）"
    echo "  --target-dir <dir>              目标目录（默认: target/aarch64）"
    echo "  --args <command>                obscura 运行参数"
    echo "  --success-check <file>          成功判据文件路径（默认: 自动从 --args 提取）"
    echo "  -h, --help                      显示帮助"
    echo ""
    echo "示例:"
    echo "  $0"
    echo "  $0 --device 30.207.82.116:62471"
    echo "  $0 --target-dir target/dbg"
    echo "  $0 --args \"fetch https://www.baidu.com --dump links\""
    echo "  $0 --device 30.207.82.116:62471 --target-dir target/dbg --args \"fetch https://www.baidu.com --dump html --output page.html\""
    exit 0
}

# ===================== 参数解析 =====================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            DEVICE="$2"
            shift 2
            ;;
        --device=*)
            DEVICE="${1#*=}"
            shift
            ;;
        --target-dir)
            TARGET_DIR="$2"
            shift 2
            ;;
        --target-dir=*)
            TARGET_DIR="${1#*=}"
            shift
            ;;
        --args)
            OBSCURA_ARGS="$2"
            shift 2
            ;;
        --args=*)
            OBSCURA_ARGS="${1#*=}"
            shift
            ;;
        --success-check)
            SUCCESS_CHECK="$2"
            shift 2
            ;;
        --success-check=*)
            SUCCESS_CHECK="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "未知选项: $1"
            usage
            ;;
    esac
done

# ===================== 自动提取成功判据 =====================
if [ -z "$SUCCESS_CHECK" ]; then
    # 从 OBSCURA_ARGS 中提取 --output 参数
    OUTPUT_FILE=$(echo "$OBSCURA_ARGS" | grep -oP '(?<=--output\s)\S+' || true)
    if [ -n "$OUTPUT_FILE" ]; then
        SUCCESS_CHECK="/data/$OUTPUT_FILE"
    else
        SUCCESS_CHECK="/data/page.html"
    fi
fi

# ===================== 显示配置 =====================
echo "========================================"
echo " ARM64 调试修复任务"
echo "========================================"
echo " 设备:         $DEVICE"
echo " 目标目录:     $TARGET_DIR"
echo " 运行参数:     $OBSCURA_ARGS"
echo " 成功判据:     $SUCCESS_CHECK"
echo "========================================"
echo ""

# ===================== 导出环境变量 =====================
export DEVICE
export TARGET_DIR
export OBSCURA_ARGS
export SUCCESS_CHECK

# ===================== 启动 Claude Code =====================
echo "启动 Claude Code 并加载任务文件..."
echo ""

# 检查 claude 命令是否存在
if ! command -v claude &> /dev/null; then
    echo "❌ 错误: 未找到 'claude' 命令"
    echo "请确保 Claude Code 已安装并在 PATH 中"
    exit 1
fi

# 启动 claude 并传入任务
claude <<EOF
请读取 .claude/tasks/fix-arm64-startup-crash.md 中的任务模板，并使用以下参数执行：

- 设备: $DEVICE
- 目标目录: $TARGET_DIR
- 运行参数: $OBSCURA_ARGS
- 成功判据: $SUCCESS_CHECK

开始执行任务，按照任务文件中的步骤进行。
EOF

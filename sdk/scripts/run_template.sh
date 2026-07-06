#!/bin/sh
# Obscura 通用启动脚本模板 — 检测 Node.js 18+ 并运行脚本
# 被 bundle.sh 内联到部署包中，兼容 BusyBox ash
#
# 期望环境变量:
#   OBSCURA_BIN       obscura 二进制路径
#   OBSCURA_WORKER    obscura-worker 二进制路径
#
# 用法: run.sh [demo_name]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- Node.js 版本检测（POSIX case 语法，兼容 ash）----
check_node_version() {
    case "$1" in
        v18.*|v19.*|v2[0-9].*) return 0 ;;
        *) return 1 ;;
    esac
}

NODE_CMD=""
NODE_VERSION=""

# 尝试本地 Node.js 18
LOCAL_NODE="/mnt/data/yunos/share/node-v18.20.4-linux-arm64/bin/node"
if [ -f "$LOCAL_NODE" ]; then
    NODE_CMD="$LOCAL_NODE"
    NODE_VERSION=$($NODE_CMD --version 2>&1)
    if check_node_version "$NODE_VERSION"; then
        echo "✓ 使用 Node.js: $NODE_VERSION (本地)"
    else
        NODE_CMD=""
    fi
fi

# 尝试系统 Node.js
if [ -z "$NODE_CMD" ]; then
    if command -v node >/dev/null 2>&1; then
        NODE_CMD="node"
        NODE_VERSION=$(node --version 2>&1)
        if check_node_version "$NODE_VERSION"; then
            echo "✓ 使用 Node.js: $NODE_VERSION (系统)"
        else
            echo "✗ 系统 Node.js 版本过低: $NODE_VERSION"
            NODE_CMD=""
        fi
    fi
fi

if [ -z "$NODE_CMD" ]; then
    echo "✗ 未找到 Node.js 18+"
    echo ""
    echo "请安装 Node.js 18 到 /mnt/data/yunos/share/node-v18.20.4-linux-arm64/"
    echo "下载: https://nodejs.org/dist/v18.20.4/node-v18.20.4-linux-arm64.tar.gz"
    exit 1
fi

# ---- 设置 obscura 路径 ----
if [ -z "$OBSCURA_BIN" ]; then
    OBSCURA_BIN="$SCRIPT_DIR/bin/obscura"
fi
if [ -z "$OBSCURA_WORKER" ]; then
    OBSCURA_WORKER="$SCRIPT_DIR/bin/obscura-worker"
fi
export OBSCURA_BIN OBSCURA_WORKER

# ---- 运行 ----
if [ -z "$1" ]; then
    echo "用法: ./run.sh [$(echo $RUN_TESTS | tr ',' '|')]"
    exit 1
fi

TEST_NAME="$1"
TEST_FILE="$SCRIPT_DIR/${TEST_DIR:-dist}/${TEST_NAME}.js"

if [ ! -f "$TEST_FILE" ]; then
    echo "错误: 未找到文件 $TEST_FILE"
    exit 1
fi

echo "运行: $TEST_NAME"
$NODE_CMD "$TEST_FILE"

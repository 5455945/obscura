#!/bin/bash

# 打包 obscura-tsdemo 为独立部署包
# 用法: ./bundle.sh [options]
#
# 选项:
#   --arch ARCH       目标架构: aarch64 (默认) 或 x86_64
#   --debug           打包 debug 版本二进制
#   --release         打包 release 版本二进制 (默认)
#   --clean           清理构建产物
#   -h, --help        显示帮助

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SDK_DIR="$(cd "$DEMO_DIR/../obscura_ts" && pwd)"

# 默认参数
TARGET_ARCH="aarch64"
BUILD_MODE="release"
DO_CLEAN=0

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            TARGET_ARCH="$2"
            shift 2
            ;;
        --debug)
            BUILD_MODE="debug"
            shift
            ;;
        --release)
            BUILD_MODE="release"
            shift
            ;;
        --clean)
            DO_CLEAN=1
            shift
            ;;
        -h|--help)
            sed -n '3,10p' "$0"
            exit 0
            ;;
        *)
            echo "错误: 未知选项 $1"
            exit 1
            ;;
    esac
done

# 清理
if [[ $DO_CLEAN -eq 1 ]]; then
    echo "清理打包产物..."
    rm -f "$DEMO_DIR"/obscura-tsdemo-*.tar.gz
    echo "✓ 清理完成"
    exit 0
fi

# 映射架构
case "$TARGET_ARCH" in
    aarch64|arm64)
        PLATFORM="linux-arm64"
        ;;
    x86_64|x64|amd64)
        PLATFORM="linux-x64"
        ;;
    *)
        echo "错误: 不支持的架构 $TARGET_ARCH"
        exit 1
        ;;
esac

PKG_SUFFIX=""
[[ "$BUILD_MODE" == "debug" ]] && PKG_SUFFIX="-debug"

echo "=== 打包 obscura-tsdemo ==="
echo "架构: $TARGET_ARCH ($PLATFORM)"
echo "模式: $BUILD_MODE"
echo ""

# 确保 npm 依赖和编译
if [[ ! -d "$SDK_DIR/node_modules/playwright-core" ]]; then
    echo ">>> cd sdk/obscura_ts && npm install..."
    cd "$SDK_DIR" && npm install --prefer-offline || exit 1
fi
if [[ ! -d "$DEMO_DIR/node_modules/obscura-ts" ]]; then
    echo ">>> cd sdk/obscura_tsdemo && npm install..."
    cd "$DEMO_DIR" && npm install --prefer-offline || exit 1
fi
if [[ ! -f "$DEMO_DIR/dist/verify.js" ]]; then
    echo ">>> cd sdk/obscura_tsdemo && npm run build..."
    cd "$DEMO_DIR" && npm run build || exit 1
fi

# ==================== Step 1: 调用 SDK bundler 打包 obscura-ts ====================
echo "=== [1/2] 打包 obscura-ts (调用 SDK bundler) ==="
SDK_BUNDLER="$SDK_DIR/scripts/bundle.sh"
if [[ -f "$SDK_BUNDLER" ]]; then
    bash "$SDK_BUNDLER" --arch "$TARGET_ARCH" --"$BUILD_MODE"
    echo "✓ SDK 打包完成"
else
    echo "错误: SDK bundler 不存在: $SDK_BUNDLER"
    exit 1
fi
echo ""

# ==================== Step 2: 打包 obscura-tsdemo ====================
echo "=== [2/2] 打包 obscura-tsdemo ==="
STAGING="$DEMO_DIR/_bundle_staging"
rm -rf "$STAGING"
mkdir -p "$STAGING/obscura-tsdemo"

# 1. 复制 demo dist
echo "[1/3] 复制 demo..."
if [[ -d "$DEMO_DIR/dist" ]]; then
    mkdir -p "$STAGING/obscura-tsdemo/dist"
    cp -r "$DEMO_DIR/dist/"* "$STAGING/obscura-tsdemo/dist/"
else
    echo "警告: demo dist 目录不存在，请先编译: cd sdk/obscura_tsdemo && npm run build"
fi

# 2. 生成 package.json
echo "[2/3] 生成 package.json..."
cat > "$STAGING/obscura-tsdemo/package.json" << 'EOF'
{
  "name": "obscura-tsdemo",
  "version": "0.1.0",
  "private": true
}
EOF

# 3. 创建 run.sh
echo "[3/3] 创建运行脚本..."
cat > "$STAGING/obscura-tsdemo/run.sh" << 'RUNEOF'
#!/bin/sh
# 启动脚本 — 设置环境变量并运行 demo（兼容 BusyBox ash）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

check_node_version() {
    case "$1" in
        v18.*|v19.*|v2[0-9].*) return 0 ;;
        *) return 1 ;;
    esac
}

NODE_CMD=""
LOCAL_NODE="/mnt/data/yunos/share/node-v18.20.4-linux-arm64/bin/node"
if [ -f "$LOCAL_NODE" ]; then
    NODE_CMD="$LOCAL_NODE"
    NODE_VERSION=$($NODE_CMD --version 2>&1)
    check_node_version "$NODE_VERSION" || NODE_CMD=""
    [ -n "$NODE_CMD" ] && echo "[node] $NODE_VERSION (local)"
fi
if [ -z "$NODE_CMD" ]; then
    if command -v node >/dev/null 2>&1; then
        NODE_VERSION=$(node --version 2>&1)
        if check_node_version "$NODE_VERSION"; then
            NODE_CMD="node"
            echo "[node] $NODE_VERSION (system)"
        fi
    fi
fi
if [ -z "$NODE_CMD" ]; then
    echo "ERROR: Node.js 18+ not found"
    echo "Install: https://nodejs.org/dist/v18.20.4/node-v18.20.4-linux-arm64.tar.gz"
    exit 1
fi

export OBSCURA_BIN="/data/obscura-ts/bin/obscura"
export OBSCURA_WORKER="/data/obscura-ts/bin/obscura-worker"

if [ -z "$1" ]; then
    echo "Usage: ./run.sh [verify|basic|scrape|stealth|useragent|forms]"
    exit 1
fi

# 文件名映射
case "$1" in
    useragent) DEMO_FILE="$SCRIPT_DIR/dist/test-useragent.js" ;;
    *)         DEMO_FILE="$SCRIPT_DIR/dist/${1}.js" ;;
esac

if [ ! -f "$DEMO_FILE" ]; then
    echo "ERROR: file not found: $DEMO_FILE"
    exit 1
fi
echo "Running: $1"
echo "CMD: $NODE_CMD $DEMO_FILE"
$NODE_CMD "$DEMO_FILE"
RUNEOF
chmod +x "$STAGING/obscura-tsdemo/run.sh"

# 打包
cd "$STAGING"
tar czhf "$DEMO_DIR/obscura-tsdemo-$PLATFORM$PKG_SUFFIX.tar.gz" obscura-tsdemo
cd - > /dev/null
rm -rf "$STAGING"

echo "✓ obscura-tsdemo 打包完成"
echo ""

# 显示结果
echo "=== 打包完成 ==="
ls -lh "$SDK_DIR"/obscura-ts-$PLATFORM$PKG_SUFFIX.tar.gz "$DEMO_DIR"/obscura-tsdemo-$PLATFORM$PKG_SUFFIX.tar.gz 2>/dev/null || true
echo ""
echo "部署命令:"
echo "  # 推送并解压 SDK"
echo "  tar xzf obscura-ts-$PLATFORM$PKG_SUFFIX.tar.gz -C /data/"
echo "  # 推送并解压 Demo"
echo "  tar xzf obscura-tsdemo-$PLATFORM$PKG_SUFFIX.tar.gz -C /data/obscura-test/"
echo "  # 创建模块软链接"
echo "  ln -sf /data/obscura-ts /data/obscura-test/obscura-tsdemo/node_modules/obscura-ts"
echo "  ln -sf /data/obscura-ts/node_modules/playwright-core /data/obscura-test/obscura-tsdemo/node_modules/playwright-core"
echo ""
echo "验证命令:"
echo "  cd /data/obscura-test/obscura-tsdemo && ./run.sh verify"

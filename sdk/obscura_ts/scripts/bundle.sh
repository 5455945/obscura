#!/bin/bash

# 打包 obscura-ts SDK 为独立部署包
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
SDK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SDK_DIR/../.." && pwd)"

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
    rm -f "$SDK_DIR"/obscura-ts-*.tar.gz
    echo "✓ 清理完成"
    exit 0
fi

# 映射架构
case "$TARGET_ARCH" in
    aarch64|arm64)
        PLATFORM="linux-arm64"
        RUST_TARGET="aarch64-unknown-linux-gnu"
        ;;
    x86_64|x64|amd64)
        PLATFORM="linux-x64"
        RUST_TARGET="x86_64-unknown-linux-gnu"
        ;;
    *)
        echo "错误: 不支持的架构 $TARGET_ARCH"
        exit 1
        ;;
esac

# 二进制路径
BIN_DIR="$PROJECT_ROOT/target/$TARGET_ARCH/$RUST_TARGET/$BUILD_MODE"
if [[ ! -d "$BIN_DIR" ]]; then
    echo "错误: 编译输出目录不存在: $BIN_DIR"
    echo "请先编译: ./build.sh --arch $TARGET_ARCH --$BUILD_MODE"
    exit 1
fi

# playwright-core 路径（npm install 已在上面确保安装）
PW_DIR="$SDK_DIR/node_modules/playwright-core"

echo "=== 打包 obscura-ts ==="
echo "架构: $TARGET_ARCH ($PLATFORM)"
echo "模式: $BUILD_MODE"
echo "二进制: $BIN_DIR"
echo ""

# 确保 npm 依赖已安装
if [[ ! -d "$SDK_DIR/node_modules/playwright-core" ]]; then
    echo ">>> npm install..."
    cd "$SDK_DIR" && npm install --prefer-offline || exit 1
fi

# 确保 TypeScript 已编译
if [[ ! -f "$SDK_DIR/dist/index.js" ]]; then
    echo ">>> npm run build..."
    cd "$SDK_DIR" && npm run build || exit 1
fi
if [[ ! -f "$SDK_DIR/examples-dist/basic.js" ]]; then
    echo ">>> npm run build:examples..."
    cd "$SDK_DIR" && npm run build:examples 2>/dev/null || true
fi

# 构建临时目录
STAGING="$SDK_DIR/_bundle_staging"
rm -rf "$STAGING"
mkdir -p "$STAGING/obscura-ts"

# 1. 复制 SDK（仅 .js 运行时文件）
echo "[1/5] 复制 SDK..."
cp -r "$SDK_DIR/dist" "$STAGING/obscura-ts/"
cp "$SDK_DIR/package.json" "$STAGING/obscura-ts/"
# 清理不需要的：.d.ts / .map / src/ / examples 子目录
find "$STAGING/obscura-ts/dist" -type f ! -name '*.js' -delete
find "$STAGING/obscura-ts/dist" -type d -empty -delete 2>/dev/null || true
rm -rf "$STAGING/obscura-ts/dist/src" "$STAGING/obscura-ts/dist/examples" 2>/dev/null || true

# 2. 复制二进制
echo "[2/5] 复制二进制文件..."
mkdir -p "$STAGING/obscura-ts/bin"
cp "$BIN_DIR/obscura" "$STAGING/obscura-ts/bin/"
cp "$BIN_DIR/obscura-worker" "$STAGING/obscura-ts/bin/"
chmod +x "$STAGING/obscura-ts/bin/"*

# 3. 软链接 playwright-core 到 node_modules 下（升级版本无需改脚本）
echo "[3/5] 链接 playwright-core..."
mkdir -p "$STAGING/obscura-ts/node_modules"
ln -sfn "$PW_DIR" "$STAGING/obscura-ts/node_modules/playwright-core"

# 4. 复制 examples（优先编译后的 JS，fallback 源码目录）
echo "[4/5] 复制 examples..."
if [[ -d "$SDK_DIR/examples-dist" ]]; then
    mkdir -p "$STAGING/obscura-ts/examples"
    cp -r "$SDK_DIR/examples-dist/"* "$STAGING/obscura-ts/examples/"
elif [[ -d "$SDK_DIR/examples" ]]; then
    cp -r "$SDK_DIR/examples" "$STAGING/obscura-ts/"
fi

# 5. 创建 node_modules 入口（仅 package.json，无软链接）和 run.sh
echo "[5/5] 创建 node_modules 入口和运行脚本..."
mkdir -p "$STAGING/obscura-ts/node_modules/obscura-ts"
cat > "$STAGING/obscura-ts/node_modules/obscura-ts/package.json" << 'EOF'
{"main":"../../dist/index.js"}
EOF

cat > "$STAGING/obscura-ts/run.sh" << 'RUNEOF'
#!/bin/sh
# Obscura SDK 启动脚本 — 兼容 BusyBox ash
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
    echo "Install Node.js 18+ or set PATH to include it"
    exit 1
fi

export OBSCURA_BIN="$SCRIPT_DIR/bin/obscura"
export OBSCURA_WORKER="$SCRIPT_DIR/bin/obscura-worker"

if [ -z "$1" ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Usage: ./run.sh [basic|baidu_simple_test|baidu_test|debug_baidu]"
    echo ""
    echo "Available examples:"
    ls "$SCRIPT_DIR/examples/" 2>/dev/null || echo "  (none)"
    exit 1
fi

TEST_FILE="$SCRIPT_DIR/examples/${1}.js"
if [ ! -f "$TEST_FILE" ]; then
    echo "ERROR: file not found: $TEST_FILE"
    echo "Available: $(ls "$SCRIPT_DIR/examples/" 2>/dev/null)"
    exit 1
fi
echo "Running: $1"
echo "CMD: $NODE_CMD $TEST_FILE"
$NODE_CMD "$TEST_FILE"
RUNEOF
chmod +x "$STAGING/obscura-ts/run.sh"

# 打包
PKG_SUFFIX=""
[[ "$BUILD_MODE" == "debug" ]] && PKG_SUFFIX="-debug"
OUTPUT="$SDK_DIR/obscura-ts-$PLATFORM$PKG_SUFFIX.tar.gz"
cd "$STAGING"
tar czhf "$OUTPUT" obscura-ts
cd - > /dev/null

# 清理临时目录
rm -rf "$STAGING"

# 显示结果
SIZE=$(du -h "$OUTPUT" | cut -f1)
echo ""
echo "✓ 打包完成: $OUTPUT ($SIZE)"
echo ""
echo "部署命令:"
echo "  tar xzf $(basename "$OUTPUT") -C /data/"
echo ""
echo "验证命令 (SDK 自身):"
echo "  cd /data/obscura-ts && ./run.sh basic"

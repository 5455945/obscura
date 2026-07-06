#!/bin/bash

# Obscura aarch64 部署和验证脚本
# 用法: ./deploy_and_test.sh [选项]
# 选项:
#   --device IP:PORT     设备地址 (默认: 30.207.92.96:61208)
#   --adb PATH           ADB 路径 (默认: /mnt/d/.sdk/tools/adb/linux/adb)
#   --sdk-package PATH   SDK 安装包路径 (默认: ./obscura_ts/obscura-ts-linux-arm64.tar.gz)
#   --package PATH       Demo 安装包路径 (默认: ./obscura_tsdemo/obscura-tsdemo-linux-arm64.tar.gz)
#   --tests TESTS        要运行的测试，逗号分隔 (默认: all)
#                        可选: verify,useragent,basic,scrape,stealth
#   --skip-push          跳过推送步骤（如果已推送）
#   --help               显示帮助

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 解析项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OBSCURA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 默认配置
DEVICE_IP="30.207.92.96"
DEVICE_PORT="61222"
ADB_PATH="/mnt/d/.sdk/tools/adb/linux/adb"
SDK_PACKAGE_PATH="./obscura_ts/obscura-ts-linux-arm64.tar.gz"
PACKAGE_PATH=""  # 可选，为空时只部署 SDK，不部署 demo
REMOTE_DIR="/data/obscura-test"
SDK_REMOTE_DIR="/data"
TESTS="all"
SKIP_PUSH=false
DEMO_MODE=false  # 是否同时部署了 demo

# Node.js 配置
NODE_VERSION="18.20.4"
NODE_TARBALL="node-v${NODE_VERSION}-linux-arm64.tar.gz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"
DEPS_DIR="${OBSCURA_DIR}/_deps"
NODE_LOCAL_PATH="${DEPS_DIR}/${NODE_TARBALL}"
NODE_REMOTE_BASE="/data"
NODE_REMOTE_PATH="${NODE_REMOTE_BASE}/node-v${NODE_VERSION}-linux-arm64"
NODE_PATH="${NODE_REMOTE_PATH}/bin/node"

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 显示帮助
show_help() {
    cat << EOF
Obscura aarch64 部署和验证脚本

用法: $0 [选项]

选项:
  --device IP:PORT      设备地址 (默认: 30.207.92.96:61208)
  --adb PATH            ADB 路径 (默认: /mnt/d/.sdk/tools/adb/linux/adb)
  --sdk-package PATH    SDK 安装包路径 (默认: ./obscura_ts/obscura-ts-linux-arm64.tar.gz)
  --package PATH        Demo 安装包路径 (默认: ./obscura_tsdemo/obscura-tsdemo-linux-arm64.tar.gz)
  --tests TESTS         要运行的测试，逗号分隔 (默认: all)
                        可选: verify,useragent,basic,scrape,stealth
  --skip-push           跳过推送步骤（如果已推送）
  --help                显示帮助

示例:
  $0                                                  # 使用默认配置运行所有测试
  $0 --device 192.168.1.100:5555                      # 指定设备地址
  $0 --tests verify,useragent                         # 只运行指定测试
  $0 --skip-push                                      # 跳过推送（如果已推送）
  $0 --sdk-package ./obscura_ts/obscura-ts-linux-arm64-debug.tar.gz  # 使用 debug 包

EOF
    exit 0
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --device)
            IFS=':' read -r DEVICE_IP DEVICE_PORT <<< "$2"
            shift 2
            ;;
        --adb)
            ADB_PATH="$2"
            shift 2
            ;;
        --package)
            PACKAGE_PATH="$2"
            shift 2
            ;;
        --sdk-package)
            SDK_PACKAGE_PATH="$2"
            shift 2
            ;;
        --tests)
            TESTS="$2"
            shift 2
            ;;
        --skip-push)
            SKIP_PUSH=true
            shift
            ;;
        --help)
            show_help
            ;;
        *)
            log_error "未知选项: $1"
            show_help
            ;;
    esac
done

# 设备标识
DEVICE_ID="${DEVICE_IP}:${DEVICE_PORT}"

# 检查安装包，不存在时自动构建
check_package() {
    local arch="${TARGET_ARCH:-aarch64}"
    local mode="${BUILD_MODE:-release}"
    local mode_flag="--${mode}"

    # 从包名推断 arch 和 mode
    if echo "$SDK_PACKAGE_PATH" | grep -q "x64\|x86_64\|linux-x64"; then
        arch="x86_64"
    fi
    if echo "$SDK_PACKAGE_PATH" | grep -q "debug"; then
        mode="debug"
        mode_flag="--debug"
    fi

    if [ ! -f "$SDK_PACKAGE_PATH" ]; then
        log_warn "SDK 安装包不存在: $SDK_PACKAGE_PATH"
        log_info "自动构建 SDK ($arch $mode)..."
        cd "$OBSCURA_DIR"
        bash _scripts/build.sh --arch "$arch" "$mode_flag" || {
            log_error "编译失败"
            exit 1
        }
        cd "$SCRIPT_DIR/obscura_ts"
        bash scripts/bundle.sh --arch "$arch" "$mode_flag" || {
            log_error "打包失败"
            exit 1
        }
        cd "$SCRIPT_DIR"
        if [ ! -f "$SDK_PACKAGE_PATH" ]; then
            log_error "构建后仍未找到: $SDK_PACKAGE_PATH"
            exit 1
        fi
        log_success "SDK 包已生成: $SDK_PACKAGE_PATH"
    else
        log_success "SDK 包: $SDK_PACKAGE_PATH"
    fi

    if [ -n "$PACKAGE_PATH" ] && [ -f "$PACKAGE_PATH" ]; then
        DEMO_MODE=true
        log_success "Demo 包: $PACKAGE_PATH"
    elif [ -n "$PACKAGE_PATH" ]; then
        log_warn "Demo 安装包不存在: $PACKAGE_PATH"
        log_info "自动构建 Demo ($arch $mode)..."
        cd "$SCRIPT_DIR/obscura_tsdemo"
        bash scripts/bundle.sh --arch "$arch" "$mode_flag" || {
            log_error "Demo 打包失败"
            exit 1
        }
        cd "$SCRIPT_DIR"
        if [ -f "$PACKAGE_PATH" ]; then
            DEMO_MODE=true
            log_success "Demo 包已生成: $PACKAGE_PATH"
        else
            log_error "构建后仍未找到: $PACKAGE_PATH"
            exit 1
        fi
    else
        log_info "未指定 Demo 包，仅部署和验证 SDK"
    fi
}

# 连接设备
connect_device() {
    log_info "连接设备: $DEVICE_ID"

    # 检查 ADB
    if [ ! -f "$ADB_PATH" ]; then
        log_error "ADB 不存在: $ADB_PATH"
        exit 1
    fi

    # 连接设备
    $ADB_PATH -host connect "$DEVICE_ID" || {
        log_error "连接设备失败"
        exit 1
    }

    # 等待设备就绪
    sleep 2

    # 检查设备状态
    if ! $ADB_PATH -host -s "$DEVICE_ID" get-state > /dev/null 2>&1; then
        log_error "设备未就绪"
        exit 1
    fi

    log_success "设备连接成功"
}

# 检查设备 Node.js 版本（返回状态，不退出）
check_node_version() {
    # 获取 Node.js 版本
    echo $ADB_PATH -host -s "$DEVICE_ID" shell "$NODE_PATH --version 2>&1" | tr -d '\r'
    local node_version=$($ADB_PATH -host -s "$DEVICE_ID" shell "$NODE_PATH --version 2>&1" | tr -d '\r')

    # 必须是 v 开头的版本号（如 v18.20.4），排除错误信息
    if ! echo "$node_version" | grep -qE '^v[0-9]+\.'; then
        return 1
    fi

    # 提取主版本号
    local major_version=$(echo "$node_version" | sed 's/v\([0-9]*\).*/\1/')

    if [ "$major_version" -lt 18 ]; then
        log_warn "Node.js 版本过低: $node_version (需要 >= 18)"
        return 1
    fi

    log_info "设备 Node.js: $node_version"
    return 0
}

# 下载 Node.js 到 _deps（如果不存在）
download_node_if_needed() {
    # 创建 _deps 目录
    mkdir -p "${DEPS_DIR}"

    # 检查本地是否已存在
    if [ -f "${NODE_LOCAL_PATH}" ]; then
        log_info "Node.js 包已缓存: ${NODE_LOCAL_PATH}"
        return 0
    fi

    log_info "下载 Node.js v${NODE_VERSION}..."
    log_info "URL: ${NODE_URL}"
    log_info "保存到: ${NODE_LOCAL_PATH}"

    wget -q --show-progress -O "${NODE_LOCAL_PATH}" "${NODE_URL}" || {
        log_error "下载 Node.js 失败"
        rm -f "${NODE_LOCAL_PATH}"
        exit 1
    }

    log_success "Node.js 下载完成"
}

# 推送 Node.js 到设备（如果设备上不存在）
push_node_if_needed() {
    # 检查设备上是否已存在
    if check_node_version; then
        log_info "设备上已存在 Node.js，跳过推送"
        return 0
    fi

    log_info "推送 Node.js 到设备..."

    # 推送 tarball
    $ADB_PATH -host -s "$DEVICE_ID" push "${NODE_LOCAL_PATH}" "${NODE_REMOTE_BASE}/" || {
        log_error "推送 Node.js 失败"
        exit 1
    }

    # 在设备上解压
    log_info "在设备上解压 Node.js..."
    echo $ADB_PATH -host -s "$DEVICE_ID" shell "cd ${NODE_REMOTE_BASE} && tar xzf ${NODE_TARBALL}"
    $ADB_PATH -host -s "$DEVICE_ID" shell "cd ${NODE_REMOTE_BASE} && tar xzf ${NODE_TARBALL}" || {
        log_error "解压 Node.js 失败"
        exit 1
    }

    # 清理远程 tarball
    if [[ -f "${NODE_REMOTE_BASE}/${NODE_TARBALL}" ]]; then
        echo $ADB_PATH -host -s "$DEVICE_ID" shell "rm -f ${NODE_REMOTE_BASE}/${NODE_TARBALL}" 
        $ADB_PATH -host -s "$DEVICE_ID" shell "rm -f ${NODE_REMOTE_BASE}/${NODE_TARBALL}" || true
    fi

    # 验证安装
    if ! check_node_version; then
        log_error "Node.js 安装验证失败"
        exit 1
    fi

    log_success "Node.js 推送并安装完成"
}

# 配置设备权限
setup_permissions() {
    log_info "配置设备权限..."

    # 启用调试模式
    echo $ADB_PATH -host -s "$DEVICE_ID" shell "echo 'enable n;' > /proc/alog" 2>&1
    $ADB_PATH -host -s "$DEVICE_ID" shell "echo 'enable n;' > /proc/alog" 2>&1 | grep -v "parse error" || true

    # 重新挂载为可写
    echo $ADB_PATH -host -s "$DEVICE_ID" shell "mount -o remount, rw /" 2>&1
    $ADB_PATH -host -s "$DEVICE_ID" shell "mount -o remount, rw /" 2>&1 | grep -v "parse error" || {
        log_warn "重新挂载失败，可能需要 root 权限"
    }

    log_success "权限配置完成"
}

# 推送安装包
push_package() {
    if [ "$SKIP_PUSH" = true ]; then
        log_info "跳过推送步骤"
        return
    fi

    log_info "推送 SDK 安装包到设备..."
    $ADB_PATH -host -s "$DEVICE_ID" push "$SDK_PACKAGE_PATH" "${SDK_REMOTE_DIR}/" || {
        log_error "推送 SDK 安装包失败"
        exit 1
    }

    if [ "$DEMO_MODE" = true ]; then
        log_info "推送 Demo 安装包到设备..."
        $ADB_PATH -host -s "$DEVICE_ID" shell "mkdir -p $REMOTE_DIR" || true
        $ADB_PATH -host -s "$DEVICE_ID" push "$PACKAGE_PATH" "$REMOTE_DIR/" || {
            log_error "推送 Demo 安装包失败"
            exit 1
        }
    fi

    log_success "安装包推送完成"
}

# 解压安装包
extract_package() {
    if [ "$SKIP_PUSH" = true ]; then
        log_info "跳过推送，也跳过解压"
        # 验证 SDK 目录已存在
        if ! $ADB_PATH -host -s "$DEVICE_ID" shell "test -f ${SDK_REMOTE_DIR}/obscura-ts/run.sh" 2>/dev/null; then
            log_error "SDK 未部署到设备: ${SDK_REMOTE_DIR}/obscura-ts/run.sh 不存在"
            log_info "请先运行一次不带 --skip-push 的部署"
            exit 1
        fi
        return
    fi

    local sdk_tarball=$(basename "$SDK_PACKAGE_PATH")

    # 清理旧 SDK 目录，避免残留文件
    log_info "清理旧 SDK..."
    $ADB_PATH -host -s "$DEVICE_ID" shell "rm -rf ${SDK_REMOTE_DIR}/obscura-ts" || true

    log_info "解压 SDK 安装包: $sdk_tarball..."
    $ADB_PATH -host -s "$DEVICE_ID" shell "cd ${SDK_REMOTE_DIR} && tar xzf $sdk_tarball" || {
        log_error "解压 SDK 安装包失败"
        exit 1
    }

    if [ "$DEMO_MODE" = true ]; then
        local demo_tarball=$(basename "$PACKAGE_PATH")
        log_info "解压 Demo 安装包: $demo_tarball..."
        $ADB_PATH -host -s "$DEVICE_ID" shell "cd $REMOTE_DIR && tar xzf $demo_tarball" || {
            log_error "解压 Demo 安装包失败"
            exit 1
        }

        log_info "创建模块软链接..."
        $ADB_PATH -host -s "$DEVICE_ID" shell "mkdir -p ${REMOTE_DIR}/obscura-tsdemo/node_modules" || true
        $ADB_PATH -host -s "$DEVICE_ID" shell "rm -rf ${REMOTE_DIR}/obscura-tsdemo/node_modules/obscura-ts && ln -sf ${SDK_REMOTE_DIR}/obscura-ts ${REMOTE_DIR}/obscura-tsdemo/node_modules/obscura-ts" || {
            log_error "创建 obscura-ts 软链接失败"
            exit 1
        }
        $ADB_PATH -host -s "$DEVICE_ID" shell "rm -rf ${REMOTE_DIR}/obscura-tsdemo/node_modules/playwright-core && ln -sf ${SDK_REMOTE_DIR}/obscura-ts/node_modules/playwright-core ${REMOTE_DIR}/obscura-tsdemo/node_modules/playwright-core" || {
            log_error "创建 playwright-core 软链接失败"
            exit 1
        }
    fi

    log_success "安装包解压完成"
}

# 运行单个测试
run_test() {
    local test_name=$1

    log_info "运行测试: $test_name"

    # 生成日志文件名（包含时间戳）
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_dir
    local run_cmd

    if [ "$DEMO_MODE" = true ]; then
        log_dir="${REMOTE_DIR}/logs"
        run_cmd="cd ${REMOTE_DIR}/obscura-tsdemo && ./run.sh $test_name"
    else
        log_dir="${SDK_REMOTE_DIR}/obscura-ts/logs"
        run_cmd="cd ${SDK_REMOTE_DIR}/obscura-ts && ./run.sh $test_name"
    fi

    local log_file="${log_dir}/${test_name}_${timestamp}.log"
    $ADB_PATH -host -s "$DEVICE_ID" shell "mkdir -p ${log_dir}" || true

    # 运行测试
    local output
    output=$($ADB_PATH -host -s "$DEVICE_ID" shell "$run_cmd 2>&1")
    local exit_code=$?

    # 保存日志到设备
    $ADB_PATH -host -s "$DEVICE_ID" shell "echo '$output' > $log_file" 2>/dev/null || true

    # 显示输出
    if [ -n "$output" ]; then
        echo "$output"
    fi

    # 判断成功（退出码 0 且无明显的 Error/FAIL 关键字）
    if [ $exit_code -eq 0 ] && ! echo "$output" | grep -q "^Error:\|^✗\|验证失败\|测试失败"; then
        log_success "测试 $test_name 通过"
        return 0
    else
        log_error "测试 $test_name 失败 (退出码: $exit_code)"
        if [ -z "$output" ]; then
            log_error "测试没有输出，可能是 Node.js 版本过低或其他环境问题"
        fi
        return 1
    fi
}

# 运行所有测试
run_tests() {
    log_info "开始运行测试..."

    local failed_tests=()
    local passed_tests=()

    # 确定要运行的测试列表
    local tests_to_run=()
    if [ "$TESTS" = "all" ]; then
        if [ "$DEMO_MODE" = true ]; then
            tests_to_run=(verify useragent basic scrape stealth)
        else
            tests_to_run=(basic baidu_simple_test)
        fi
    else
        IFS=',' read -ra tests_to_run <<< "$TESTS"
    fi

    # 运行每个测试
    for test in "${tests_to_run[@]}"; do
        echo ""
        echo "========================================"
        echo "运行测试: $test"
        echo "========================================"

        if run_test "$test"; then
            passed_tests+=("$test")
        else
            failed_tests+=("$test")
        fi

        sleep 1
    done

    # 显示总结
    echo ""
    echo "========================================"
    echo "测试总结"
    echo "========================================"

    if [ ${#passed_tests[@]} -gt 0 ]; then
        log_success "通过的测试 (${#passed_tests[@]}):"
        for test in "${passed_tests[@]}"; do
            echo "  ✓ $test"
        done
    fi

    if [ ${#failed_tests[@]} -gt 0 ]; then
        log_error "失败的测试 (${#failed_tests[@]}):"
        for test in "${failed_tests[@]}"; do
            echo "  ✗ $test"
        done
        echo ""
        log_info "详细日志保存在设备: ${REMOTE_DIR}/logs/"
        log_info "查看日志: adb -host -s $DEVICE_ID shell cat ${REMOTE_DIR}/logs/<日志文件>"
        exit 1
    fi

    if [ ${#passed_tests[@]} -gt 0 ] && [ ${#failed_tests[@]} -eq 0 ]; then
        log_success "所有测试通过！"
    fi
}

# 显示日志位置
show_log_info() {
    log_info "测试日志保存在设备: ${REMOTE_DIR}/logs/"
    log_info "可以通过以下命令查看日志:"
    echo "  $ADB_PATH -host -s $DEVICE_ID shell ls -lh ${REMOTE_DIR}/logs/"
    echo "  $ADB_PATH -host -s $DEVICE_ID shell cat ${REMOTE_DIR}/logs/<日志文件>"
}

# 主函数
main() {
    echo "========================================"
    echo "Obscura aarch64 部署和验证脚本"
    echo "========================================"
    echo ""

    check_package
    download_node_if_needed
    connect_device
    setup_permissions
    push_node_if_needed
    push_package
    extract_package
    run_tests
    show_log_info

    echo ""
    log_success "部署和验证完成！"
}

# 运行主函数
main

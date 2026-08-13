#!/bin/bash
# ============================================================
# build_download_android.sh - 下载 Android 交叉编译构建依赖
#
# 在 build_download.sh 基础上扩展 Android 特定依赖（NDK, catapult）
# 以及 android 目标的 Rust 标准库
#
# android_platform 不需要：独立 V8 构建不引用它
# （详见 build/android/BUILD.gn:260-261, build_with_chromium 才触发）
#
# 用法:
#   独立执行: ./build_download_android.sh [选项]
#   被引用:   source ./build_download_android.sh  （获取变量和函数，不执行下载）
#
# 选项:
#   同 build_download.sh，额外增加：
#   --skip-android-ndk      跳过 Android NDK 下载
#   --skip-android-repos    跳过 catapult 克隆
#   --skip-android-stdlib   跳过 Android Rust stdlib 下载
# ============================================================

[[ -n "$_BUILD_DOWNLOAD_ANDROID_LOADED" ]] && return 0 2>/dev/null
_BUILD_DOWNLOAD_ANDROID_LOADED=1

source "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/build_download.sh"

# ===================== Android 特定变量 =====================
ANDROID_DEPS_DIR="${DEPS_DIR}/android"

# NDK 版本从 V8 build.rs 提取，提取失败则回退 r26c
_extract_ndk_ver() {
    if [ -f "${V8_SRC_DIR}/build.rs" ]; then
        grep -oE 'android-ndk-(r[a-z0-9]+-linux)\.zip' "${V8_SRC_DIR}/build.rs" | head -1 | sed -n 's/.*\(r[a-z0-9]*\)-linux.*/\1/p'
    fi
}
NDK_VER=$(_extract_ndk_ver)
NDK_VER="${NDK_VER:-r26c}"
ANDROID_NDK_DIR="${ANDROID_DEPS_DIR}/ndk-${NDK_VER}"
NDK_API_LEVEL=24
ANDROID_NDK_URL="https://dl.google.com/android/repository/android-ndk-${NDK_VER}-linux.zip"
ANDROID_NDK_ZIP="/tmp/android-ndk-${NDK_VER}-linux.zip"

CATAPULT_DIR="${ANDROID_DEPS_DIR}/catapult"
CATAPULT_REPO="https://chromium.googlesource.com/catapult.git"

# V8 crate 内需要创建符号链接的路径（相对于 V8 源码根目录）
V8_THIRD_PARTY_DIR="${V8_SRC_DIR}/third_party"

# zip 解压辅助函数：优先使用 unzip（保留符号链接），不可用时回退 Python zipfile
# Python zipfile 不保留 Unix 符号链接，需手动修复 NDK 关键链接
_extract_zip() {
    local zip_file="$1"
    local dest_dir="$2"
    mkdir -p "$dest_dir"
    if command -v unzip &>/dev/null; then
        unzip -q -o "$zip_file" -d "$dest_dir"
    elif command -v python3 &>/dev/null; then
        python3 -c "
import zipfile, sys
with zipfile.ZipFile('$zip_file', 'r') as z:
    z.extractall('$dest_dir')
"
    else
        echo -e "${RED}错误: 未找到 unzip 或 python3，无法解压 zip 文件${NC}" >&2
        echo -e "${RED}请安装 unzip: apt install unzip${NC}" >&2
        return 1
    fi
    # 补充修复：确保 NDK bin/ 下所有文件可执行，修复被 zip/py 损坏的符号链接
    for ext_dir in "${dest_dir}"/android-ndk-*/; do
        local bin_dir="${ext_dir}toolchains/llvm/prebuilt/linux-x86_64/bin"
        if [ -d "$bin_dir" ]; then
            chmod +x "$bin_dir"/*
            cd "$bin_dir" || continue
            [ -f clang-17 ] && [ ! -L clang ] && ln -sf clang-17 clang 2>/dev/null
            [ -L clang ] && [ ! -L clang++ ] && ln -sf clang clang++ 2>/dev/null
            [ -f lld ] && [ ! -L ld.lld ] && ln -sf lld ld.lld 2>/dev/null
            [ -f lld ] && [ ! -L ld64.lld ] && ln -sf lld ld64.lld 2>/dev/null
            [ -f llvm-ar ] && [ ! -L ar ] && ln -sf llvm-ar ar 2>/dev/null
            [ -f llvm-objcopy ] && [ ! -L objcopy ] && ln -sf llvm-objcopy objcopy 2>/dev/null
            [ -f llvm-nm ] && [ ! -L nm ] && ln -sf llvm-nm nm 2>/dev/null
            [ -f llvm-strip ] && [ ! -L strip ] && ln -sf llvm-strip strip 2>/dev/null
            [ -f llvm-ranlib ] && [ ! -L ranlib ] && ln -sf llvm-ranlib ranlib 2>/dev/null
            cd - > /dev/null
            echo ">>> 已修复 NDK 二进制文件权限和符号链接"
        fi
    done
}

# ===================== Android 下载函数 =====================

download_android_stdlib() {
    local TARGET_TRIPLE="${1:-aarch64-linux-android}"
    local LOCAL_VERSION
    if [ -z "$RUST_DIR" ] || [ ! -x "$RUST_DIR/rustc/bin/rustc" ]; then
        echo -e "${RED}错误: Rust 工具链未就绪，请先运行 download_rust_toolchain${NC}"
        return 1
    fi
    LOCAL_VERSION=$(basename "$RUST_DIR" | sed -n 's/.*rust-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    if [ -z "$LOCAL_VERSION" ]; then
        echo -e "${RED}错误: 无法从 $RUST_DIR 提取 Rust 版本号${NC}"
        return 1
    fi

    if [[ "$BD_FORCE" == "1" ]]; then
        rm -rf "${RUST_DIR}/rustc/lib/rustlib/${TARGET_TRIPLE}"
    fi

    if [ -d "${RUST_DIR}/rustc/lib/rustlib/${TARGET_TRIPLE}" ]; then
        echo -e "${BLUE}Android Rust stdlib 已就绪: ${RUST_DIR}/rustc/lib/rustlib/${TARGET_TRIPLE}${NC}"
        return 0
    fi

    echo "=== 下载 Android Rust 标准库 (${TARGET_TRIPLE}) ==="

    local CHANNEL_URL="https://mirrors.tuna.tsinghua.edu.cn/rustup/dist/channel-rust-stable.toml"
    local CHANNEL_TOML="/tmp/channel-rust-stable-android.toml"

    echo -e "下载 channel 清单: ${BLUE}${CHANNEL_URL}${NC}"
    wget -q --timeout=10 -O "$CHANNEL_TOML" "$CHANNEL_URL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 下载 channel 清单失败${NC}"
        return 1
    fi

    local STD_URL
    STD_URL=$(awk '/^\[pkg\.rust-std\.target\.'"${TARGET_TRIPLE//./\\.}"'\]/{f=1} f&&/^url =/{gsub(/^url = "|"$|^$/, ""); print; exit}' "$CHANNEL_TOML")
    rm -f "$CHANNEL_TOML"

    if [ -z "$STD_URL" ]; then
        echo -e "${RED}错误: 无法找到 ${TARGET_TRIPLE} stdlib URL${NC}"
        return 1
    fi

    local CHANNEL_VERSION
    CHANNEL_VERSION=$(echo "$STD_URL" | sed -n 's/.*rust-std-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    echo -e "本地 Rust:   ${BLUE}${LOCAL_VERSION}${NC}"
    echo -e "Channel 版本: ${BLUE}${CHANNEL_VERSION}${NC}"
    echo -e "Stdlib URL:   ${BLUE}${STD_URL}${NC}"

    if [ "$LOCAL_VERSION" != "$CHANNEL_VERSION" ]; then
        echo -e "${YELLOW}警告: Channel 版本 (${CHANNEL_VERSION}) 与本地工具链 (${LOCAL_VERSION}) 不一致${NC}"
        echo -e "${YELLOW}      stdlib 版本必须与 rustc 严格匹配，尝试从 Rust 官方镜像下载匹配版本...${NC}"
        local DOWNLOAD_DATE
        DOWNLOAD_DATE=$(echo "$STD_URL" | sed -n 's/.*dist\/\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\).*/\1/p')
        if [ -n "$DOWNLOAD_DATE" ]; then
            STD_URL="https://mirrors.tuna.tsinghua.edu.cn/rustup/dist/${DOWNLOAD_DATE}/rust-std-${LOCAL_VERSION}-${TARGET_TRIPLE}.tar.gz"
            echo -e "尝试匹配版本 URL: ${BLUE}${STD_URL}${NC}"
        fi
    fi

    local STD_TARBALL="/tmp/rust-std-android.tar.gz"
    echo ">>> 下载 Android stdlib..."
    rm -f "$STD_TARBALL"
    wget -c --timeout=30 --tries=2 -O "$STD_TARBALL" "$STD_URL"

    if [ $? -ne 0 ] || [ ! -f "$STD_TARBALL" ]; then
        echo -e "${YELLOW}警告: 首次 URL 下载失败，尝试从 static.rust-lang.org 下载...${NC}"
        rm -f "$STD_TARBALL"
        local FALLBACK_URL="https://static.rust-lang.org/dist/rust-std-${LOCAL_VERSION}-${TARGET_TRIPLE}.tar.gz"
        echo -e "备用 URL: ${BLUE}${FALLBACK_URL}${NC}"
        wget -c --timeout=30 --tries=2 -O "$STD_TARBALL" "$FALLBACK_URL"
        if [ $? -ne 0 ] || [ ! -f "$STD_TARBALL" ]; then
            echo -e "${RED}错误: 所有 URL 下载 Android stdlib 均失败${NC}"
            return 1
        fi
    fi

    local FILE_SIZE
    FILE_SIZE=$(stat -c%s "$STD_TARBALL" 2>/dev/null || stat -f%z "$STD_TARBALL" 2>/dev/null)
    if [[ "$FILE_SIZE" -lt 1000000 ]]; then
        echo -e "${RED}错误: Android stdlib 文件过小 (${FILE_SIZE} bytes)${NC}"
        rm -f "$STD_TARBALL"
        return 1
    fi

    echo ">>> 解压并添加到 Rust 工具链..."
    local EXTRACT_DIR="/tmp/rust-std-android-extract"
    rm -rf "$EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"
    tar xzf "$STD_TARBALL" -C "$EXTRACT_DIR"

    local STD_LIB_DIR
    STD_LIB_DIR=$(find "$EXTRACT_DIR" -type d -name "${TARGET_TRIPLE}" -path "*/lib/rustlib/*" -print -quit)
    if [ -z "$STD_LIB_DIR" ]; then
        STD_LIB_DIR=$(find "$EXTRACT_DIR" -type d -name "${TARGET_TRIPLE}" -print -quit)
    fi
    if [ -z "$STD_LIB_DIR" ]; then
        echo -e "${RED}错误: 解压后未找到 ${TARGET_TRIPLE} stdlib${NC}"
        rm -rf "$EXTRACT_DIR"
        return 1
    fi

    cp -ar "$STD_LIB_DIR" "${RUST_DIR}/rustc/lib/rustlib/"
    rm -rf "$EXTRACT_DIR"
    rm -f "$STD_TARBALL"

    echo -e "${GREEN}=== Android Rust stdlib 就绪: ${RUST_DIR}/rustc/lib/rustlib/${TARGET_TRIPLE} ===${NC}"
    echo ""
}

download_android_ndk() {
    if [[ "$BD_FORCE" == "1" ]] && [[ -d "$ANDROID_NDK_DIR" ]]; then
        echo "=== [--force] 删除已有 Android NDK: $ANDROID_NDK_DIR ==="
        rm -rf "$ANDROID_NDK_DIR"
    fi

    if [ -f "${ANDROID_NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${NDK_API_LEVEL}-clang++" ]; then
        echo -e "${BLUE}Android NDK r26c 已就绪: $ANDROID_NDK_DIR${NC}"
        return 0
    fi

    echo "=== 下载 Android NDK r26c ==="
    echo -e "下载链接: ${BLUE}${ANDROID_NDK_URL}${NC}"
    echo -e "保存路径: ${BLUE}${ANDROID_NDK_DIR}${NC}"

    mkdir -p "${ANDROID_DEPS_DIR}"

    if [ ! -f "$ANDROID_NDK_ZIP" ]; then
        echo ">>> 下载 NDK zip (~500MB)..."
        wget -c --timeout=60 --tries=3 -O "$ANDROID_NDK_ZIP" "$ANDROID_NDK_URL"
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: Android NDK 下载失败${NC}"
            echo -e "${RED}请检查网络连接或手动下载到: ${ANDROID_NDK_ZIP}${NC}"
            return 1
        fi
    else
        echo ">>> 使用已缓存的 NDK zip: $ANDROID_NDK_ZIP"
    fi

    local FILE_SIZE
    FILE_SIZE=$(stat -c%s "$ANDROID_NDK_ZIP" 2>/dev/null || stat -f%z "$ANDROID_NDK_ZIP" 2>/dev/null)
    if [[ "$FILE_SIZE" -lt 100000000 ]]; then
        echo -e "${RED}错误: NDK zip 文件过小 (${FILE_SIZE} bytes)，可能下载不完整${NC}"
        rm -f "$ANDROID_NDK_ZIP"
        return 1
    fi

    echo ">>> 解压 NDK 到 ${ANDROID_DEPS_DIR}..."
    _extract_zip "$ANDROID_NDK_ZIP" "${ANDROID_DEPS_DIR}/"

    local EXTRACTED_DIR="${ANDROID_DEPS_DIR}/android-ndk-r26c"
    if [ ! -d "$EXTRACTED_DIR" ]; then
        echo -e "${RED}错误: NDK 解压失败，未找到 android-ndk-r26c 目录${NC}"
        return 1
    fi

    # 如果目标已经是同名目录，移动内容而非重命名
    if [ "$EXTRACTED_DIR" != "$ANDROID_NDK_DIR" ]; then
        mv "$EXTRACTED_DIR" "$ANDROID_NDK_DIR"
    fi

    rm -f "$ANDROID_NDK_ZIP"

    echo -e "${GREEN}=== Android NDK r26c 就绪: $ANDROID_NDK_DIR ===${NC}"
    echo ""
}

download_catapult() {
    if [[ "$BD_FORCE" == "1" ]] && [[ -d "$CATAPULT_DIR" ]]; then
        echo "=== [--force] 删除已有 catapult: $CATAPULT_DIR ==="
        rm -rf "$CATAPULT_DIR"
    fi

    if [ -d "${CATAPULT_DIR}/.git" ]; then
        echo -e "${BLUE}catapult 已就绪: $CATAPULT_DIR${NC}"
        return 0
    fi

    echo "=== 克隆 catapult ==="
    echo -e "仓库:   ${BLUE}${CATAPULT_REPO}${NC}"
    echo -e "保存路径: ${BLUE}${CATAPULT_DIR}${NC}"

    mkdir -p "${ANDROID_DEPS_DIR}"
    git clone --depth=1 "$CATAPULT_REPO" "$CATAPULT_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: catapult 克隆失败${NC}"
        return 1
    fi

    echo -e "${GREEN}=== catapult 就绪: $CATAPULT_DIR ===${NC}"
    echo ""
}

create_android_v8_symlinks() {
    if [ ! -d "$V8_THIRD_PARTY_DIR" ]; then
        echo -e "${YELLOW}警告: V8 third_party 目录不存在: $V8_THIRD_PARTY_DIR（cargo vendor 尚未执行？）${NC}"
        return 1
    fi

    echo "=== 创建 V8 → Android 依赖符号链接 ==="

    # android_ndk 符号链接
    # V8 build.rs 检查 ./third_party/android_ndk/... 是否存在，存在则跳过下载
    local V8_NDK_LINK="${V8_THIRD_PARTY_DIR}/android_ndk"
    if [ -L "$V8_NDK_LINK" ]; then
        local current_target
        current_target=$(readlink "$V8_NDK_LINK")
        if [ "$current_target" = "$ANDROID_NDK_DIR" ]; then
            echo -e "${BLUE}android_ndk 符号链接已就绪: $V8_NDK_LINK${NC}"
        else
            rm -f "$V8_NDK_LINK"
            _create_relative_symlink "$ANDROID_NDK_DIR" "$V8_NDK_LINK"
        fi
    elif [ -d "$V8_NDK_LINK" ]; then
        echo ">>> V8 内已有 android_ndk 实体目录，跳过"
    else
        _create_relative_symlink "$ANDROID_NDK_DIR" "$V8_NDK_LINK"
    fi

    # android_platform：独立 V8 不需要内容，但 V8 build.rs 检查路径存在性，
    # 若不存在会尝试 git clone（离线失败）。保留一个空目录作为占位。
    local V8_AP_LINK="${V8_THIRD_PARTY_DIR}/android_platform"
    local AP_DIR="${ANDROID_DEPS_DIR}/android_platform"
    mkdir -p "$AP_DIR"
    if [ ! -L "$V8_AP_LINK" ] && [ ! -d "$V8_AP_LINK" ]; then
        _create_relative_symlink "$AP_DIR" "$V8_AP_LINK"
    fi

    # catapult 符号链接
    local V8_CT_LINK="${V8_THIRD_PARTY_DIR}/catapult"
    if [ -L "$V8_CT_LINK" ]; then
        local current_target
        current_target=$(readlink "$V8_CT_LINK")
        if [ "$current_target" != "$CATAPULT_DIR" ]; then
            rm -f "$V8_CT_LINK"
            _create_relative_symlink "$CATAPULT_DIR" "$V8_CT_LINK"
        else
            echo -e "${BLUE}catapult 符号链接已就绪: $V8_CT_LINK${NC}"
        fi
    elif [ -d "$V8_CT_LINK" ]; then
        echo ">>> V8 内已有 catapult 实体目录，跳过"
    else
        _create_relative_symlink "$CATAPULT_DIR" "$V8_CT_LINK"
    fi

    echo ""
}

# ===================== 帮助信息 =====================

bd_android_usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "下载 Obscura Android 交叉编译（x86_64 → aarch64-linux-android）所需的全部依赖。"
    echo ""
    echo "基础选项（同 build_download.sh）:"
    echo "  --skip-clang       跳过 clang 下载"
    echo "  --skip-rust        跳过 Rust 工具链下载"
    echo "  --skip-ninja-gn    跳过 ninja/gn 下载"
    echo "  --skip-libclang    跳过 libclang.so 下载"
    echo "  --skip-sysroot     跳过 Debian sysroot 下载（Android 编译不需要）"
    echo "  --skip-cmake       跳过 cmake 下载（--features stealth 需要）"
    echo "  --skip-vendor      跳过 cargo vendor"
    echo "  --vendor-only      只执行 cargo vendor（跳过其他所有下载）"
    echo "  --force            强制重新下载已存在的文件"
    echo ""
    echo "Android 特定选项:"
    echo "  --skip-android-ndk     跳过 Android NDK 下载"
    echo "  --skip-android-repos   跳过 catapult 克隆"
    echo "  --skip-android-stdlib  跳过 Android Rust stdlib 下载"
    echo ""
    echo "  -h, --help         显示帮助"
    echo ""
    echo "示例:"
    echo "  $0                                     # 下载全部内容"
    echo "  $0 --vendor-only                       # 只执行 cargo vendor"
    echo "  $0 --skip-android-ndk                  # 跳过 NDK 下载（使用已有 NDK）"
    echo "  $0 --force                             # 强制重新下载所有内容"
    exit 0
}

# ===================== 独立执行逻辑 =====================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    BD_SKIP_RUST=0
    BD_SKIP_CLANG=0
    BD_SKIP_NINJA_GN=0
    BD_SKIP_LIBCLANG=0
    BD_SKIP_SYSROOT=1        # Android 不需要 Debian sysroot
    BD_SKIP_CMAKE=0
    BD_SKIP_VENDOR=0
    BD_VENDOR_ONLY=0
    BD_FORCE=0
    BD_SKIP_ANDROID_NDK=0
    BD_SKIP_ANDROID_REPOS=0
    BD_SKIP_ANDROID_STDLIB=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-clang)            BD_SKIP_CLANG=1; shift ;;
            --skip-rust)             BD_SKIP_RUST=1; shift ;;
            --skip-ninja-gn)         BD_SKIP_NINJA_GN=1; shift ;;
            --skip-libclang)         BD_SKIP_LIBCLANG=1; shift ;;
            --skip-sysroot)          BD_SKIP_SYSROOT=1; shift ;;
            --skip-cmake)            BD_SKIP_CMAKE=1; shift ;;
            --skip-vendor)           BD_SKIP_VENDOR=1; shift ;;
            --vendor-only)           BD_VENDOR_ONLY=1; shift ;;
            --force)                 BD_FORCE=1; shift ;;
            --skip-android-ndk)      BD_SKIP_ANDROID_NDK=1; shift ;;
            --skip-android-repos)    BD_SKIP_ANDROID_REPOS=1; shift ;;
            --skip-android-stdlib)   BD_SKIP_ANDROID_STDLIB=1; shift ;;
            -h|--help)               bd_android_usage ;;
            *)
                echo "未知选项: $1"
                bd_android_usage
                ;;
        esac
    done

    echo "=== build_download_android.sh 开始: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23) ==="
    echo "  FORCE=$BD_FORCE  VENDOR_ONLY=$BD_VENDOR_ONLY"
    echo ""

    cd "$OBSCURA_DIR"

    if [[ "$BD_VENDOR_ONLY" == "1" ]]; then
        create_cargo_configs
        run_vendor || exit 1
    else
        # 1. Rust 工具链（含 Android stdlib）
        [[ "$BD_SKIP_RUST" -eq 0 ]] && download_rust_toolchain || echo ">>> 跳过 Rust 工具链下载"
        # 先设置 Rust 环境，后续 cargo vendor 需要
        export RUST_DIR="${RUST_DIR}"
        if [ -n "$RUST_DIR" ] && [ -x "$RUST_DIR/rustc/bin/rustc" ]; then
            export RUSTC="$RUST_DIR/rustc/bin/rustc"
            export CARGO="$RUST_DIR/cargo/bin/cargo"
            export PATH="$RUST_DIR/rustc/bin:$RUST_DIR/cargo/bin:$RUST_DIR/clippy-preview/bin:$PATH"
        fi

        # 2. cargo vendor
        if [[ "$BD_SKIP_VENDOR" -eq 0 ]]; then
            create_cargo_configs
            run_vendor || exit 1
            # vendor 后重新扫描 V8_SRC_DIR
            V8_SRC_DIR=$(ls -td "${OBSCURA_DIR}"/third_party/v8-* 2>/dev/null | grep -E '/v8-[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
            V8_THIRD_PARTY_DIR="${V8_SRC_DIR}/third_party"
        else
            echo ">>> 跳过 cargo vendor"
        fi

        # 3. clang
        [[ "$BD_SKIP_CLANG" -eq 0 ]] && download_clang || echo ">>> 跳过 clang 下载"

        # 4. ninja/gn
        [[ "$BD_SKIP_NINJA_GN" -eq 0 ]] && download_ninja_gn || echo ">>> 跳过 ninja/gn 下载"

        # 5. libclang
        [[ "$BD_SKIP_LIBCLANG" -eq 0 ]] && download_libclang || echo ">>> 跳过 libclang 下载"

        # 6. cmake
        [[ "$BD_SKIP_CMAKE" -eq 0 ]] && download_cmake || echo ">>> 跳过 cmake 下载"

        # 7. Android Rust stdlib
        if [[ "$BD_SKIP_ANDROID_STDLIB" -eq 0 ]]; then
            download_android_stdlib "aarch64-linux-android" || echo -e "${YELLOW}警告: aarch64 stdlib 下载失败${NC}"
            download_android_stdlib "x86_64-linux-android" || echo -e "${YELLOW}警告: x86_64 stdlib 下载失败${NC}"
        else
            echo ">>> 跳过 Android Rust stdlib 下载"
        fi

        # 8. Android NDK
        if [[ "$BD_SKIP_ANDROID_NDK" -eq 0 ]]; then
            download_android_ndk || exit 1
        else
            echo ">>> 跳过 Android NDK 下载"
        fi

        # 9. catapult（android_platform 不需要，见文件头注释）
        if [[ "$BD_SKIP_ANDROID_REPOS" -eq 0 ]]; then
            download_catapult || echo -e "${YELLOW}警告: catapult 下载失败${NC}"
        else
            echo ">>> 跳过 catapult 下载"
        fi

        # 10. 创建 V8 tree 内符号链接（让 build.rs 跳过自己的下载）
        create_android_v8_symlinks || echo -e "${YELLOW}警告: 符号链接创建失败（不影响 cargo vendor 后首次构建）${NC}"
    fi

    echo ""
    echo "=== build_download_android.sh 完成: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23) ==="
fi

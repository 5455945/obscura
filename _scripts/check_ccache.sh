#!/bin/bash
# check_ccache.sh - Check, install and configure ccache
# Used to accelerate V8 and C/C++ compilation
#
# Usage: source this script in build.sh
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/check_ccache.sh"
#
# On success, the following environment variables are exported:
#   CCACHE_ENABLED=1
#   CCACHE_DIR
#   CCACHE_MAXSIZE
#   CC (if not already set)
#   CXX (if not already set)

[[ -n "$_CCACHE_CHECK_LOADED" ]] && return 0 2>/dev/null
_CCACHE_CHECK_LOADED=1

# Resolve project root directory (realpath handles symlinks cross-platform)
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# Detect runtime environment
detect_environment() {
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        echo "mingw64"
    elif [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
            echo "ubuntu"
        else
            echo "linux"
        fi
    else
        echo "unknown"
    fi
}

# Check if ccache is installed (system or _deps/ccache)
check_ccache_installed() {
    # First check system PATH
    if command -v ccache &> /dev/null; then
        return 0
    fi
    # Then check _deps/ccache/bin/ccache
    if [[ -x "${OBSCURA_DIR}/_deps/ccache/bin/ccache" ]]; then
        return 0
    fi
    return 1
}

# Download ccache from Ubuntu mirror to _deps/ccache/
install_ccache_ubuntu() {
    echo -e "${BLUE}=== Downloading ccache from Ubuntu mirror to _deps/ccache/ ===${NC}"

    local DEPS_DIR="${OBSCURA_DIR}/_deps"
    local CCACHE_DEPS_DIR="${DEPS_DIR}/ccache"
    # ccache 3.7.7 has simple dependencies (libc6 + zlib), already satisfied on the system
    local CCACHE_DEB_URL="https://mirrors.tuna.tsinghua.edu.cn/ubuntu/pool/main/c/ccache/ccache_3.7.7-1_amd64.deb"
    local CCACHE_DEB="/tmp/ccache_3.7.7-1_amd64.deb"

    # Download ccache .deb package
    echo -e "${BLUE}Downloading: ${CCACHE_DEB_URL}${NC}"
    wget -q -O "$CCACHE_DEB" "$CCACHE_DEB_URL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to download ccache${NC}"
        rm -f "$CCACHE_DEB"
        return 1
    fi

    # Extract to _deps/ccache/
    echo -e "${BLUE}Extracting to: ${CCACHE_DEPS_DIR}${NC}"
    mkdir -p "${CCACHE_DEPS_DIR}"
    dpkg-deb -x "$CCACHE_DEB" "${CCACHE_DEPS_DIR}"
    rm -f "$CCACHE_DEB"

    # Remove unnecessary directories (docs, man pages, etc.)
    rm -rf "${CCACHE_DEPS_DIR}/usr/share"

    # Create bin directory and link ccache binary
    mkdir -p "${CCACHE_DEPS_DIR}/bin"
    ln -srf "${CCACHE_DEPS_DIR}/usr/bin/ccache" "${CCACHE_DEPS_DIR}/bin/ccache"

    # Verify extraction
    if [[ ! -x "${CCACHE_DEPS_DIR}/bin/ccache" ]]; then
        echo -e "${RED}Error: ccache extraction failed${NC}"
        return 1
    fi

    # Add _deps/ccache/bin to PATH
    export PATH="${CCACHE_DEPS_DIR}/bin:${PATH}"

    echo -e "${GREEN}=== ccache 3.7.7 download complete ===${NC}"
    echo -e "  Path: ${BLUE}$(command -v ccache)${NC}"
    echo -e "  Version: $(ccache --version | head -n1)"
    return 0
}

# Install ccache on MSYS2/MinGW64
install_ccache_mingw64() {
    echo -e "${BLUE}=== Attempting to install ccache on MSYS2/MinGW64 ===${NC}"

    if ! command -v pacman &> /dev/null; then
        echo -e "${RED}Error: pacman not found${NC}"
        return 1
    fi

    # MSYS2 environment
    if [[ "$OSTYPE" == "msys" ]]; then
        echo -e "${BLUE}Running: pacman -S --noconfirm ccache${NC}"
        pacman -S --noconfirm ccache
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: ccache installation failed${NC}"
            return 1
        fi
    # MinGW64 environment
    elif [[ "$OSTYPE" == "cygwin" && "$MSYSTEM" == "MINGW64" ]]; then
        echo -e "${BLUE}Running: pacman -S --noconfirm mingw-w64-x86_64-ccache${NC}"
        pacman -S --noconfirm mingw-w64-x86_64-ccache
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: ccache installation failed${NC}"
            return 1
        fi
    else
        echo -e "${RED}Error: Unsupported MSYS2 environment: OSTYPE=$OSTYPE, MSYSTEM=$MSYSTEM${NC}"
        return 1
    fi

    echo -e "${GREEN}=== ccache installed successfully ===${NC}"
    return 0
}

# Configure ccache
configure_ccache() {
    local obscura_dir="$1"

    # Set cache directory (under project root)
    export CCACHE_DIR="${obscura_dir}/.ccache"
    export CCACHE_MAXSIZE="50G"  # 50GB cache

    # Create cache directory
    mkdir -p "${CCACHE_DIR}"

    # Enable compression (saves space)
    export CCACHE_COMPRESS="1"
    export CCACHE_COMPRESSLEVEL="6"

    # Other optimization options
    export CCACHE_SLOPPINESS="include_file_mtime,time_macros"
    export CCACHE_CPP2="1"  # Use -cpp2 mode for better hit rate

    echo -e "${GREEN}=== ccache configured ===${NC}"
    echo -e "  Cache dir: ${BLUE}${CCACHE_DIR}${NC}"
    echo -e "  Max size: ${BLUE}${CCACHE_MAXSIZE}${NC}"
    echo -e "  Compression: ${BLUE}Enabled (level ${CCACHE_COMPRESSLEVEL})${NC}"

    # Show current cache statistics
    if check_ccache_installed; then
        echo ""
        echo -e "${BLUE}Current ccache statistics:${NC}"
        ccache -s 2>/dev/null || true
    fi
}

# Set up compiler wrapper
setup_compiler_wrapper() {
    # If CC/CXX are already set, wrap them; otherwise use default clang/gcc
    if [[ -n "$CC" ]]; then
        # CC is set, wrap with ccache
        if [[ "$CC" != ccache* ]]; then
            export CC="ccache $CC"
        fi
    else
        # CC not set, use default clang/gcc
        if command -v clang &> /dev/null; then
            export CC="ccache clang"
        elif command -v gcc &> /dev/null; then
            export CC="ccache gcc"
        fi
    fi

    if [[ -n "$CXX" ]]; then
        # CXX is set, wrap with ccache
        if [[ "$CXX" != ccache* ]]; then
            export CXX="ccache $CXX"
        fi
    else
        # CXX not set, use default clang++/g++
        if command -v clang++ &> /dev/null; then
            export CXX="ccache clang++"
        elif command -v g++ &> /dev/null; then
            export CXX="ccache g++"
        fi
    fi

    # Export flag indicating ccache is enabled
    export CCACHE_ENABLED=1

    echo -e "${GREEN}=== Compiler wrapper configured ===${NC}"
    [[ -n "$CC" ]] && echo -e "  CC=${BLUE}${CC}${NC}"
    [[ -n "$CXX" ]] && echo -e "  CXX=${BLUE}${CXX}${NC}"
}

# Main function
main() {
    # OBSCURA_DIR already resolved via realpath at script top (handles symlinks)
    local obscura_dir="$OBSCURA_DIR"
    local env=$(detect_environment)

    echo -e "${BLUE}=== ccache check and configuration ===${NC}"
    echo -e "Detected environment: ${BLUE}${env}${NC}"

    # Check if already installed
    if check_ccache_installed; then
        # If ccache is in _deps/ccache/ (not in system PATH), ensure PATH is updated
        if ! command -v ccache &> /dev/null && [[ -x "${obscura_dir}/_deps/ccache/bin/ccache" ]]; then
            export PATH="${obscura_dir}/_deps/ccache/bin:${PATH}"
        fi
        echo -e "${GREEN}✓ ccache is installed${NC}"
        echo -e "  Version: $(ccache --version | head -n1)"
        echo -e "  Path: $(command -v ccache)"
    else
        echo -e "${YELLOW}✗ ccache is not installed${NC}"

        # Attempt installation
        case "$env" in
            ubuntu|debian)
                install_ccache_ubuntu
                if [ $? -ne 0 ]; then
                    echo ""
                    echo -e "${RED}=========================================${NC}"
                    echo -e "${RED}Error: ccache installation failed${NC}"
                    echo -e "${RED}=========================================${NC}"
                    echo -e "${YELLOW}Please install manually:${NC}"
                    echo -e "  ${BLUE}sudo apt-get install ccache${NC}"
                    echo ""
                    echo -e "${YELLOW}Continuing build without ccache (slower compilation)...${NC}"
                    export CCACHE_ENABLED=0
                    return 0
                fi
                ;;
            mingw64)
                install_ccache_mingw64
                if [ $? -ne 0 ]; then
                    echo ""
                    echo -e "${RED}=========================================${NC}"
                    echo -e "${RED}Error: ccache installation failed${NC}"
                    echo -e "${RED}=========================================${NC}"
                    echo -e "${YELLOW}Please install manually:${NC}"
                    echo -e "  ${BLUE}MSYS2: pacman -S ccache${NC}"
                    echo -e "  ${BLUE}MinGW64: pacman -S mingw-w64-x86_64-ccache${NC}"
                    echo ""
                    echo -e "${YELLOW}Continuing build without ccache (slower compilation)...${NC}"
                    export CCACHE_ENABLED=0
                    return 0
                fi
                ;;
            *)
                echo ""
                echo -e "${RED}=========================================${NC}"
                echo -e "${RED}Error: Unsupported environment or missing ccache${NC}"
                echo -e "${RED}=========================================${NC}"
                echo -e "${YELLOW}Please install ccache manually:${NC}"
                echo -e "  ${BLUE}Ubuntu/Debian: sudo apt-get install ccache${NC}"
                echo -e "  ${BLUE}MSYS2: pacman -S ccache${NC}"
                echo -e "  ${BLUE}MinGW64: pacman -S mingw-w64-x86_64-ccache${NC}"
                echo ""
                echo -e "${YELLOW}Continuing build without ccache (slower compilation)...${NC}"
                export CCACHE_ENABLED=0
                return 0
                ;;
        esac

        # Check again if installation succeeded
        if ! check_ccache_installed; then
            echo -e "${RED}Error: ccache still not found after installation${NC}"
            export CCACHE_ENABLED=0
            return 0
        fi
    fi

    # Configure ccache
    configure_ccache "$obscura_dir"

    # Set up compiler wrapper
    setup_compiler_wrapper

    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}✓ ccache enabled, will significantly speed up compilation${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
}

# Execute main function
main "$@"

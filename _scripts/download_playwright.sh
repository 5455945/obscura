#!/bin/bash
# ============================================================
# download_playwright.sh - Download Playwright source package to _deps/playwright/
#
# Usage:
#   ./_scripts/download_playwright.sh                    # Download default version (v1.60.0)
#   ./_scripts/download_playwright.sh --version 1.61.0   # Download specific version
#   ./_scripts/download_playwright.sh --force             # Force re-download
#   ./_scripts/download_playwright.sh --check-only        # Check for updates only, no download
#
# Options:
#   --version <version>   Specify Playwright version (e.g. 1.60.0, 1.61.0)
#   --force               Force re-download of existing files
#   --check-only          Only check for newer version, no download
#   -h, --help            Show help
# ============================================================

set -euo pipefail

# ===================== Constants =====================
# Resolve project root directory
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"

# Playwright dependency directory
PLAYWRIGHT_DIR="${OBSCURA_DIR}/_deps/playwright"

# Default version
DEFAULT_PLAYWRIGHT_VERSION="1.60.0"

# GitHub API URL
GITHUB_API_URL="https://api.github.com/repos/microsoft/playwright/releases/latest"

# Timeout (seconds)
API_TIMEOUT=10
DOWNLOAD_TIMEOUT=300

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# ===================== Argument Parsing =====================
PLAYWRIGHT_VERSION="$DEFAULT_PLAYWRIGHT_VERSION"
FORCE_DOWNLOAD=0
CHECK_ONLY=0

show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Download Playwright source package to _deps/playwright/"
    echo ""
    echo "Options:"
    echo "  --version <version>   Specify Playwright version (e.g. 1.60.0, 1.61.0)"
    echo "  --force               Force re-download of existing files"
    echo "  --check-only          Only check for newer version, no download"
    echo "  -h, --help            Show help"
    echo ""
    echo "Examples:"
    echo "  $0                           # Download default version v${DEFAULT_PLAYWRIGHT_VERSION}"
    echo "  $0 --version 1.61.0          # Download v1.61.0"
    echo "  $0 --force                   # Force re-download"
    echo "  $0 --check-only              # Check for updates only"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            if [[ -z "${2:-}" ]]; then
                echo -e "${RED}Error: --version requires a version number${NC}" >&2
                exit 1
            fi
            PLAYWRIGHT_VERSION="$2"
            shift 2
            ;;
        --force)
            FORCE_DOWNLOAD=1
            shift
            ;;
        --check-only)
            CHECK_ONLY=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown argument '$1'${NC}" >&2
            show_help
            exit 1
            ;;
    esac
done

# ===================== Utility Functions =====================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $*"
}

# Compare versions: return 0 if $1 > $2, 1 if $1 == $2, 2 if $1 < $2
compare_versions() {
    local v1="$1"
    local v2="$2"

    if [[ "$v1" == "$v2" ]]; then
        return 1
    fi

    local IFS='.'
    read -ra V1_PARTS <<< "$v1"
    read -ra V2_PARTS <<< "$v2"

    local max_len=${#V1_PARTS[@]}
    if [[ ${#V2_PARTS[@]} -gt $max_len ]]; then
        max_len=${#V2_PARTS[@]}
    fi

    for ((i = 0; i < max_len; i++)); do
        local p1=${V1_PARTS[i]:-0}
        local p2=${V2_PARTS[i]:-0}

        if ((p1 > p2)); then
            return 0
        elif ((p1 < p2)); then
            return 2
        fi
    done

    return 1
}

# Get latest stable version from GitHub API
get_latest_version() {
    local response
    local tag_name

    # Query GitHub API using curl with timeout
    if ! response=$(curl -s -m "$API_TIMEOUT" \
        -H "Accept: application/vnd.github.v3+json" \
        "$GITHUB_API_URL" 2>/dev/null); then
        return 1
    fi

    # Parse tag_name (format: "tag_name": "v1.61.0")
    tag_name=$(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"v\{0,1\}\([^"]*\)".*/\1/')

    if [[ -z "$tag_name" ]]; then
        return 1
    fi

    echo "$tag_name"
    return 0
}

# Check for updates
check_for_updates() {
    local current_version="$1"
    local latest_version

    log_info "Checking Playwright updates (current: v${current_version})..."

    if ! latest_version=$(get_latest_version); then
        log_warn "Update check timed out or failed, using local cached version"
        return 0
    fi

    if [[ -z "$latest_version" ]]; then
        log_warn "Unable to parse latest version info"
        return 0
    fi

    # Compare versions
    compare_versions "$latest_version" "$current_version"
    local cmp_result=$?

    if [[ $cmp_result -eq 0 ]]; then
        echo ""
        log_info "═══════════════════════════════════════════════════════════"
        log_info "Newer stable version found: v${latest_version} (current: v${current_version})"
        log_info "Update command: $0 --version ${latest_version}"
        log_info "═══════════════════════════════════════════════════════════"
        echo ""
        return 0
    else
        log_info "Current version v${current_version} is the latest stable version"
        return 0
    fi
}

# Download Playwright source package
download_playwright() {
    local version="$1"
    local target_file="${PLAYWRIGHT_DIR}/v${version}.tar.gz"
    local download_url="https://github.com/microsoft/playwright/archive/refs/tags/v${version}.tar.gz"

    # Create directory
    mkdir -p "$PLAYWRIGHT_DIR"

    # Check if file already exists
    if [[ -f "$target_file" ]] && [[ "$FORCE_DOWNLOAD" -eq 0 ]]; then
        log_info "Playwright v${version} already exists: ${target_file}"
        return 0
    fi

    if [[ "$FORCE_DOWNLOAD" -eq 1 ]] && [[ -f "$target_file" ]]; then
        log_info "Force re-download, removing old file: ${target_file}"
        rm -f "$target_file"
    fi

    log_info "Downloading Playwright v${version}..."
    log_info "URL: ${download_url}"
    log_info "Target: ${target_file}"

    if ! curl -L -m "$DOWNLOAD_TIMEOUT" \
        -o "$target_file" \
        --progress-bar \
        "$download_url"; then
        log_error "Download failed"
        rm -f "$target_file"
        return 1
    fi

    # Verify download
    if [[ ! -f "$target_file" ]] || [[ ! -s "$target_file" ]]; then
        log_error "Downloaded file is empty or missing"
        rm -f "$target_file"
        return 1
    fi

    local file_size
    file_size=$(stat -c%s "$target_file" 2>/dev/null || stat -f%z "$target_file" 2>/dev/null || echo "unknown")
    log_info "Download complete: ${target_file} (${file_size} bytes)"

    return 0
}

# ===================== Main =====================

main() {
    log_info "Playwright dependency manager"
    log_info "Project dir: ${OBSCURA_DIR}"
    log_info "Playwright dir: ${PLAYWRIGHT_DIR}"

    local target_file="${PLAYWRIGHT_DIR}/v${PLAYWRIGHT_VERSION}.tar.gz"

    # Check if file already exists
    if [[ -f "$target_file" ]]; then
        log_info "Playwright v${PLAYWRIGHT_VERSION} already exists: ${target_file}"

        # Check for updates
        check_for_updates "$PLAYWRIGHT_VERSION"

        if [[ "$CHECK_ONLY" -eq 1 ]]; then
            log_info "Check-only mode, exiting"
            return 0
        fi

        if [[ "$FORCE_DOWNLOAD" -eq 0 ]]; then
            log_info "Using existing file. Use --force to re-download"
            return 0
        fi
    else
        if [[ "$CHECK_ONLY" -eq 1 ]]; then
            log_warn "No local Playwright v${PLAYWRIGHT_VERSION}, but in check-only mode"
            # Still check for updates
            check_for_updates "$PLAYWRIGHT_VERSION"
            return 0
        fi

        log_info "Playwright v${PLAYWRIGHT_VERSION} not found, starting download..."
    fi

    # Download
    if ! download_playwright "$PLAYWRIGHT_VERSION"; then
        log_error "Download failed, please check network connection"
        exit 1
    fi

    log_info "Playwright v${PLAYWRIGHT_VERSION} is ready"
    log_info "Next step: Run sdk/obscura_ts/prepare_playwright.sh to extract and configure"
}

main

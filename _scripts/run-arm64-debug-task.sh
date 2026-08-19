#!/bin/bash
# ============================================================
# run-arm64-debug-task.sh - Launch ARM64 debug fix task
#
# Usage:
#   ./run-arm64-debug-task.sh [options]
#
# Options:
#   --device <ip:port>              Debug device address (default: 30.207.82.116:62472)
#   --target-dir <dir>              Target directory (default: target/aarch64)
#   --args <command>                obscura run arguments
#   --success-check <file>          Success criteria file path (default: auto-extracted from --args)
#   -h, --help                      Show help
#
# Examples:
#   # Use default parameters
#   ./run-arm64-debug-task.sh
#
#   # Change device only
#   ./run-arm64-debug-task.sh --device 30.207.82.116:62471
#
#   # Change target directory
#   ./run-arm64-debug-task.sh --target-dir target/dbg
#
#   # Change run arguments
#   ./run-arm64-debug-task.sh --args "fetch https://www.baidu.com --dump links"
#
#   # Full parameters
#   ./run-arm64-debug-task.sh \
#     --device 30.207.82.116:62471 \
#     --target-dir target/dbg \
#     --args "fetch https://www.baidu.com --dump html --output page.html"
# ============================================================

set -e

# Resolve project root directory (realpath handles symlinks cross-platform) and cd to it
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"
cd "$OBSCURA_DIR"

# ===================== Defaults =====================
DEVICE="30.207.82.116:62472"
TARGET_DIR="target/aarch64"
OBSCURA_ARGS="fetch https://www.baidu.com --dump html --output page.html"
SUCCESS_CHECK=""

# ===================== Help =====================
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --device <ip:port>              Debug device address (default: 30.207.82.116:62472)"
    echo "  --target-dir <dir>              Target directory (default: target/aarch64)"
    echo "  --args <command>                obscura run arguments"
    echo "  --success-check <file>          Success criteria file path (default: auto-extracted from --args)"
    echo "  -h, --help                      Show help"
    echo ""
    echo "Examples:"
    echo "  $0"
    echo "  $0 --device 30.207.82.116:62471"
    echo "  $0 --target-dir target/dbg"
    echo "  $0 --args \"fetch https://www.baidu.com --dump links\""
    echo "  $0 --device 30.207.82.116:62471 --target-dir target/dbg --args \"fetch https://www.baidu.com --dump html --output page.html\""
    exit 0
}

# ===================== Argument Parsing =====================
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
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# ===================== Auto-extract Success Criteria =====================
if [ -z "$SUCCESS_CHECK" ]; then
    # Extract --output argument from OBSCURA_ARGS
    OUTPUT_FILE=$(echo "$OBSCURA_ARGS" | sed -n 's/.*--output[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' || true)
    if [ -n "$OUTPUT_FILE" ]; then
        SUCCESS_CHECK="/data/$OUTPUT_FILE"
    else
        SUCCESS_CHECK="/data/page.html"
    fi
fi

# ===================== Show Configuration =====================
echo "========================================"
echo " ARM64 Debug Fix Task"
echo "========================================"
echo " Device:         $DEVICE"
echo " Target dir:     $TARGET_DIR"
echo " Run args:       $OBSCURA_ARGS"
echo " Success check:  $SUCCESS_CHECK"
echo "========================================"
echo ""

# ===================== Export Environment Variables =====================
export DEVICE
export TARGET_DIR
export OBSCURA_ARGS
export SUCCESS_CHECK

# ===================== Launch Claude Code =====================
echo "Launching Claude Code and loading task file..."
echo ""

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "❌ Error: 'claude' command not found"
    echo "Please ensure Claude Code is installed and in PATH"
    exit 1
fi

# Launch claude with task
claude <<EOF
Please read the task template in .claude/tasks/fix-arm64-startup-crash.md and execute with the following parameters:

- Device: $DEVICE
- Target dir: $TARGET_DIR
- Run args: $OBSCURA_ARGS
- Success check: $SUCCESS_CHECK

Start executing the task, following the steps in the task file.
EOF

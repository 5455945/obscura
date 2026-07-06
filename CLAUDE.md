# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Obscura is a headless browser engine written in Rust, designed for web scraping and AI agent automation. It provides a lightweight alternative to headless Chrome (~30MB vs 200+MB memory) with built-in anti-detection features, V8 JavaScript engine support, and Chrome DevTools Protocol (CDP) compatibility.

## Architecture

The project is a Rust workspace with the following crate structure:

**Core Layer:**
- `obscura-dom`: DOM parsing and manipulation using html5ever and Servo's selectors library
- `obscura-net`: HTTP networking layer with reqwest, cookie management, robots.txt support, and optional stealth features
- `obscura-js`: JavaScript runtime using V8 via deno_core, including ops (operations) for DOM/network access and markdown conversion

**Browser Layer:**
- `obscura-browser`: Core browser functionality, page lifecycle management, and browser contexts
- `obscura-cdp`: Chrome DevTools Protocol implementation for Puppeteer/Playwright compatibility
- `obscura-mcp`: Model Context Protocol server that exposes browser tools to AI agents (Claude Desktop, Cursor, etc.)

**Application Layer:**
- `obscura-cli`: Command-line interface providing `obscura` binary with `fetch`, `serve`, `scrape`, and `mcp` subcommands
- `obscura`: Public Rust API for programmatic usage

**Dependency Flow:**
```
obscura-cli → obscura-mcp → obscura-browser → obscura-js → obscura-dom
                                              ↓            ↓
                                          obscura-net ← obscura-dom
```

The `obscura` crate is a standalone public API that wraps `obscura-browser` for library usage.

## Build Commands

**优先使用 ./build.sh 编译命令**

**Standard development build:**
```bash
cargo build
```

**Release build:**
```bash
cargo build --release
```

**Release build with stealth mode (anti-detection + tracker blocking):**
```bash
cargo build --release --features stealth
```

**Run tests:**
```bash
cargo test
```

**Run tests for a specific crate:**
```bash
cargo test -p obscura-dom
cargo test -p obscura-js
```

**Run a specific test:**
```bash
cargo test test_name
```

**Check compilation without building:**
```bash
cargo check
```

**Format code:**
```bash
cargo fmt
```

**Lint with clippy:**
```bash
cargo clippy
```

**编译 debug 版本：**
```bash
./_scripts/build.sh --debug
```

**编译 release 版本：**
```bash
./_scripts/build.sh --release
```

**Release build with stealth mode (anti-detection + tracker blocking)
**编译 debug 版本：**
```bash
./_scripts/build.sh --debug --features stealth
```

**编译 release 版本：**
```bash
./_scripts/build.sh --release --features stealth
```

**清理 debug 版本缓存：**
```bash
./_scripts/build.sh --debug clean
```

**清理 release 版本缓存：**
```bash
./_scripts/build.sh --release clean
```

**Important:** First build takes ~5 minutes because V8 compiles from source. Subsequent builds use cached artifacts.

## Key Development Notes

**V8 Integration:**
- The project uses `deno_core` to embed V8 JavaScript engine
- V8 requires `panic = "unwind"` in release mode (see Cargo.toml) - this is critical for the anti-panic protocol that prevents V8 FFI crashes
- V8 flags can be passed via CLI: `obscura --v8-flags "--max-old-space-size=4096"`

**Stealth Mode:**
- Enabled via `--features stealth` flag
- Propagates through crate dependencies: `obscura-cli` → `obscura-browser` → `obscura-net`
- Includes anti-fingerprinting, tracker blocking, and navigator.webdriver spoofing

**Testing:**
- Tests use standard Rust `#[cfg(test)]` inline test modules
- Located throughout the codebase (see `crates/*/src/*.rs` files)
- Run with `cargo test` from workspace root

**Dependencies:**
- All dependencies are vendored in `third_party/` directory
- Managed via `cargo vendor --versioned-dirs third_party --locked`
- No external network access needed for builds after initial setup

## Cross-compilation for ARM64

`build.sh` 实现了从 x86_64 交叉编译到 aarch64-linux-gnu 的完整流程。

### 构建流程

`build.sh` 采用两阶段构建：
1. **Vendor 阶段**：使用 USTC 镜像下载依赖到 `third_party/`
2. **Build 阶段**：使用本地 vendor 目录离线编译

### 关键配置

**Sysroot（ARM64 系统库）**
```bash
# 复用 V8 自带的 sysroot（Debian Bullseye arm64）
V8_SRC_DIR="${OBSCURA_DIR}/third_party/v8-137.3.0"
SYSROOT_DIR="${V8_SRC_DIR}/build/linux/debian_bullseye_arm64-sysroot"

# 如果不存在，使用 V8 的脚本自动下载
( cd "$V8_SRC_DIR" && python3 ./build/linux/sysroot_scripts/install-sysroot.py --arch=arm64 )
( cd "$V8_SRC_DIR" && python3 ./build/linux/sysroot_scripts/install-sysroot.py --arch=amd64 )
```

**pkg-config 配置**
```bash
# 让 V8 的 GN 构建能找到 sysroot 里的 glib 等库
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT_DIR"
export PKG_CONFIG_LIBDIR="${SYSROOT_DIR}/usr/lib/aarch64-linux-gnu/pkgconfig:${SYSROOT_DIR}/usr/lib/pkgconfig:${SYSROOT_DIR}/usr/share/pkgconfig"
```

**Bindgen 配置**
```bash
# bindgen 在 host (x86_64) 上运行，需要配置正确的 C++ 标准库路径
export LIBCLANG_PATH="/usr/lib/llvm-21/lib"
export BINDGEN_EXTRA_CLANG_ARGS="-nostdinc++ \
  -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE \
  -D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS \
  -isystem ${V8_SRC_DIR}/third_party/libc++/src/include \
  -isystem ${V8_SRC_DIR}/third_party/libc++abi/src/include \
  -isystem ${V8_SRC_DIR}/buildtools/third_party/libc++ \
  -isystem ${V8_SRC_DIR}/../target/aarch64/release/clang/lib/clang/21/include \
  --sysroot=${SYSROOT_DIR} --target=aarch64-linux-gnu"
```

**链接器配置**
```bash
# 使用 V8 自带的 lld（在 target/aarch64/release/clang/bin/）
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="clang-21"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="\
  -C link-arg=--target=aarch64-linux-gnu \
  -C link-arg=--sysroot=${SYSROOT_DIR} \
  -C link-arg=-fuse-ld=lld \
  -C link-arg=-B${OBSCURA_DIR}/target/aarch64/release/clang/bin"
```

**其他工具**
```bash
export CC_aarch64_unknown_linux_gnu="clang-21"
export CXX_aarch64_unknown_linux_gnu="clang-21"
export AR_aarch64_unknown_linux_gnu="llvm-ar"  # 避免依赖 aarch64-linux-gnu-ar
```

### 常见问题

**1. `bits/libc-header-start.h` file not found**
- 原因：缺少 ARM64 sysroot
- 解决：确保 `SYSROOT_DIR` 已下载，且 `CFLAGS` 包含 `--sysroot=${SYSROOT_DIR}`

**2. `glib-2.0 was not found` 或 `Package glib-2.0 was not found`**
- 原因：pkg-config 没有指向 sysroot
- 解决：设置 `PKG_CONFIG_SYSROOT_DIR` 和 `PKG_CONFIG_LIBDIR`

**3. `cstdint file not found`（bindgen）**
- 原因：bindgen 找不到 C++ 标准库头文件
- 解决：设置 `BINDGEN_EXTRA_CLANG_ARGS` 指定 libc++ 路径，使用 `-nostdinc++` 禁用默认搜索

**4. `explicit specialization of non-template struct 'basic_common_reference'`**
- 原因：系统的 libstdc++ 和 V8 的 libc++ 冲突
- 解决：使用 `-nostdinc++` 禁用系统 C++ 标准库，指向 V8 的 libc++

**5. `unrecognised emulation mode: aarch64linux`**
- 原因：系统 `ld` 不支持 aarch64
- 解决：使用 V8 自带的 lld：`-fuse-ld=lld -B${V8_CLANG_BIN}`

**6. `failed to find tool "aarch64-linux-gnu-ar"`**
- 原因：缺少交叉编译工具链
- 解决：使用 `llvm-ar` 替代，它支持所有架构

### 构建产物

```bash
target/aarch64/aarch64-unknown-linux-gnu/release/obscura        # 70M
target/aarch64/aarch64-unknown-linux-gnu/release/obscura-worker # 67M
```

## Important Configuration

**Single page fetch:**
```bash
cargo run -- fetch https://example.com --dump html
cargo run -- fetch https://example.com --eval "document.title"
```

**Start CDP server (for Puppeteer/Playwright):**
```bash
cargo run -- serve --port 9222
cargo run -- serve --port 9222 --stealth
```

**Parallel scraping:**
```bash
cargo run -- scrape url1 url2 url3 --concurrency 25 --eval "document.querySelector('h1').textContent"
```

**MCP server for AI agents:**
```bash
cargo run -- mcp
cargo run -- mcp --http --port 8080
```

## SDK Packaging Rules

### Two Package Types

**1. obscura-ts (SDK library)**
- **Purpose**: Standalone SDK package for npm distribution or direct deployment
- **Build**: `cd sdk/obscura_ts && bash scripts/bundle.sh --arch <arch> --<mode>`
- **Output**: `sdk/obscura_ts/obscura-ts-<platform>-<mode>.tar.gz`
- **Contents**: dist/, src/, package.json, bin/, playwright-core/, examples/ or tests/
- **Binary path**: `bin/obscura` (flat, no platform subdirectory)
- **Self-contained**: Includes all dependencies, can run directly after extraction

**2. obscura-tsdemo (demo/test suite)**
- **Purpose**: Demo applications that use obscura-ts
- **Build**: `cd sdk/obscura_tsdemo && bash scripts/bundle.sh --arch <arch> --<mode>`
- **Output**: `sdk/obscura_tsdemo/obscura-tsdemo-<platform>-<mode>.tar.gz`
- **Contents**: dist/, package.json, run.sh
- **Dependencies**: Requires obscura-ts to be deployed at `/data/obscura-ts`
- **Module links**: Created by deploy_and_test.sh at deployment time

### Build Parameters

Both bundle scripts accept identical parameters:
```bash
--arch <arch>     Target architecture: aarch64 (default) or x86_64
--debug           Package debug binaries
--release         Package release binaries (default)
--clean           Remove all build artifacts for this script
```

### Platform Naming

| Architecture | Platform Tag | Rust Target |
|--------------|--------------|-------------|
| aarch64 | linux-arm64 | aarch64-unknown-linux-gnu |
| x86_64 | linux-x64 | x86_64-unknown-linux-gnu |

### Build Directory Structure

```
target/
  aarch64/aarch64-unknown-linux-gnu/
    debug/      # build.sh --debug output
    release/    # build.sh --release output
  x86_64/x86_64-unknown-linux-gnu/
    debug/
    release/
```

### Cleaning Rules

- **Architecture isolation**: `--clean` only removes packages for the specified architecture
- **Mode isolation**: Debug and release builds are independent; cleaning one does not affect the other
- **npm vs deployment**: `npm pack` output (`.tgz`) is independent of `bundle.sh` output (`.tar.gz`)

### Critical Constraints

1. **tar without -h flag**: Bundle scripts use `tar czf` (not `tar czhf`) because node_modules contains self-referential symlinks that cause infinite recursion with `-h`
2. **obscura-ts self-reference**: Must include `node_modules/obscura-ts -> ..` so that `require('obscura-ts')` works in tests/ and examples/
3. **obscura-tsdemo no placeholders**: Do not create empty placeholder files in node_modules; Node.js will find them and report MODULE_NOT_FOUND. Symlinks are created by deploy_and_test.sh
4. **POSIX shell compatibility**: All run.sh scripts must use `#!/bin/sh` and POSIX syntax (case statements, not `[[ ]]`) for BusyBox ash compatibility on vehicle systems
5. **Style consistency**: obscura_ts and obscura_tsdemo use identical parameter parsing, naming conventions, and script structure. When modifying one, apply the same pattern to the other

### Deployment Flow

```bash
# 1. Build SDK
cd sdk/obscura_ts
bash scripts/bundle.sh --arch aarch64 --release

# 2. Build demos (optional)
cd sdk/obscura_tsdemo
bash scripts/bundle.sh --arch aarch64 --release

# 3. Deploy to vehicle
cd sdk
bash deploy_and_test.sh --device <ip:port> --tests verify

# deploy_and_test.sh will:
# - Push obscura-ts-<platform>-<mode>.tar.gz to /data/
# - Push obscura-tsdemo-<platform>-<mode>.tar.gz to /data/obscura-test/
# - Extract both packages
# - Create symlinks: /data/obscura-test/obscura-tsdemo/node_modules/{obscura-ts,playwright-core}
# - Run specified tests
```

## Common Development Tasks

**Adding a new CDP method:**
1. Implement in `crates/obscura-cdp/src/` following the existing domain structure
2. Add corresponding test in the same file using `#[cfg(test)]` module
3. Update CDP documentation in main README.md if it's a new domain

**Modifying JavaScript runtime:**
1. Changes to V8 integration go in `crates/obscura-js/src/runtime.rs`
2. New JavaScript operations (ops) go in `crates/obscura-js/src/ops/`
3. Test with both unit tests and manual CLI testing

**Working with DOM:**
1. DOM parsing logic is in `crates/obscura-dom/src/`
2. Uses html5ever for HTML parsing
3. CSS selector support via Servo's selectors library

## Permissions Policy

All operations within this project are allowed without asking for confirmation. This includes:
- All file read/write operations within the project directory
- All system information reads
- All network queries
- All system tool operations on project files
- Modifications to system temporary directories

**Strictly forbidden:** Modifying anything outside the project directory.

## Important Configuration

**Release profile:** Uses `panic = "unwind"` (not "abort") - required for V8 FFI safety. Do not change this.

**Workspace structure:** All crates use workspace dependencies defined in root `Cargo.toml`. When adding dependencies, prefer workspace-level definitions.

**Feature flags:** The `stealth` feature propagates through multiple crates. When adding new stealth-related code, ensure the feature flag is properly threaded through dependencies.

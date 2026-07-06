---
name: multi-env-debug-setup
description: >
  根据当前项目和系统环境，自动配置 QoderCN/VS Code 的多环境调试配置（.vscode/launch.json + tasks.json）。
  支持环境：Win10、MSYS2/MinGW64、WSL Ubuntu、原生 Linux。
  支持架构：host 本地调试、aarch64 远程 GDB 调试（车机）。
  检测可用环境后全部配置，用户手动选择，默认优先 host 环境。
---

# 多环境调试配置自动化

## 何时触发

用户要求：
- "配置调试环境"
- "设置 launch.json"
- "配置 IDE 调试"
- "添加调试配置"
- 或明确提到需要在 QoderCN/VS Code 中配置调试

## 核心原则

1. **先检测，后配置**：不假设环境，必须实际检测系统状态
2. **多环境并行配置**：如果系统同时存在多个可用环境（如 Win10 + WSL），全部配置好
3. **默认优先 host**：将 host 本地调试配置设为默认（第一个）
4. **架构敏感**：区分 host 架构与 target 架构，决定是本地调试还是远程交叉调试
5. **不覆盖用户已有配置**：如果 `.vscode/launch.json` 已存在，先备份再追加/合并

## 环境检测矩阵

### Step 1: 检测操作系统类型

```bash
# 检测 OS
OS_TYPE=""
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS_TYPE="linux"
    # 检测 WSL
    if grep -qE "(Microsoft|WSL)" /proc/sys/kernel/osrelease 2>/dev/null || [[ -n "$WSL_DISTRO_NAME" ]]; then
        OS_TYPE="wsl"
    fi
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || -n "$MSYSTEM" ]]; then
    OS_TYPE="msys2"
elif [[ "$OSTYPE" == "win32" || "$OS" == "Windows_NT" ]]; then
    OS_TYPE="windows"
fi

echo "OS_TYPE: $OS_TYPE"
```

### Step 2: 检测 Host 架构

```bash
HOST_ARCH=$(uname -m)
echo "HOST_ARCH: $HOST_ARCH"  # x86_64, aarch64, arm64, etc.
```

### Step 3: 检测 Target 架构

从项目编译产物推断：

```bash
# 检查是否有 aarch64 编译产物
if ls target/aarch64*/aarch64-unknown-linux-gnu/*/obscura 2>/dev/null | head -1 | grep -q aarch64; then
    TARGET_ARCH="aarch64"
    HAS_AARCH64_BUILD=1
fi

# 检查是否有 host 架构编译产物
if ls target/*/debug/obscura 2>/dev/null | head -1 | grep -v aarch64 | grep -q .; then
    TARGET_ARCH_HOST=$(uname -m)
    HAS_HOST_BUILD=1
fi
```

### Step 4: 检测可用调试工具

```bash
# GDB 检测
HAS_GDB=0; which gdb &>/dev/null && HAS_GDB=1
HAS_GDB_MULTIARCH=0; which gdb-multiarch &>/dev/null && HAS_GDB_MULTIARCH=1
HAS_AARCH64_GDB=0; which aarch64-linux-gnu-gdb &>/dev/null && HAS_AARCH64_GDB=1

# ADB 检测（常见路径）
ADB_PATH=""
for candidate in \
    "/mnt/d/.sdk/tools/adb/linux/adb" \
    "$HOME/android-ndk"*/prebuilt/linux-x86_64/bin/adb \
    "$HOME/AppData/Local/Android/Sdk/platform-tools/adb.exe" \
    "/usr/bin/adb"; do
    if [[ -f "$candidate" ]]; then
        ADB_PATH="$candidate"
        break
    fi
done

# sysroot 检测（V8 ARM64 sysroot）
SYSROOT_PATH=""
for candidate in \
    "${PWD}/third_party/v8-137.3.0/build/linux/debian_bullseye_arm64-sysroot" \
    "/workspace/git/obscura/third_party/v8-137.3.0/build/linux/debian_bullseye_arm64-sysroot"; do
    if [[ -d "$candidate" ]]; then
        SYSROOT_PATH="$candidate"
        break
    fi
done
```

## 配置生成规则

### 规则 1: Host 本地调试（默认优先）

当 `HOST_ARCH == TARGET_ARCH` 或存在 host 编译产物时，生成本地调试配置：

**WSL/Linux**: 使用 `gdb`
**Windows**: 使用 `cppvsdbg` 或 `lldb`
**MSYS2**: 使用 `gdb`（MinGW 版本）

### 规则 2: 远程 GDB 调试（aarch64 车机）

当满足以下条件时生成：
- 存在 aarch64 编译产物
- 有 `gdb-multiarch` 或 `aarch64-linux-gnu-gdb`
- 有 ADB

### 规则 3: WSL 内嵌 Windows 路径映射

如果检测到 WSL + Windows 双环境：
- WSL 配置使用 Linux 路径
- 可选附加 Windows 配置（通过 `\\wsl$\` 路径）

## 配置模板

### 模板 A: WSL/Linux Host 本地调试

```json
{
  "name": "Local Debug (WSL/Linux)",
  "type": "cppdbg",
  "request": "launch",
  "program": "${workspaceFolder}/target/debug/obscura",
  "args": ["fetch", "https://www.baidu.com", "--dump", "text"],
  "stopAtEntry": false,
  "cwd": "${workspaceFolder}",
  "environment": [{"name": "RUST_LOG", "value": "debug"}],
  "externalConsole": false,
  "MIMode": "gdb",
  "miDebuggerPath": "/usr/bin/gdb",
  "setupCommands": [
    {"description": "Enable pretty-printing", "text": "-enable-pretty-printing", "ignoreFailures": true}
  ]
}
```

### 模板 B: WSL → 车机 aarch64 远程 GDB

```json
{
  "name": "Remote GDB (Car aarch64)",
  "type": "cppdbg",
  "request": "launch",
  "program": "${workspaceFolder}/target/aarch64/aarch64-unknown-linux-gnu/debug/obscura",
  "args": [],
  "stopAtEntry": true,
  "cwd": "${workspaceFolder}",
  "environment": [],
  "externalConsole": false,
  "MIMode": "gdb",
  "miDebuggerPath": "/usr/bin/gdb-multiarch",
  "miDebuggerServerAddress": "localhost:12345",
  "setupCommands": [
    {"description": "Enable pretty-printing", "text": "-enable-pretty-printing", "ignoreFailures": true},
    {"description": "Set sysroot for ARM64", "text": "set sysroot <SYSROOT_PATH>", "ignoreFailures": false},
    {"description": "Set solib search path", "text": "set solib-search-path ./", "ignoreFailures": true}
  ],
  "preLaunchTask": "prepare-car-debug",
  "postDebugTask": "cleanup-car-debug"
}
```

### 模板 C: MSYS2/MinGW64 本地调试

```json
{
  "name": "Local Debug (MinGW64)",
  "type": "cppdbg",
  "request": "launch",
  "program": "${workspaceFolder}/target/x86_64-pc-windows-gnu/debug/obscura.exe",
  "args": ["fetch", "https://www.baidu.com", "--dump", "text"],
  "stopAtEntry": false,
  "cwd": "${workspaceFolder}",
  "environment": [],
  "externalConsole": false,
  "MIMode": "gdb",
  "miDebuggerPath": "C:/msys64/mingw64/bin/gdb.exe",
  "setupCommands": [
    {"description": "Enable pretty-printing", "text": "-enable-pretty-printing", "ignoreFailures": true}
  ]
}
```

### 模板 D: Windows MSVC 本地调试

```json
{
  "name": "Local Debug (Windows MSVC)",
  "type": "cppvsdbg",
  "request": "launch",
  "program": "${workspaceFolder}/target/x86_64-pc-windows-msvc/debug/obscura.exe",
  "args": ["fetch", "https://www.baidu.com", "--dump", "text"],
  "stopAtEntry": false,
  "cwd": "${workspaceFolder}",
  "environment": [],
  "console": "integratedTerminal"
}
```

## tasks.json 配置

### 任务 1: build-debug

```json
{
  "label": "build-debug",
  "type": "shell",
  "command": "./_scripts/build.sh",
  "args": ["--debug"],
  "group": {"kind": "build", "isDefault": true},
  "problemMatcher": ["$rustc"]
}
```

### 任务 2: prepare-car-debug（WSL/Linux 专用）

```json
{
  "label": "prepare-car-debug",
  "type": "shell",
  "command": "./_scripts/debug.sh",
  "args": ["${input:carDevice}", "--debug", "--gdbserver-only", "${input:obscuraArgs}"],
  "problemMatcher": []
}
```

### 任务 3: cleanup-car-debug

```json
{
  "label": "cleanup-car-debug",
  "type": "shell",
  "command": "<ADB_PATH>",
  "args": ["-host", "-s", "${input:carDevice}", "shell", "pkill -f gdbserver; pkill -f obscura"],
  "presentation": {"reveal": "silent"}
}
```

### 输入变量

```json
{
  "inputs": [
    {
      "id": "carDevice",
      "type": "promptString",
      "description": "车机设备地址 (如: 30.207.82.136:61337)",
      "default": "30.207.82.136:61337"
    },
    {
      "id": "obscuraArgs",
      "type": "promptString",
      "description": "obscura 运行参数",
      "default": "fetch https://www.baidu.com --dump text"
    }
  ]
}
```

## 自动化工作流

当用户要求配置调试环境时，按以下步骤执行：

### Phase 1: 环境探测

1. 运行环境检测脚本，收集：
   - `OS_TYPE`
   - `HOST_ARCH`
   - `TARGET_ARCH`
   - 可用工具链（gdb、gdb-multiarch、adb）
   - sysroot 路径
   - 编译产物存在性

2. 输出检测结果表格：

| 项目 | 值 | 状态 |
|------|-----|------|
| 操作系统 | WSL Ubuntu 20.04 | ✅ |
| Host 架构 | x86_64 | ✅ |
| Target 架构 | aarch64 | ✅ |
| gdb-multiarch | /usr/bin/gdb-multiarch | ✅ |
| ADB | /mnt/d/.sdk/tools/adb/linux/adb | ✅ |
| ARM64 sysroot | .../debian_bullseye_arm64-sysroot | ✅ |

### Phase 2: 生成配置

1. 创建/更新 `.vscode/launch.json`
2. 创建/更新 `.vscode/tasks.json`
3. 如果文件已存在，先备份为 `.vscode/launch.json.bak.时间戳`

### Phase 3: 验证

1. 检查 JSON 语法合法性
2. 检查路径是否存在（program、miDebuggerPath、sysroot）
3. 输出可用调试配置列表

### Phase 4: 使用说明

告知用户：
1. 按 `Ctrl+Shift+D` 打开调试面板
2. 在顶部下拉框选择配置
3. 按 `F5` 启动调试

## 不同环境组合的典型输出

### 组合 1: WSL Ubuntu + aarch64 交叉编译

生成的 `launch.json` 包含：
1. `Local Debug (WSL)` — 默认，host 本地调试
2. `Remote GDB (Car aarch64)` — 车机远程调试

### 组合 2: Windows 10 + MSYS2 MinGW64

生成的 `launch.json` 包含：
1. `Local Debug (MinGW64)` — 默认
2. `Local Debug (Windows MSVC)` — 如果有 msvc 产物

### 组合 3: 原生 Linux x86_64

生成的 `launch.json` 包含：
1. `Local Debug (Linux)` — 默认

### 组合 4: WSL + 同时存在 host 和 aarch64 产物

生成的 `launch.json` 包含：
1. `Local Debug (WSL)` — 默认（host 优先）
2. `Remote GDB (Car aarch64)` — 交叉调试

## 注意事项

1. **gdb-multiarch 必须安装**：WSL/Linux 下远程调试 aarch64 需要 `sudo apt install gdb-multiarch`
2. **ADB 路径可能需要手动修正**：自动检测的 ADB 路径可能不适用于所有环境
3. **sysroot 路径**：必须指向有效的 ARM64 sysroot（如 V8 构建产物中的 `debian_bullseye_arm64-sysroot`）
4. **端口冲突**：如果 `localhost:12345` 被占用，需修改 `miDebuggerServerAddress` 和 debug.sh 中的端口
5. **首次连接车机**：需要在车机上点击"允许 USB 调试"

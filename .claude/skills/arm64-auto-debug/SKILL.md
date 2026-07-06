---
name: arm64-auto-debug
description: ARM64 车机全自动化调试流程，仅使用 debug 版本，从编译到崩溃分析完全自动化
---
# ARM64 全自动化调试 Skill

## 概述

本 Skill 提供完全自动化的 ARM64 车机远程调试流程，仅使用 debug 版本，从编译到崩溃分析无需人工干预。

## 核心原则

1. **仅使用 debug 版本**: 所有操作都针对 debug 二进制
2. **完全自动化**: 从编译到崩溃分析，无需人工干预
3. **自主决策**: 自动判断问题并采取措施
4. **完整记录**: 所有步骤和发现自动记录到日志

## 自动化流程

### 阶段 1: 编译（自动化）

```bash
# 编译 debug 版本
./_scripts/build.sh --debug
```

**自动验证**:
- 检查二进制是否存在: `target/aarch64/aarch64-unknown-linux-gnu/debug/obscura`
- 检查文件大小（应该 ~290M）

**失败处理**:
- 如果编译失败，自动分析 `build.log`
- 提取错误信息
- 生成编译失败报告

### 阶段 2: 设备连接（自动化）

```bash
# 2.1 连接设备
/mnt/d/.sdk/tools/adb/linux/adb -host connect <device_ip>:<port>

# 2.2 验证连接
STATE=$(/mnt/d/.sdk/tools/adb/linux/adb -host -s <device> get-state 2>&1)
if [[ "$STATE" != *"device"* ]]; then
    echo "错误: 连接失败 - $STATE"
    exit 1
fi
```

**自动重试**:
- 如果设备未授权，自动 kill server 并重试
- 最多重试 3 次

### 阶段 3: 部署和启动（自动化）

```bash
# 使用 debug.sh 自动化部署
./_scripts/debug.sh <device> --debug --gdbserver-only <obscura_args>
```

**关键参数**:
- `--debug`: 使用 debug 版本
- `--gdbserver-only`: 只启动 gdbserver
- `<obscura_args>`: 传给 obscura 的参数

**自动验证**:
- 检查 gdbserver 日志
- 确认 "Listening on port" 出现

### 阶段 4: GDB 自动化分析

**创建 GDB 脚本** `/tmp/gdb_auto_analyze.gdb`:

```gdb
set pagination off
set height 0
set width 0
set confirm off
set solib-search-path ./
set sysroot /workspace/git/obscura/third_party/v8-137.3.0/build/linux/debian_bullseye_arm64-sysroot
target remote localhost:12345
echo \n=== [AUTO] 开始执行 ===\n
continue
echo \n=== [AUTO] 程序已停止 ===\n
info program
echo \n=== [AUTO] 寄存器状态 ===\n
info registers
echo \n=== [AUTO] 调用栈（30层）===\n
bt 30
echo \n=== [AUTO] 线程列表 ===\n
info threads
echo \n=== [AUTO] 所有线程调用栈 ===\n
thread apply all bt 10
echo \n=== [AUTO] 分析完成 ===\n
quit
```

**运行 GDB**:

```bash
gdb-multiarch -q -x /tmp/gdb_auto_analyze.gdb \
  target/aarch64/aarch64-unknown-linux-gnu/debug/obscura \
  2>&1 | tee target/aarch64/debug_logs/gdb_auto.log
```

### 阶段 5: 自动分析

**分析逻辑**:

1. 检查是否崩溃: `grep "received signal" gdb.log`
2. 提取崩溃位置
3. 检查可疑寄存器值:
   - `0x8080808080808080`: 未初始化内存
   - `0xdeadbeef`: Use-after-free
4. 提取调用栈
5. 判断崩溃类型（V8、快照、GC、JIT）

**生成报告**:

自动生成 `target/aarch64/debug_logs/ANALYSIS_REPORT.md`，包含：
- 执行摘要
- 崩溃详情
- 调用栈
- 寄存器状态
- 可疑模式
- 根本原因推测
- 修复建议

## 使用方法

### 一键执行（推荐）

```bash
# 使用默认目录 (./target/aarch64)
./_scripts/auto_debug.sh 30.207.82.136:61385 "fetch https://www.baidu.com --dump text"

# 指定自定义目录
./_scripts/auto_debug.sh 30.207.82.136:61385 --target-dir ./target2 "fetch https://www.baidu.com --dump text"
```

### 分步执行

```bash
# 1. 编译（使用默认目录）
./_scripts/build.sh --debug

# 或使用自定义目录
./_scripts/build.sh --debug --target-dir ./target2

# 2. 部署并启动 gdbserver
./_scripts/debug.sh 30.207.82.136:61385 --debug --gdbserver-only fetch https://www.baidu.com

# 或使用自定义目录
./_scripts/debug.sh 30.207.82.136:61385 --debug --target-dir ./target2 --gdbserver-only fetch https://www.baidu.com

# 3. GDB 分析
gdb-multiarch -q -x /tmp/gdb_auto.gdb \
  target/aarch64/aarch64-unknown-linux-gnu/debug/obscura
```

## 故障处理

### 编译失败

```bash
tail -50 target/aarch64/debug_logs/build_*.log
grep -i error target/aarch64/debug_logs/build_*.log
```

### 设备连接失败

```bash
# 检查设备状态
adb devices

# 重新连接
adb kill-server
adb connect <device>
```

### gdbserver 启动失败

```bash
# 检查端口占用
adb shell "netstat -tlnp | grep 12345"

# 检查二进制
adb shell "ls -l /data/obscura"
```

### GDB 超时

```bash
# 增加超时时间（修改 auto_debug.sh）
timeout 60 gdb-multiarch ...

# 检查程序是否死锁
adb shell "ps -ef | grep obscura"
```

## 日志文件

所有日志保存在 `${TARGET_DIR}/debug_logs/` 目录（默认 `target/aarch64/debug_logs/`）：

- `build_*.log` - 编译日志
- `debug_*.log` - 调试会话日志
- `gdbserver_*.log` - gdbserver 日志
- `gdb_auto_*.log` - GDB 自动化输出
- `ANALYSIS_REPORT_*.md` - 自动分析报告

**注意**: 使用 `--target-dir` 参数可以自定义日志输出目录。

## 相关文件

- `auto_debug.sh` - 全自动化脚本
- `debug.sh` - 调试脚本（支持 --debug）
- `build.sh` - 编译脚本
- `docs/skills/ARM64_AUTO_DEBUG.md` - 详细文档

## 注意事项

1. 首次连接设备需要在车机上点击"允许 USB 调试"
2. 编译 debug 版本需要约 55 分钟
3. 确保设备有足够的存储空间（~300M）
4. 确保 gdbserver 已安装在设备上

## 示例

### 示例 1: 完全自动化调试（默认目录）

```bash
./_scripts/auto_debug.sh 30.207.82.136:61385 "fetch https://www.baidu.com --dump text"
```

### 示例 2: 指定自定义目录

```bash
./_scripts/auto_debug.sh 30.207.82.136:61385 --target-dir ./target2 "fetch https://example.com --dump html --output page.html"
```

### 示例 3: 使用不同设备

```bash
./_scripts/auto_debug.sh 192.168.1.100:5555 "fetch https://test.com"
```
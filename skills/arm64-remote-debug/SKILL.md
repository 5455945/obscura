---
name: arm64-remote-debug
description: ARM64 车机手动远程调试流程，支持交互式 GDB 调试和详细分析
---
# ARM64 手动远程调试 Skill

## 概述

本 Skill 提供手动的 ARM64 车机远程调试流程，适用于需要交互式调试和详细分析的复杂问题。

## 适用场景

- 需要交互式 GDB 调试
- 复杂的崩溃问题分析
- 需要设置断点和单步调试
- 需要检查内存和变量
- 自动化调试无法解决的问题

## 阶段 1: 环境准备

### 1.1 编译 debug 版本

```bash

# 编译
./_scripts/build.sh --debug
```

**验证**:
```bash
ls -lh target/aarch64/aarch64-unknown-linux-gnu/debug/obscura
```

### 1.2 检查设备连接

```bash
# 连接设备
/mnt/d/.sdk/tools/adb/linux/adb -host connect <device>

# 验证
/mnt/d/.sdk/tools/adb/linux/adb -host -s <device> get-state
```

## 阶段 2: 部署并启动 GDBServer

### 2.1 推送二进制

```bash
# 使用 debug.sh（推荐，默认目录）
./_scripts/debug.sh <device> --debug --gdbserver-only <args>

# 使用自定义目录
./_scripts/debug.sh <device> --debug --target-dir ./target2 --gdbserver-only <args>

# 或手动推送
/mnt/d/.sdk/tools/adb/linux/adb -host -s <device> push \
  target/aarch64/aarch64-unknown-linux-gnu/debug/obscura /data/obscura
/mnt/d/.sdk/tools/adb/linux/adb -host -s <device> shell chmod +x /data/obscura
```

### 2.2 启动 GDBServer

```bash
# 清理旧进程
/mnt/d/.sdk/tools/adb/linux/adb -host -s <device> shell \
  "pkill -f gdbserver; pkill -f obscura"

# 启动 gdbserver（默认目录）
/mnt/d/.sdk/tools/adb/linux/adb -host -s <device> shell \
  "/usr/bin/gdbserver :12345 /data/obscura <args>" > target/aarch64/debug_logs/gdbserver.log 2>&1 &

# 或使用自定义目录
/mnt/d/.sdk/tools/adb/linux/adb -host -s <device> shell \
  "/usr/bin/gdbserver :12345 /data/obscura <args>" > ${TARGET_DIR}/debug_logs/gdbserver.log 2>&1 &

# 验证
tail -f target/aarch64/debug_logs/gdbserver.log
```

**预期输出**:
```
Process /data/obscura created; pid = XXXXX
Listening on port 12345
```

### 2.3 设置端口转发

```bash
/mnt/d/.sdk/tools/adb/linux/adb -host -s <device> forward tcp:12345 tcp:12345
```

## 阶段 3: GDB 调试

### 3.1 创建 GDB 初始化脚本

**文件**: `/tmp/gdb_init.gdb`

```gdb
set pagination off
set height 0
set width 0
set solib-search-path ./
set sysroot /workspace/git/obscura/third_party/v8-137.3.0/build/linux/debian_bullseye_arm64-sysroot
target remote localhost:12345
```

### 3.2 启动交互式 GDB

**方式 A: 使用 tmux（推荐）**

```bash
# 启动 tmux 会话
tmux new-session -d -s obscura-gdb \
  "gdb-multiarch -q -x /tmp/gdb_init.gdb \
   target/aarch64/aarch64-unknown-linux-gnu/debug/obscura"

# 连接到会话
tmux attach -t obscura-gdb
```

**方式 B: 直接运行**

```bash
gdb-multiarch -q -x /tmp/gdb_init.gdb \
  target/aarch64/aarch64-unknown-linux-gnu/debug/obscura
```

### 3.3 常用 GDB 命令

**执行控制**:
```gdb
continue          # 继续执行
step              # 单步进入
next              # 单步跳过
finish            # 执行到当前函数返回
interrupt         # 中断执行
```

**信息查看**:
```gdb
bt [full]         # 调用栈
info reg          # 寄存器
info threads      # 线程列表
thread <n>        # 切换线程
info locals       # 局部变量
print <expr>      # 打印表达式
```

**断点**:
```gdb
break <function>     # 函数断点
break <file>:<line>  # 行号断点
info breakpoints     # 列出断点
delete <n>           # 删除断点
```

**内存检查**:
```gdb
x/10xw <addr>        # 检查内存（10个字，十六进制）
info proc mappings   # 内存映射
```

**高级调试**:
```gdb
watch <var>          # 设置观察点
catch <event>        # 设置捕获点
display <expr>       # 每次停止时显示表达式
undisplay <n>        # 取消显示
```

## 阶段 4: 崩溃分析

### 4.1 识别崩溃类型

**常见信号**:
- `SIGSEGV`: 段错误（内存访问违规）
- `SIGABRT`: 主动中止（assert 失败）
- `SIGBUS`: 总线错误（对齐问题）
- `SIGFPE`: 浮点异常

### 4.2 收集崩溃信息

**必须收集**:

```gdb
# 1. 调用栈（最重要）
bt full

# 2. 寄存器状态
info reg

# 3. 线程信息
info threads
thread apply all bt

# 4. 内存映射
info proc mappings

# 5. 当前帧信息
info frame
info locals
info args

# 6. 反汇编
x/20i $pc
```

### 4.3 分析模式

#### 模式 1: 空指针解引用

**特征**:
- `pc` 指向小地址（如 `0x0`, `0x8`, `0x10`）
- 或者访问的地址接近 0

**分析步骤**:
```gdb
# 查看调用栈，找到哪个指针为 NULL
bt full

# 查看相关变量
print <pointer_var>

# 查看结构体成员
print *<struct_ptr>
```

#### 模式 2: 未初始化内存

**特征**:
- 寄存器包含特殊模式值
- 常见模式:
  - `0x8080808080808080` (未初始化栈)
  - `0xdeadbeef` (已释放内存)
  - `0xcccccccccccccccc` (未初始化堆)

**分析步骤**:
```gdb
# 查看寄存器
info reg

# 追溯指针来源
bt full

# 检查内存
x/10xw <address>
```

#### 模式 3: 栈溢出

**特征**:
- `sp` 超出正常范围
- 调用栈非常深（>100 层）
- 递归调用模式

**分析步骤**:
```gdb
# 查看栈指针
info reg sp

# 查看调用栈深度
bt

# 查找递归模式
bt | grep "same_function"
```

#### 模式 4: Use-After-Free

**特征**:
- 访问已释放的内存
- 寄存器包含 `0xdeadbeef` 或类似模式
- 崩溃在看似正常的代码位置

**分析步骤**:
```gdb
# 查看崩溃地址
info reg

# 检查内存内容
x/10xw <crash_address>

# 查看对象历史
bt full

# 设置观察点追踪变量
watch <variable>
```

### 4.4 V8 特定崩溃分析

**常见 V8 崩溃位置**:

1. **快照反序列化**
   ```
   v8::internal::ReadOnlyDeserializer::DeserializeIntoIsolate()
   v8::internal::Snapshot::Initialize()
   ```
   **原因**: 快照损坏或配置不匹配
   **解决**: 检查 `GN_ARGS` 中的快照配置

2. **垃圾回收**
   ```
   v8::internal::Heap::CollectGarbage()
   v8::internal::Scavenger::Process()
   ```
   **原因**: 堆损坏或 GC bug
   **解决**: 检查对象生命周期

3. **JIT 编译**
   ```
   v8::internal::compiler::PipelineImpl::Run()
   ```
   **原因**: JIT 编译器 bug
   **解决**: 禁用 JIT 或更新 V8

4. **JavaScript 执行**
   ```
   v8::internal::Execution::Call()
   v8::Function::Call()
   ```
   **原因**: JavaScript 代码错误
   **分析**: 检查 JS 代码和绑定

## 阶段 5: 文档化

### 5.1 保存 GDB 会话

```gdb
# 设置日志
set logging file target/aarch64/debug_logs/gdb_session.log
set logging on

# 执行调试命令
bt full
info reg
...

# 关闭日志
set logging off
```

### 5.2 创建分析报告

**模板**:

```markdown
# [程序名] 崩溃分析报告

**日期**: YYYY-MM-DD
**设备**: <device_info>
**二进制**: <binary_path>

## 执行摘要

**结论**: [一句话总结]
**根本原因**: [根本原因]

## 崩溃详情

### 1. 崩溃信号
[信号和位置]

### 2. 关键寄存器
[寄存器值和分析]

### 3. 完整调用栈
[调用栈]

## 根因分析

### 问题定位
[详细的分析过程]

### 可能的根本原因
[列举可能的原因]

## 解决方案建议
[具体的修复建议]
```

## 故障排查

### 问题 1: GDB 无法连接

**症状**: `Connection refused` 或超时

**排查**:
```bash
# 检查 gdbserver 是否运行
adb shell "ps -ef | grep gdbserver"

# 检查端口转发
adb forward --list

# 检查防火墙
sudo iptables -L
```

### 问题 2: 没有调试符号

**症状**: `(No debugging symbols found)`

**解决**:
```bash
# 确认使用 debug 版本
file target/aarch64/aarch64-unknown-linux-gnu/debug/obscura

# 重新编译
./_scripts/build.sh --debug clean
./_scripts/build.sh --debug
```

### 问题 3: 共享库加载失败

**症状**: `warning: unable to open ...`

**解决**:
```gdb
# 设置正确的 sysroot
set sysroot /workspace/git/obscura/third_party/v8-137.3.0/build/linux/debian_bullseye_arm64-sysroot

# 检查库搜索路径
set solib-search-path ./

# 查看库加载状态
info sharedlibrary
```

### 问题 4: GDB 命令无响应

**症状**: GDB 挂起

**解决**:
```gdb
# 中断执行
interrupt

# 或强制退出
quit
```

## 最佳实践

### 1. 总是使用 Debug 版本

- Debug 版本包含完整符号信息
- 便于定位问题
- 性能影响在调试时可以接受

### 2. 保留所有日志

- 编译日志
- GDB 输出
- GDBServer 日志
- 设备日志

### 3. 系统化分析

- 先收集信息，再分析
- 从调用栈开始
- 逐步缩小范围

### 4. 记录所有发现

- 即使是不相关的观察
- 即使最终证明是错误的假设
- 便于后续回顾和学习

## 相关资源

### 内部文档

- `auto_debug.sh` - 自动化调试脚本
- `debug.sh` - 调试脚本
- `build.sh` - 编译脚本
- `docs/skills/ARM64_AUTO_DEBUG.md` - 自动化 Skill

### 外部资源

- [GDB 文档](https://sourceware.org/gdb/documentation/)
- [V8 文档](https://v8.dev/docs)
- [ARM64 调试指南](https://developer.arm.com/documentation/)

## 示例

### 示例 1: 完整的调试会话（默认目录）

```bash
# 1. 编译
./_scripts/build.sh --debug

# 2. 启动 gdbserver
./_scripts/debug.sh 30.207.82.136:61385 --debug --gdbserver-only fetch https://www.baidu.com

# 3. 连接 GDB
tmux new-session -s debug "gdb-multiarch -q target/aarch64/aarch64-unknown-linux-gnu/debug/obscura"

# 4. 在 GDB 中
(gdb) target remote localhost:12345
(gdb) break main
(gdb) continue
(gdb) step
(gdb) print variable
(gdb) bt full
```

### 示例 2: 使用自定义目录

```bash
# 1. 编译到自定义目录
./_scripts/build.sh --debug --target-dir ./target2

# 2. 启动 gdbserver（使用自定义目录）
./_scripts/debug.sh 30.207.82.136:61385 --debug --target-dir ./target2 --gdbserver-only fetch https://www.baidu.com

# 3. 连接 GDB
tmux new-session -s debug "gdb-multiarch -q ./target2/aarch64-unknown-linux-gnu/debug/obscura"

# 4. 在 GDB 中
(gdb) target remote localhost:12345
(gdb) continue
```

### 示例 2: 分析崩溃

```bash
# 启动 GDB
gdb-multiarch -q target/aarch64/aarch64-unknown-linux-gnu/debug/obscura

# 在 GDB 中
(gdb) target remote localhost:12345
(gdb) continue
# 程序崩溃
(gdb) bt full
(gdb) info reg
(gdb) info threads
(gdb) thread 1
(gdb) frame 0
(gdb) info locals
(gdb) x/10i $pc
```

---
name: cross-debug
description: Obscura aarch64 交叉调试 skill。当用户提供车机 ADB 连接信息（如 `30.207.92.65:61104`）并要求调试 obscura 崩溃时使用。自动完成：连接设备 → 推送二进制 → 启动 gdbserver → gdb 连接 → 崩溃分析 → 给出 patch。不修改代码，只输出分析和 patch 文件。
---

# Obscura 交叉调试（WSL x86_64 → 车机 aarch64）

## 何时触发

用户提供车机 ADB 地址（格式 `IP:PORT`），并要求调试 obscura 崩溃、分析 SIGSEGV、排查运行时问题。

## 前置条件

- `debug.sh` 在项目根目录且可执行
- `target/aarch64/aarch64-unknown-linux-gnu/release/obscura` 存在（已编译）
- `gdb-multiarch` 已安装（`sudo apt install gdb-multiarch`）
- ADB 可用：`/mnt/d/.sdk/tools/adb/linux/adb`

## 调试工作流

### Phase 1：连接 & 推送

```bash
# 推送二进制到车机
./_scripts/debug.sh <DEVICE> --push-only
```

如果用户指定了 obscura 运行参数（如 `fetch URL --dump text`），在 Phase 3 使用。

### Phase 2：启动 gdbserver & 连接 gdb

**方式 A：gdbserver-only（推荐，手动控制 gdb）**

```bash
./_scripts/debug.sh <DEVICE> --gdbserver-only --no-push [obscura参数...]
```

然后在另一个终端连接：

```bash
gdb-multiarch target/aarch64/aarch64-unknown-linux-gnu/release/obscura \
  -ex "set sysroot third_party/v8-137.3.0/build/linux/debian_bullseye_arm64-sysroot" \
  -ex "target remote localhost:12345"
```

**方式 B：自动连接**

```bash
./_scripts/debug.sh <DEVICE> --no-push [obscura参数...]
```

### Phase 3：GDB 调试命令速查

```gdb
# 基本信息
bt              # 调用栈
bt full         # 完整调用栈（含局部变量）
info reg        # 寄存器
info threads    # 所有线程
thread N        # 切换线程

# 内存检查
x/10gx $sp      # 栈顶 10 个 64 位值
x/20gx $x0      # x0 指向的内存
x/s $x0         # x0 指向的字符串
p *(type*)$x0   # 按类型解读内存

# 断点
b main
b v8::Isolate::New
b 'filename:line'
b *0xADDRESS
info breakpoints
delete N

# 执行
c               # continue
ni              # next instruction（单条指令，不过函数）
si              # step instruction（单条指令，进函数）
fin             # 运行到当前函数返回

# 崩溃后
bt              # 看崩溃调用栈
info reg        # 看寄存器值
# 重点关注：x0-x7（参数）、x29(fp)、x30(lr)、sp、pc
```

### Phase 4：崩溃分析模式

#### 模式 1：SIGSEGV in V8 SizeFromMap / snapshot 反序列化

**特征**：
- 崩溃在 `v8::internal::HeapObject::SizeFromMap`
- 调用链包含 `ReadOnlyDeserializer`、`Snapshot::Initialize`
- 寄存器中出现 `0x8080808080808080` 或 `0xCCCCCCCCCCCCCCCC`

**分析步骤**：
```gdb
bt                              # 确认崩溃链路
info reg                        # 查看哪个寄存器包含毒化值
x/10gx $pc                      # 看崩溃点附近的指令
p/x *(void**)$x1                # 检查疑似 Map 指针
```

**根因判断**：
- 如果 `0x80808080...` → 未初始化内存（OS 内核填充），快照反序列化未正确写入 Map 指针
- 如果 `0xCCCCCCCC...` → V8 的 zap 值（debug 模式），可能是编译配置问题
- 检查 `v8_enable_pointer_compression` 和 `v8_enable_sandbox` 是否在 HOST/TARGET 间一致

**验证**：
```bash
# 检查 GN args 一致性
cat target/aarch64/aarch64-unknown-linux-gnu/release/gn_out/args.gn
cat target/aarch64/release/gn_out/args.gn
# 对比两者是否一致（尤其 pointer_compression、sandbox、target_cpu）
```

**解决方案**：
- 如果是快照问题 → `GN_ARGS` 中加 `v8_enable_snapshot=false`，然后 `./_scripts/build.sh clean --release`
- 如果是 pointer_compression 不一致 → 统一设置 `v8_enable_pointer_compression=false`

#### 模式 2：SIGSEGV in V8 JIT 代码

**特征**：
- 崩溃地址在 V8 的代码空间（通常 `0x3axxxxxxxx` 范围）
- pc 不在任何已知函数中

**分析步骤**：
```gdb
info reg                        # 记录 pc 值
bt                              # 看调用栈（通常有 JIT 帧）
# 查看附近的内存
x/20i $pc-32                    # 反汇编崩溃点附近
x/20i $pc                       # 反汇编崩溃点开始
```

**根因判断**：
- JIT 代码崩溃通常是 V8 的编译器 bug 或内存损坏
- 检查是否在特定 JS 代码触发

**解决方案**：
- 尝试 `--v8-flags="--no-opt"` 禁用优化
- 或 `--v8-flags="--jitless"` 禁用 JIT

#### 模式 3：SIGSEGV in Rust 代码

**特征**：
- 崩溃在 Rust 函数中（函数名含 `::`、`h` 后缀）
- 通常是空指针解引用或越界访问

**分析步骤**：
```gdb
bt full                         # 完整调用栈
info reg                        # 寄存器
# 找到第一个 Rust 帧
frame N                         # 切换到 Rust 帧
info locals                     # 局部变量
info args                       # 函数参数
```

**解决方案**：
- 根据具体函数和参数分析
- 通常需要添加 null check 或 bounds check

#### 模式 4：动态库加载失败

**特征**：
- 崩溃在 `ld-linux-aarch64.so` 或 `_dl_*` 函数中
- 或启动时就崩溃，没有任何有意义的栈

**分析步骤**：
```bash
# 在车机上检查
adb -host -s <DEVICE> shell "ldd /data/obscura"
adb -host -s <DEVICE> shell "readelf -d /data/obscura | grep NEEDED"
```

**解决方案**：
- 检查缺少的动态库
- 使用 `--sysroot` 链接或静态链接缺失库

### Phase 5：生成分析报告 & Patch

分析完成后，输出以下内容：

#### 分析报告模板

```markdown
## 崩溃分析报告

### 环境
- 设备：<DEVICE>
- 二进制：release / debug
- 崩溃命令：`obscura <args>`

### 崩溃信息
- 信号：SIGSEGV / SIGABRT / ...
- 崩溃地址：0x...
- 崩溃函数：`function_name`
- 崩溃文件：`file:line`

### 调用栈
（关键帧，省略重复的 worker 线程）

### 寄存器状态
（关键寄存器，尤其是参数寄存器和 pc/sp/lr）

### 根因分析
（详细的根因推理过程）

### 解决方案
（具体方案，可能是配置修改、GN args 调整等）

### Patch（如需要）
（统一 diff 格式的 patch，不直接修改文件）
```

#### Patch 格式

```diff
--- a/path/to/file
+++ b/path/to/file
@@ -line,count +line,count @@
 context line
-removed line
+added line
 context line
```

将 patch 保存为 `patches/fix-<description>.patch`，用 `git apply` 或 `patch -p1` 应用。

## 常见陷阱

1. **不要直接修改源码** — 只输出 patch 文件
2. **GN_ARGS 拼写** — 必须是 `GN_ARGS=`，不是 `GN_ARG=`
3. **clean 后才生效** — 修改 GN_ARGS 后必须 `./_scripts/build.sh clean --release`
4. **debug 和 release 行为不同** — debug 有更多检查，某些崩溃只在 release 出现
5. **gdbserver 后台问题** — 使用 `./_scripts/debug.sh` 的本地后台方式启动
6. **sysroot 加速** — gdb 中 `set sysroot <path>` 可加速库加载

## 关键文件路径

| 文件 | 用途 |
|------|------|
| `debug.sh` | 交叉调试脚本 |
| `build.sh` | 编译脚本（含 clean 功能） |
| `third_party/v8-137.3.0/build.rs` | V8 编译配置（GN args） |
| `target/aarch64/aarch64-unknown-linux-gnu/release/gn_out/args.gn` | 实际使用的 GN 配置 |
| `target/aarch64/aarch64-unknown-linux-gnu/debug/gn_out/args.gn` | debug 的 GN 配置 |
| `third_party/v8-137.3.0/build/linux/debian_bullseye_arm64-sysroot/` | aarch64 sysroot（gdb 加速用） |
| `build.log` | 编译日志 |
| `debug_logs/` | 调试日志目录 |

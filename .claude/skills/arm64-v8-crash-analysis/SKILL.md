---
name: arm64-v8-crash-analysis
description: ARM64 上 V8 引擎崩溃的深度分析方法论。当 obscura 在 ARM64 车机上崩溃（尤其是 V8 初始化、快照加载、GC、JIT 相关崩溃）时使用。提供三层递进式 GDB 断点分析、Map 对象验证、指针压缩诊断和交叉编译配置排查等系统化方法。
---

# ARM64 V8 崩溃深度分析 Skill

## 适用场景

当出现以下情况时使用本 Skill：

- obscura 在 ARM64 车机上运行时崩溃（SIGSEGV / SIGABRT / SIGBUS）
- 崩溃调用栈中包含 `v8::internal::*` 函数
- 崩溃发生在 V8 Isolate 初始化、快照反序列化、GC 或 JIT 阶段
- 初步 GDB 分析无法定位根本原因，需要更深层的内存和指针分析
- 怀疑交叉编译配置（指针压缩、快照、sysroot）有问题

## 核心方法论

本 Skill 采用**三层递进式分析**：每一层基于上一层的发现，逐步缩小问题范围。

```
第一层：基础崩溃信息收集（无断点）
    ↓
第二层：关键函数入口断点（设置少量断点）
    ↓
第三层：寄存器+内存级精细分析（针对性断点）
```

**原则**：不要试图一次写完所有 GDB 命令。每一层的发现会决定下一层在哪里设置断点。

---

## 第一层：基础崩溃信息收集

**目标**：不加断点，让程序自然崩溃，收集基础信息。

### 1.1 创建 GDB 脚本

```gdb
# /tmp/gdb_pass1.gdb
set pagination off
set height 0
set width 0
set confirm off
set solib-search-path ./
set sysroot ${SYSROOT}
target remote localhost:12345
echo \n=== [PASS-1] 开始执行 ===\n
continue
echo \n=== [PASS-1] 程序已停止 ===\n
info program
echo \n=== [PASS-1] 寄存器状态 ===\n
info registers
echo \n=== [PASS-1] 调用栈（30层）===\n
bt 30
echo \n=== [PASS-1] 线程列表 ===\n
info threads
echo \n=== [PASS-1] 所有线程调用栈 ===\n
thread apply all bt 10
echo \n=== [PASS-1] 分析完成 ===\n
quit
```

**SYSROOT 路径**：
```
${OBSCURA_DIR}/third_party/v8-137.3.0/build/linux/debian_bullseye_arm64-sysroot
```

### 1.2 运行

```bash
gdb-multiarch -q -x /tmp/gdb_pass1.gdb \
  target/aarch64/aarch64-unknown-linux-gnu/debug/obscura \
  2>&1 | tee target/aarch64/debug_logs/gdb_pass1_$(date +%Y%m%d_%H%M%S).log
```

### 1.3 第一层分析清单

从第一层输出中，提取以下关键信息：

| 检查项 | 如何提取 | 判断标准 |
|--------|---------|---------|
| 崩溃信号 | `grep "received signal" gdb.log` | SIGSEGV / SIGABRT / ... |
| 崩溃函数 | 调用栈第 0 帧 | 是否在 `v8::internal::*` |
| 可疑寄存器 | `info registers` | 见下方模式表 |
| 崩溃阶段 | 调用栈整体分析 | 初始化 / 运行时 / 关闭 |

### 1.4 可疑寄存器模式

| 值 | 含义 | 诊断方向 |
|----|------|---------|
| `0x8080808080808080` | 未初始化栈内存 | 变量未初始化 |
| `0xdeadbeef*` | 已释放内存 | Use-after-free |
| `0xcccccccccccccccc` | 未初始化堆 | 对象构造不完整 |
| `0x0000000000000000` | NULL 指针 | 空指针解引用 |
| **不在预期范围内的地址** | 指针解析错误 | 指针压缩/重定位问题 |

### 1.5 V8 崩溃阶段识别

根据调用栈判断崩溃发生在哪个阶段：

```
Isolate 初始化阶段:
  v8::Isolate::New()
  → v8::internal::Snapshot::Initialize()
  → v8::internal::ReadOnlyHeap::SetUp()
  → v8::internal::ReadOnlyDeserializer::*

GC 阶段:
  v8::internal::Heap::CollectGarbage()
  v8::internal::Scavenger::Process()

JIT 编译阶段:
  v8::internal::compiler::PipelineImpl::Run()

JavaScript 执行阶段:
  v8::internal::Execution::Call()
  v8::Function::Call()
```

---

## 第二层：关键函数入口断点

**触发条件**：第一层发现崩溃在 V8 内部，但无法确定具体原因。

**目标**：在崩溃路径上的关键函数设置断点，检查函数入口时的状态。

### 2.1 确定断点位置

根据第一层的调用栈，从下往上选择 2-3 个关键函数：

**Isolate 初始化崩溃的常用断点**：
```gdb
break v8::internal::ReadOnlyHeap::SetUp
break v8::internal::ReadOnlyDeserializer::DeserializeIntoIsolate
break v8::internal::ReadOnlySpace::FinalizeSpaceForDeserialization
break v8::internal::ReadOnlyPageMetadata::ShrinkToHighWaterMark
break v8::internal::HeapObject::SizeFromMap
```

**GC 崩溃的常用断点**：
```gdb
break v8::internal::Heap::CollectGarbage
break v8::internal::Scavenger::Process
```

### 2.2 创建 GDB 脚本

```gdb
# /tmp/gdb_pass2.gdb
set pagination off
set height 0
set width 0
set confirm off
set solib-search-path ./
set sysroot ${SYSROOT}

# 按调用顺序设置断点（从外到内）
break <函数1>
break <函数2>
break <函数3>

target remote localhost:12345
continue

echo \n=== [PASS-2] 断点命中 ===\n
info frame
bt 5
info registers

# 检查 this 指针（如果存在）
print/x $x19
x/20xw $x19

continue
echo \n=== [PASS-2] 下一个断点 ===\n
info frame
bt 5
info registers
quit
```

### 2.3 第二层分析要点

- 比较断点命中顺序与预期是否一致
- 检查每个断点处的寄存器状态是否合理
- 特别注意指针值是否在预期地址范围内

---

## 第三层：寄存器+内存级精细分析

**触发条件**：第二层发现了异常指针或可疑内存，需要精确定位。

**目标**：检查具体的内存内容、对象布局和指针解析。

### 3.1 V8 Map 对象验证（最常用）

V8 中每个 HeapObject 的第一个字是指向 Map 的指针。Map 决定了对象的类型和大小。

**验证步骤**：

```gdb
# 1. 获取对象地址（通常在 x19 或通过 this 指针）
set $obj = $x19

# 2. 读取对象内存（前 10 个字）
x/10xw $obj

# 3. 读取 Map 指针（对象的第一个字，可能被压缩）
set $map_raw = *($obj)
print/x $map_raw

# 4. 读取 Map 内存
x/20xw $map_raw

# 5. 读取 instance_type（Map 偏移 +4 字节，低 8 位）
set $itype = *($map_raw + 4) & 0xFF
printf "Instance type: %d (0x%x)\n", $itype, $itype

# 6. 验证 instance_type 是否有效
# 有效的 instance_type 通常在 1-200 范围内
# 如果为 0 或非常大，说明 Map 指针无效
```

### 3.2 ReadOnly 空间地址范围验证

V8 的 ReadOnly 堆对象（包括 Map）应该在一个特定的地址范围内。

**检查方法**：

```gdb
# 获取 Isolate 的 ReadOnly 空间
set $iso = v8::internal::Isolate::Current()
print $iso->read_only_space()

# 或者通过已知的有效对象推断范围
# 如果多次观察到 Map 地址在 0x3fdfxxxxxxxx 范围
# 那么新的 Map 地址也应该在这个范围附近
```

**判断标准**：
- ✅ Map 地址在 ReadOnly 空间范围内
- ❌ Map 地址偏离预期范围 > 100MB → 指针解析问题

### 3.3 指针压缩诊断

ARM64 上 V8 默认启用指针压缩。如果怀疑指针压缩导致问题：

**症状**：
- 对象内存中的 Map 指针 与 CPU 寄存器中的 Map 指针**不同**
- Map 地址不在 ReadOnly 空间范围内
- `instance_type` 为 0 或异常值

**诊断方法**：

```gdb
# 1. 读取对象内存中的压缩 Map（32 位）
set $obj = $x19
set $compressed = *(unsigned int*)($obj)
printf "压缩 Map (32 位): 0x%x\n", $compressed

# 2. 读取寄存器中的 Map（64 位，已解压缩）
set $decompressed = $x1
printf "解压缩 Map (64 位): %p\n", $decompressed

# 3. 如果两者不一致，说明解压缩过程有问题
# 检查 V8 的指针压缩 cage base
print v8::internal::PtrComprCageBase::base()
```

**修复方向**：
- 在 `build.sh` 中设置 `v8_enable_pointer_compression=false`
- 或检查交叉编译环境的 cage base 配置

### 3.4 内存模式扫描

扫描对象内存，检测特殊填充模式：

```gdb
set $addr = <起始地址>
set $i = 0
set $found = 0
while $i < 20
  set $val = *($addr + $i * 4)
  if $val == 0x80808080
    printf "⚠️ 0x80808080 (未初始化) 在偏移 %d\n", $i * 4
    set $found = 1
  end
  if $val == 0xdeadbeef
    printf "⚠️ 0xdeadbeef (已释放) 在偏移 %d\n", $i * 4
    set $found = 1
  end
  set $i = $i + 1
end
if $found == 0
  echo "✅ 未发现明显的内存填充模式\n"
end
```

---

## V8 编译配置排查

当崩溃与 V8 编译配置相关时，按以下顺序排查：

### 检查 GN_ARGS

```bash
# 查看当前编译使用的 GN_ARGS
grep "GN_ARGS:" target/aarch64/build.log

# 或查看 build.sh 中的配置
grep -A 10 "GN_ARGS=" build.sh
```

### 关键配置项

| 配置项 | 说明 | ARM64 默认值 | 建议 |
|--------|------|-------------|------|
| `v8_enable_pointer_compression` | 指针压缩 | **true** (ARM64) | 交叉编译问题时设 false |
| `v8_enable_fast_mksnapshot` | 快速快照生成 | false (debug) | 保持 false |
| `v8_enable_backtrace` | 启用回溯 | true (debug) | 保持 true |
| `dcheck_always_on` | 启用 DCHECK | true (debug) | 保持 true |
| `v8_enable_snapshot` | 启用快照 | true | 检查快照是否匹配架构 |
| `use_sysroot` | 使用 sysroot | true | 必须为 true |

### 重新生成快照

```bash
# 完全清理 V8 缓存
./_scripts/build.sh --debug clean
rm -rf third_party/v8-137.3.0/out/
rm -f third_party/v8-137.3.0/snapshot_blob.bin

# 验证 mksnapshot 架构（应为 ARM64）
file third_party/v8-137.3.0/mksnapshot

# 重新编译
./_scripts/build.sh --debug
```

### 禁用指针压缩

```bash
# 在 build.sh 的 GN_ARGS 中添加
export GN_ARGS="... v8_enable_pointer_compression=false ..."

# 重新编译
./_scripts/build.sh --debug clean
./_scripts/build.sh --debug
```

---

## 分析报告模板

每次分析完成后，生成结构化报告：

```markdown
# [崩溃类型] 分析报告

**日期**: YYYY-MM-DD
**设备**: <device>
**二进制**: debug / release
**测试命令**: <command>

## 执行摘要

**崩溃信号**: SIGSEGV / SIGABRT / ...
**崩溃位置**: <函数名>
**崩溃阶段**: Isolate 初始化 / GC / JIT / JS 执行
**根本原因**: [一句话]

## 第一层发现

### 调用栈
[关键帧]

### 可疑寄存器
[寄存器值和分析]

## 第二层发现（如有）

### 断点命中顺序
[断点和状态]

## 第三层发现（如有）

### Map 验证
[Map 地址、instance_type、有效性]

### 内存模式
[扫描结果]

## 根本原因

[详细分析]

## 修复建议

[具体步骤]
```

---

## 常见崩溃模式速查

### 模式 1: SizeFromMap 崩溃 + Map 地址不在 ReadOnly 空间

```
调用栈: HeapObject::SizeFromMap() ← ReadOnlyPageMetadata::ShrinkToHighWaterMark()
Map 地址: 偏离 ReadOnly 空间范围
Instance type: 0
```

**诊断**: 指针压缩解压缩错误  
**修复**: `v8_enable_pointer_compression=false` 或重新生成快照

### 模式 2: SizeFromMap 崩溃 + x1 = 0x8080808080808080

```
调用栈: HeapObject::SizeFromMap() ← ReadOnlyPageObjectIterator::Next()
x1 = 0x8080808080808080
```

**诊断**: 读取了未初始化的 Map 指针  
**修复**: 快照损坏，重新生成快照

### 模式 3: Isolate::Init 崩溃

```
调用栈: Isolate::Init() → Snapshot::Initialize()
```

**诊断**: 快照与当前 V8 版本不匹配  
**修复**: 清理 V8 缓存，重新编译

### 模式 4: CollectGarbage 崩溃

```
调用栈: Heap::CollectGarbage() → Scavenger::Process()
```

**诊断**: 堆对象损坏  
**修复**: 检查对象生命周期，启用 V8 checks (`v8_enable_v8_checks=true`)

---

## gdbserver 快速重启

分析过程中需要多次重启 gdbserver：

```bash
# 1. 清理设备和端口
/mnt/d/.sdk/tools/adb/linux/adb -host -s <device> shell \
  "pkill -9 -f gdbserver; pkill -9 -f obscura"
/mnt/d/.sdk/tools/adb/linux/adb -host -s <device> shell "rm -f /data/obscura"

# 2. 启动 gdbserver（后台）
./_scripts/debug.sh <device> --debug --gdbserver-only <obscura_args> &

# 3. 等待 gdbserver 就绪（约 2-3 分钟推送 293M 二进制）
sleep 180

# 4. 验证
/mnt/d/.sdk/tools/adb/linux/adb -host -s <device> shell \
  "ps -ef | grep gdbserver | grep -v grep"
cat $(ls -t target/aarch64/debug_logs/gdbserver_*.log | head -1)

# 5. 设置端口转发
/mnt/d/.sdk/tools/adb/linux/adb -host -s <device> forward tcp:12345 tcp:12345
```

---

## 注意事项

1. **每层分析都需要重启 gdbserver**：上一次 GDB 会话结束后，gdbserver 中的程序也终止了
2. **二进制推送需要 2-3 分钟**：debug 二进制约 293M，通过 adb 推送较慢
3. **使用 `--gdbserver-only`**：让 debug.sh 只负责部署和启动 gdbserver，GDB 分析由我们控制
4. **日志保存在 `target/aarch64/debug_logs/`**：每次分析都会生成带时间戳的日志文件
5. **不要一次写太多 GDB 断点**：GDB 脚本中的 `this` 等符号可能在某些帧中不可用，导致脚本提前终止
6. **指针压缩默认启用**：ARM64 上 `v8_enable_pointer_compression` 默认为 true，交叉编译时可能引发问题

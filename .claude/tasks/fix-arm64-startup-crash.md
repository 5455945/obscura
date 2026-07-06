# 自治任务：修复 ARM64 启动 Crash（参数化模板）

## 任务参数

> **说明**：以下参数在执行任务时通过命令行传入。如果未传入，使用默认值或询问用户。

| 参数 | 占位符 | 默认值 | 说明 |
|------|--------|--------|------|
| **调试设备** | `{{DEVICE}}` | `30.207.82.116:62472` | 格式：`<ip>:<port>` |
| **目标目录** | `{{TARGET_DIR}}` | `target/aarch64` | 编译输出目录 |
| **运行参数** | `{{OBSCURA_ARGS}}` | `fetch https://www.baidu.com --dump html --output page.html` | 传给 obscura 的命令 |
| **成功判据** | `{{SUCCESS_CHECK}}` | `/data/page.html` | 设备上需要生成的文件路径 |

### 参数解析规则

**开始执行任务前**，检查以下环境变量是否已设置：

```bash
DEVICE=${DEVICE:-"30.207.82.116:62472"}
TARGET_DIR=${TARGET_DIR:-"target/aarch64"}
OBSCURA_ARGS=${OBSCURA_ARGS:-"fetch https://www.baidu.com --dump html --output page.html"}
SUCCESS_CHECK=${SUCCESS_CHECK:-"/data/page.html"}
```

如果环境变量未设置，且用户未在启动时指定参数，则：
1. 使用上表中的默认值
2. 或在任务开始时询问用户确认

### 参数提取示例

从 `{{OBSCURA_ARGS}}` 中提取输出文件路径：

```bash
# 如果 OBSCURA_ARGS 包含 "--output <file>"，提取 <file>
# 例如："fetch https://www.baidu.com --dump html --output page.html"
# 则 SUCCESS_CHECK="/data/page.html"

# 使用 grep 提取：
OUTPUT_FILE=$(echo "$OBSCURA_ARGS" | grep -oP '(?<=--output\s)\S+')
if [ -n "$OUTPUT_FILE" ]; then
    SUCCESS_CHECK="/data/$OUTPUT_FILE"
fi
```

---

## 任务目标

让 `obscura` 在 ARM64 车机上成功执行以下命令：

```bash
{{OBSCURA_ARGS}}
```

并在设备上生成文件：`{{SUCCESS_CHECK}}`

## 其他参数

| 参数 | 值 |
|------|-----|
| **ADB 路径** | `/mnt/d/.sdk/tools/adb/linux/adb` |
| **SYSROOT** | `/home/zhangfengjiang.zfj/workspace/git/obscura/third_party/v8-137.3.0/build/linux/debian_bullseye_arm64-sysroot` |
| **GDB 端口** | `12345` |

---

## 阶段 0：分支准备

```bash
# 基于当前分支创建修复分支
git checkout -b fix/arm64-startup-crash-$(date +%Y%m%d)
```

后续所有代码修改、编译、提交都在此分支进行。

---

## 阶段 1：自动调试验证（主循环入口）

### 1.1 编译 debug 版本

```bash
./_scripts/build.sh --debug --target-dir {{TARGET_DIR}}
```

**编译失败处理**：
- 读取 `{{TARGET_DIR}}/build.log` 末尾 100 行
- 定位错误信息
- 进入阶段 3 修复代码
- 重新编译

### 1.2 清理设备旧进程

```bash
ADB="/mnt/d/.sdk/tools/adb/linux/adb"
DEVICE="{{DEVICE}}"

# 清理旧进程
$ADB -host -s $DEVICE shell "pkill -9 -f gdbserver; pkill -9 -f obscura"
sleep 2

# 清理旧二进制和输出文件
$ADB -host -s $DEVICE shell "rm -f /data/obscura {{SUCCESS_CHECK}}"
```

### 1.3 启动 gdbserver

```bash
# 后台启动 debug.sh
nohup ./_scripts/debug.sh {{DEVICE}} --debug --target-dir {{TARGET_DIR}} \
  --gdbserver-only {{OBSCURA_ARGS}} \
  > {{TARGET_DIR}}/debug_logs/debug_loop_$(date +%Y%m%d_%H%M%S).log 2>&1 &

# 等待 gdbserver 启动（二进制推送约 2-3 分钟）
sleep 180
```

**验证 gdbserver 就绪**：

```bash
# 检查 gdbserver 进程
$ADB -host -s $DEVICE shell "ps -ef | grep gdbserver | grep -v grep"

# 检查日志
ls -t {{TARGET_DIR}}/debug_logs/gdbserver_*.log | head -1 | xargs cat
```

预期输出：
```
Process /data/obscura created; pid = XXXXX
Listening on port 12345
```

### 1.4 设置端口转发

```bash
$ADB -host -s $DEVICE forward tcp:12345 tcp:12345
```

### 1.5 运行 GDB 自动化分析

**创建 GDB 脚本** `/tmp/gdb_task_analyze.gdb`：

```gdb
set pagination off
set height 0
set width 0
set confirm off
set solib-search-path ./
set sysroot /home/zhangfengjiang.zfj/workspace/git/obscura/third_party/v8-137.3.0/build/linux/debian_bullseye_arm64-sysroot
target remote localhost:12345
echo \n=== [TASK] 开始执行 ===\n
continue
echo \n=== [TASK] 程序已停止 ===\n
info program
echo \n=== [TASK] 寄存器状态 ===\n
info registers
echo \n=== [TASK] 调用栈（30层）===\n
bt 30
echo \n=== [TASK] 线程列表 ===\n
info threads
echo \n=== [TASK] 所有线程调用栈 ===\n
thread apply all bt 10
echo \n=== [TASK] 分析完成 ===\n
quit
```

**运行 GDB**：

```bash
timeout 120 gdb-multiarch -q -x /tmp/gdb_task_analyze.gdb \
  {{TARGET_DIR}}/aarch64-unknown-linux-gnu/debug/obscura \
  2>&1 | tee {{TARGET_DIR}}/debug_logs/gdb_task_$(date +%Y%m%d_%H%M%S).log
```

### 1.6 判断结果

**成功条件**（必须全部满足）：

1. GDB 日志中未出现崩溃信号：
   ```bash
   ! grep -q "received signal SIG" {{TARGET_DIR}}/debug_logs/gdb_task_*.log
   ```

2. 程序正常退出：
   ```bash
   grep -q "Inferior 1 .* exited normally" {{TARGET_DIR}}/debug_logs/gdb_task_*.log
   ```

3. 设备端文件存在且非空：
   ```bash
   $ADB -host -s $DEVICE shell "test -s {{SUCCESS_CHECK}} && echo 'SUCCESS' || echo 'FAIL'"
   ```

**失败条件**（满足任一）：

- 出现崩溃信号：`SIGSEGV` / `SIGABRT` / `SIGBUS` / `SIGFPE`
- GDB 显示异常停止
- 程序超时（120 秒）
- 设备端未生成 `{{SUCCESS_CHECK}}` 或文件为空

### 1.7 成功路径 → 终止任务

```bash
# 提交代码
git add -A
git commit -m "fix: resolve ARM64 startup crash

Device: {{DEVICE}}
Target dir: {{TARGET_DIR}}
Command: {{OBSCURA_ARGS}}
Result: {{SUCCESS_CHECK}} generated successfully."

echo "✅ 任务完成：ARM64 启动 crash 已修复"
echo "   设备: {{DEVICE}}"
echo "   输出: {{SUCCESS_CHECK}}"
```

**任务结束**。

### 1.8 失败路径 → 进入阶段 2

读取 GDB 日志，提取崩溃信息，进入阶段 2 分析。

---

## 阶段 2：崩溃/错误分析

### 2.1 收集证据

从以下日志提取信息：

```bash
# 最新的 GDB 日志
GDB_LOG=$(ls -t {{TARGET_DIR}}/debug_logs/gdb_task_*.log | head -1)

# 提取关键信息
echo "=== 崩溃信号 ==="
grep "received signal" $GDB_LOG

echo -e "\n=== 崩溃位置 ==="
grep -A 5 "Thread 1.*received signal" $GDB_LOG | head -10

echo -e "\n=== 调用栈 ==="
grep -A 30 "调用栈（30层）" $GDB_LOG

echo -e "\n=== 可疑寄存器 ==="
grep -A 35 "寄存器状态" $GDB_LOG | head -40
```

### 2.2 分析范围

扫描 `obscura` 仓库下所有相关代码，按崩溃调用栈定位：

| 崩溃位置 | 检查代码 |
|---------|---------|
| `v8::internal::*` | `crates/obscura-js/src/` + `build.sh`（GN_ARGS） |
| `obscura_browser::*` | `crates/obscura-browser/src/` |
| `obscura_dom::*` | `crates/obscura-dom/src/` |
| `obscura_net::*` | `crates/obscura-net/src/` |
| `obscura::run_*` | `crates/obscura-cli/src/main.rs` |
| 编译错误 | `{{TARGET_DIR}}/build.log` |

### 2.3 形成修复假设

基于崩溃调用栈和代码分析：

1. 列出可能的根本原因（1-3 个）
2. 按可行性排序
3. 选择最可能的假设

### 2.4 进入阶段 3

带着修复假设进入阶段 3。

---

## 阶段 3：实施修复

### 3.1 修改代码

根据修复假设，使用 `Edit` 工具修改代码。

### 3.2 编译验证

```bash
./_scripts/build.sh --debug --target-dir {{TARGET_DIR}}
```

### 3.3 编译失败处理

如果编译失败：

```bash
# 读取编译错误
tail -100 {{TARGET_DIR}}/build.log

# 定位错误文件和行号
grep -E "error\[" {{TARGET_DIR}}/build.log | tail -5
```

**修复流程**：

1. 分析编译错误
2. 修改代码修复错误
3. 重新编译
4. **连续 3 次编译失败** → 放弃当前假设，回到阶段 2 选择下一个假设

### 3.4 编译成功 → 回到阶段 1

编译成功后，输出进度摘要：

```
=== 循环 #N 完成 ===
- 设备: {{DEVICE}}
- 目标目录: {{TARGET_DIR}}
- 测试命令: {{OBSCURA_ARGS}}
- 本轮修改: <文件列表>
- 崩溃位置: <函数/文件>
- 修复假设: <假设描述>
- 下一步: 重新调试验证
```

回到阶段 1，重新调试验证。

---

## 循环控制

```
┌─────────────────────────────────────────────────────┐
│  阶段 1: 编译 + 调试                                 │
│  ├─ 成功 → 提交代码 → 结束任务                      │
│  └─ 失败 ↓                                          │
│  阶段 2: 分析崩溃                                    │
│  ├─ 形成修复假设                                     │
│  └─ ↓                                               │
│  阶段 3: 修改代码 + 编译                             │
│  ├─ 编译失败 → 修复编译错误 → 重试编译               │
│  │   └─ 连续 3 次失败 → 回到阶段 2 换假设            │
│  └─ 编译成功 → 回到阶段 1                           │
└─────────────────────────────────────────────────────┘
```

**不设循环上限**，持续执行直到成功或触发人工干预条件。

---

## 人工干预触发条件

**仅以下情况暂停任务并请求人工协助**，其他情况一律自动处理：

| 情况 | 判断方法 | 报告格式 |
|------|---------|---------|
| **调试设备无法连接** | `adb connect` 重试 3 次仍失败 | `⚠️ 设备连接失败：无法连接到 {{DEVICE}}` |
| **设备未授权** | `adb get-state` 返回 `unauthorized` 且重试无效 | `⚠️ 设备未授权：请在车机上点击"允许 USB 调试"` |
| **磁盘空间不足** | `df -h .` 显示剩余 < 10GB | `⚠️ 磁盘空间不足：剩余 < 10GB，请清理磁盘` |
| **gdbserver 未安装** | 设备上 `/usr/bin/gdbserver` 不存在 | `⚠️ gdbserver 未安装：设备上缺少 /usr/bin/gdbserver` |
| **未知外部依赖缺失** | 编译/运行报找不到非项目内的工具或库 | `⚠️ 外部依赖缺失：<具体依赖>` |

**触发时输出**：

```
═══════════════════════════════════════════════════
⚠️ 需要人工介入
═══════════════════════════════════════════════════
设备: {{DEVICE}}
目标目录: {{TARGET_DIR}}
原因: <具体原因>
当前状态: 第 N 轮循环
已完成: <已完成的步骤>
等待操作: <需要用户做什么>
═══════════════════════════════════════════════════
```

---

## 任务完成标准

满足以下**全部条件**才算完成：

- [ ] 设备端 `{{SUCCESS_CHECK}}` 存在且内容非空
- [ ] 调试过程无崩溃信号
- [ ] 修复代码已提交到 `fix/arm64-startup-crash-*` 分支
- [ ] 提交信息包含验证说明和设备信息

---

## 日志文件

所有日志保存在 `{{TARGET_DIR}}/debug_logs/`：

- `build_*.log` — 编译日志
- `debug_loop_*.log` — 调试会话日志
- `gdbserver_*.log` — gdbserver 日志
- `gdb_task_*.log` — GDB 自动化输出

---

## 使用示例

### 示例 1：使用默认参数

```bash
# 直接启动 Claude Code
claude

# 在 Claude Code 中输入
请读取并执行 .claude/tasks/fix-arm64-startup-crash.md 中的任务，使用默认参数
```

### 示例 2：指定不同设备

```bash
# 设置环境变量后启动
DEVICE=30.207.82.116:62471 claude

# 在 Claude Code 中输入
请读取并执行 .claude/tasks/fix-arm64-startup-crash.md 中的任务
```

### 示例 3：指定完整参数

```bash
# 设置所有环境变量
export DEVICE=30.207.82.116:62471
export TARGET_DIR=target/dbg
export OBSCURA_ARGS="fetch https://www.baidu.com --dump links"

claude

# 在 Claude Code 中输入
请读取并执行 .claude/tasks/fix-arm64-startup-crash.md 中的任务
```

### 示例 4：在 Claude Code 中动态指定

```bash
claude

# 在 Claude Code 中输入
请读取 .claude/tasks/fix-arm64-startup-crash.md 中的任务模板，
我指定以下参数：
- 设备：30.207.82.116:62471
- 目标目录：target/dbg
- 运行参数：fetch https://www.baidu.com --dump html --output page.html

然后开始执行任务
```

---

## 执行指令

**开始执行此任务**。

1. 首先解析参数（从环境变量或用户输入）
2. 将所有 `{{占位符}}` 替换为实际值
3. 按照阶段 0 → 1 → 2 → 3 的顺序循环执行
4. 每次循环输出进度摘要
5. 直到满足完成标准或触发人工干预条件

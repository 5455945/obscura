# Obscura aarch64 部署指南

## 安装包信息

### 自包含安装包
- **文件名**: `obscura-tsdemo-linux-arm64.tar.gz`
- **大小**: 约 43MB
- **架构**: Linux aarch64 (ARM64)
- **包含内容**:
  - `playwright-core/` - Playwright 核心库
  - `obscura-ts/` - TypeScript SDK（包含二进制文件和编译产物）
  - `obscura-tsdemo/` - Demo 示例代码
  - `node_modules/` - 预配置的模块链接

**特点**：
- 包含所有依赖，无需联网安装
- 解压即用，适合离线环境
- 使用 `bundle.sh` 脚本打包

## 部署步骤

### 方式一：ADB 推送（推荐）

#### 1. 设置设备信息

```bash
# 设置设备地址（请替换为实际设备地址）
DEVICE_IP="30.207.92.96"
DEVICE_PORT="61208"
ADB_PATH="/mnt/d/.sdk/tools/adb/linux/adb"

# 或者使用环境变量
export DEVICE_IP="30.207.92.96"
export DEVICE_PORT="61208"
```

#### 2. 连接设备

```bash
# 连接设备
$ADB_PATH -host connect ${DEVICE_IP}:${DEVICE_PORT}

# 配置权限
$ADB_PATH -host -s ${DEVICE_IP}:${DEVICE_PORT} echo "enable n;" > /proc/alog
$ADB_PATH -host -s ${DEVICE_IP}:${DEVICE_PORT} mount -o remount,rw /
```

#### 3. 推送安装包

```bash
# 推送安装包到设备
$ADB_PATH -host -s ${DEVICE_IP}:${DEVICE_PORT} push ./obscura-tsdemo-linux-arm64.tar.gz /data/
```

#### 4. 在设备上解压和运行

```bash
# 通过 adb shell 进入设备
$ADB_PATH -host -s ${DEVICE_IP}:${DEVICE_PORT} shell

# 在设备上执行以下命令
cd /data
tar xzf obscura-tsdemo-linux-arm64.tar.gz

# 运行测试
cd obscura-tsdemo
node dist/verify.js
```

### 方式二：SSH/SCP（如果设备支持）

#### 1. 传输安装包

```bash
# 设置设备信息
DEVICE_HOST="user@车机IP"

# 传输文件
scp obscura-tsdemo-linux-arm64.tar.gz ${DEVICE_HOST}:/tmp/
```

#### 2. 在设备上安装

```bash
# SSH 登录设备
ssh ${DEVICE_HOST}

# 创建工作目录
mkdir -p ~/obscura-test
cd ~/obscura-test

# 复制并解压安装包
cp /tmp/obscura-tsdemo-linux-arm64.tar.gz .
tar xzf obscura-tsdemo-linux-arm64.tar.gz

# 运行测试
node obscura-tsdemo/dist/verify.js
```

## 验证安装

```bash
# 检查二进制文件架构
file obscura-ts/bin/linux-arm64/obscura
# 预期输出: ELF 64-bit LSB shared object, ARM aarch64

# 检查版本
obscura-ts/bin/linux-arm64/obscura --version
# 预期输出: obscura 0.1.0
```

## 运行测试

```bash
# 运行基础验证
node obscura-tsdemo/dist/verify.js

# 运行 UserAgent 测试
node obscura-tsdemo/dist/test-useragent.js

# 运行其他示例
node obscura-tsdemo/dist/basic.js
node obscura-tsdemo/dist/scrape.js
node obscura-tsdemo/dist/stealth.js
```

## 预期输出

### verify.js 测试
```
=== 验证 obscura-ts SDK 包 ===

1. 启动 obscura 浏览器...
   ✓ 浏览器启动成功

2. 创建新页面...
   ✓ 页面创建成功

3. 导航到 https://www.baidu.com...
   ✓ 导航成功

4. 获取页面标题...
   ✓ 标题: 百度一下，你就知道

5. 执行 JavaScript...
   ✓ 搜索框存在: true

6. 关闭浏览器...
   ✓ 浏览器已关闭

=== 验证完成 ===
obscura-ts SDK 包工作正常！
```

### test-useragent.js 测试
```
=== 测试 UserAgent 配置 ===

1. 启动浏览器（自定义 UserAgent）...
   设置的 UserAgent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36...

2. 导航到百度...
   ✓ 导航成功

3. 检查 navigator.userAgent...
   实际 UserAgent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36...

4. 验证结果...
   ✓ UserAgent 配置成功！完全匹配

=== 测试完成 ===
```

## 常见问题

### 1. 二进制文件无法执行

**问题**: `exec format error`

**原因**: 架构不匹配

**解决**: 确认二进制文件是 aarch64 架构
```bash
file obscura-ts/bin/linux-arm64/obscura
```

### 2. 缺少依赖库

**问题**: `error while loading shared libraries: libxxx.so`

**解决**: 安装缺失的依赖库
```bash
# 查看缺失的库
ldd obscura-ts/bin/linux-arm64/obscura

# 安装缺失的库（示例）
sudo apt-get install libxxx
```

### 3. 端口被占用

**问题**: `bind 127.0.0.1:9222: Address already in use`

**解决**: 清理残留进程或更换端口
```bash
# 清理残留进程
pkill -9 -f "obscura serve"

# 或在代码中指定其他端口
const browser = await ObscuraBrowser.launch({ port: 9223 });
```

### 4. JavaScript 错误

**问题**: `Error: Couldn't find a style target`

**原因**: 某些网站的 JavaScript 兼容性问题

**解决**: 可以忽略，不影响核心功能。或设置 `quiet: true` 隐藏日志。

### 5. ADB 连接失败

**问题**: `cannot connect to device`

**解决**:
```bash
# 检查设备是否在线
$ADB_PATH -host devices

# 断开并重新连接
$ADB_PATH -host disconnect ${DEVICE_IP}:${DEVICE_PORT}
$ADB_PATH -host connect ${DEVICE_IP}:${DEVICE_PORT}
```

## 性能测试

在设备上运行性能测试：

```bash
cat > perf-test.js << 'EOF'
const { ObscuraBrowser } = require('./obscura-ts/dist/index.js');

async function main() {
  console.log('=== 性能测试 ===\n');
  
  const iterations = 10;
  const times = [];
  
  for (let i = 0; i < iterations; i++) {
    const start = Date.now();
    const browser = await ObscuraBrowser.launch({ quiet: true });
    const page = await browser.newPage();
    await page.goto('https://www.baidu.com');
    await browser.close();
    const elapsed = Date.now() - start;
    times.push(elapsed);
    console.log(`迭代 ${i + 1}: ${elapsed}ms`);
  }
  
  const avg = times.reduce((a, b) => a + b) / times.length;
  const min = Math.min(...times);
  const max = Math.max(...times);
  
  console.log(`\n=== 结果 ===`);
  console.log(`平均: ${avg.toFixed(2)}ms`);
  console.log(`最小: ${min}ms`);
  console.log(`最大: ${max}ms`);
}

main().catch(console.error);
EOF

node perf-test.js
```

## 清理

```bash
# 删除安装包
rm obscura-tsdemo-linux-arm64.tar.gz

# 删除工作目录
rm -rf obscura-test
```

## 验证检查清单

在设备上执行以下检查：

- [ ] 二进制文件架构正确（ELF 64-bit ARM aarch64）
- [ ] 二进制文件可执行（`obscura --version` 正常）
- [ ] 浏览器启动正常
- [ ] 页面导航正常
- [ ] JavaScript 执行正常
- [ ] 元素选择器工作正常
- [ ] 页面内容获取正常
- [ ] 隐身模式工作正常
- [ ] UserAgent 配置生效
- [ ] 性能指标合理

## 反馈

测试完成后，请提供以下信息：

1. **环境信息**:
   - 设备型号
   - 操作系统版本
   - CPU 架构（确认是 aarch64）
   - 内存大小

2. **测试结果**:
   - 所有测试是否通过
   - 性能数据（启动时间、导航时间等）
   - 遇到的问题和错误信息

3. **改进建议**:
   - 功能需求
   - 性能优化建议
   - 其他反馈

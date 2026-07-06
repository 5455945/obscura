# Obscura TypeScript SDK 发布指南

## 当前状态

✅ **已完成的工作：**

1. **二进制文件打包**
   - obscura 和 obscura-worker 已复制到 `bin/<platform>/`
   - 包大小：45.7 MB（压缩后）/ 140.5 MB（解压后）
   - 包含 35 个文件
   - **注意**：`bin/` 目录已添加到 `.gitignore`，不会被提交到仓库

2. **自动检测逻辑**
   - SDK 会自动在 `bin/<platform>/` 目录查找二进制文件
   - 支持 linux-x64、linux-arm64、darwin-x64、darwin-arm64、win32-x64

3. **发布脚本**
   - `scripts/prepare-bin.js` 自动复制当前架构的二进制文件
   - **不会删除其他架构的文件**，只覆盖当前架构
   - `npm run prepublishOnly` 在发布前自动执行

## 发布流程

### 1. 准备阶段

```bash
# 确保已编译 obscura（x86_64）
./_scripts/build.sh --arch x86_64 --release

# 进入 SDK 目录
cd sdk/obscura_ts

# 安装依赖
npm install

# 编译 TypeScript
npm run build

# 复制二进制文件到 bin/
npm run prepare:bin
```

### 2. 测试打包

```bash
# 测试打包（不实际创建文件）
npm pack --dry-run

# 实际打包（创建 .tgz 文件）
npm pack
```

### 3. 发布到 npm

```bash
# 登录 npm（如果未登录）
npm login

# 发布
npm publish

# 或者发布到特定 tag
npm publish --tag beta
```

### 4. 用户安装

```bash
# 从 npm 安装
npm install obscura-ts

# 或者从本地 .tgz 安装
npm install ./obscura-ts-0.1.0.tgz
```

## 多平台支持

**重要**：`prepare-bin.js` 只会复制当前架构的二进制文件到 `bin/<platform>/`，**不会删除其他架构的文件**。

### 当前架构（自动检测）
```bash
# 自动检测当前架构并复制对应的二进制文件
npm run prepare:bin

# 或手动指定构建目录
node scripts/prepare-bin.js ./target/x86_64/x86_64-unknown-linux-gnu/release
```

### 交叉编译其他架构

如果需要为其他架构准备二进制文件：

```bash
# 1. 交叉编译 aarch64 版本
./_scripts/build.sh --arch aarch64 --release

# 2. 手动复制 aarch64 二进制文件（不会覆盖其他架构）
mkdir -p bin/linux-arm64
cp target/aarch64/aarch64-unknown-linux-gnu/release/obscura bin/linux-arm64/
cp target/aarch64/aarch64-unknown-linux-gnu/release/obscura-worker bin/linux-arm64/
chmod +x bin/linux-arm64/*

# 3. 打包时会包含所有架构的二进制文件
npm pack
```

**注意**：npm 包会包含 `bin/` 目录下所有架构的二进制文件，用户安装时 SDK 会自动选择对应平台的版本。

## 包结构

```
obscura-ts-0.1.0/
├── bin/
│   ├── linux-x64/
│   │   ├── obscura          (72.2 MB)
│   │   └── obscura-worker   (68.2 MB)
│   ├── linux-arm64/         (可选)
│   ├── darwin-x64/          (可选)
│   ├── darwin-arm64/        (可选)
│   └── win32-x64/           (可选)
├── dist/                    (编译后的 JavaScript)
├── src/                     (TypeScript 源码)
├── scripts/
│   └── prepare-bin.js       (二进制准备脚本)
├── package.json
└── README.md
```

## 使用示例

```typescript
import { ObscuraBrowser } from 'obscura-ts';

async function main() {
  // 启动浏览器（自动查找 bin/ 目录中的二进制文件）
  const browser = await ObscuraBrowser.launch({
    stealth: true,
    quiet: true,
  });

  const page = await browser.newPage();
  await page.goto('https://www.baidu.com');
  
  console.log(await page.title());
  
  await browser.close();
}

main();
```

## 故障排查

### 问题：找不到 obscura 二进制

**解决方案：**
1. 检查 `bin/<platform>/` 目录是否存在
2. 确认二进制文件有执行权限：`chmod +x bin/linux-x64/obscura`
3. 手动指定路径：
   ```typescript
   const browser = await ObscuraBrowser.launch({
     executablePath: '/path/to/obscura'
   });
   ```

### 问题：包太大

**优化方案：**
1. 使用 `strip` 命令去除调试符号：
   ```bash
   strip bin/linux-x64/obscura
   strip bin/linux-x64/obscura-worker
   ```
2. 使用 UPX 压缩（需要安装）：
   ```bash
   upx --best bin/linux-x64/obscura
   upx --best bin/linux-x64/obscura-worker
   ```

### 问题：跨平台发布

**解决方案：**
1. 在 CI/CD 中为每个平台编译
2. 使用 GitHub Actions 自动编译和发布
3. 或者使用 Docker 多平台编译

## 下一步

1. **创建 README.md** - 用户文档
2. **添加 LICENSE** - Apache 2.0 许可证
3. **配置 .npmignore** - 排除不必要的文件
4. **设置 CI/CD** - 自动编译和发布
5. **版本管理** - 使用语义化版本号

## 参考

- [npm 发布指南](https://docs.npmjs.com/packages-and-modules/contributing-packages-to-the-registry)
- [语义化版本](https://semver.org/)
- [obscura 项目文档](../../README.md)

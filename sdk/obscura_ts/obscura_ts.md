# obscura-ts

TypeScript SDK for [Obscura](https://github.com/h4ckf0r0day/obscura) headless browser.

**obscura-ts** provides a high-level, type-safe API for browser automation using Obscura's Chrome DevTools Protocol (CDP) implementation, powered by [Playwright](https://playwright.dev/).

## Features

- **TypeScript-first** — Full type definitions and IntelliSense support
- **Stealth mode** — Built-in anti-detection (fingerprint randomization, tracker blocking)
- **Playwright-compatible** — Uses Playwright's battle-tested browser automation
- **Obscura-optimized** — Leverages Obscura's lightweight engine (~30MB memory vs 200MB+ for Chrome)
- **Markdown extraction** — Built-in DOM-to-Markdown conversion via `LP.getMarkdown`
- **Process management** — Automatically launches and manages obscura processes

## Prerequisites

Before using obscura-ts, you need:

1. **Obscura binary** — Build from source or download from [releases](https://github.com/h4ckf0r0day/obscura/releases)
2. **Node.js 18+** — Required for modern JavaScript features
3. **Playwright source** — Downloaded to `_deps/playwright/`

### Building Obscura

```bash
git clone https://github.com/h4ckf0r0day/obscura.git
cd obscura
cargo build --release

# With stealth mode (recommended)
cargo build --release --features stealth
```

### Downloading Playwright

```bash
# Download default version (v1.60.0)
./_scripts/download_playwright.sh

# Download specific version
./_scripts/download_playwright.sh --version 1.61.0

# Check for updates
./_scripts/download_playwright.sh --check-only
```

## Installation

```bash
# Prepare Playwright dependency
cd sdk/obscura_ts
./prepare_playwright.sh

# Install obscura-ts
npm install

# Build the SDK
npm run build
```

## Quick Start

```typescript
import { ObscuraBrowser } from 'obscura-ts';

async function main() {
  // Launch obscura with stealth mode
  const browser = await ObscuraBrowser.launch({ stealth: true });

  // Create a new page
  const page = await browser.newPage();

  // Navigate to a website
  await page.goto('https://example.com');

  // Get page title
  console.log(await page.title());

  // Evaluate JavaScript
  const heading = await page.evaluate<string>('document.querySelector("h1")?.textContent');
  console.log(heading);

  // Get page as Markdown (obscura-specific)
  const markdown = await page.markdown();
  console.log(markdown);

  // Close browser
  await browser.close();
}

main().catch(console.error);
```

## API Reference

### ObscuraBrowser

The main browser class that manages the obscura process and Playwright connection.

#### `ObscuraBrowser.launch(options?)`

Launch a new obscura process and connect via CDP.

```typescript
const browser = await ObscuraBrowser.launch({
  stealth: true,        // Enable anti-detection
  port: 9222,           // CDP server port
  proxy: 'socks5://...', // Optional proxy
  workers: 2,           // Parallel worker processes
  quiet: true,          // Suppress obscura logs
});
```

**Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `executablePath` | `string` | auto-detect | Path to obscura binary |
| `port` | `number` | `9222` | CDP server port |
| `host` | `string` | `"127.0.0.1"` | Bind host |
| `stealth` | `boolean` | `false` | Enable anti-detection |
| `proxy` | `string` | — | HTTP/SOCKS5 proxy URL |
| `workers` | `number` | `1` | Parallel worker processes |
| `userAgent` | `string` | — | Custom User-Agent |
| `v8Flags` | `string` | — | V8 engine flags |
| `timeout` | `number` | `30000` | Launch timeout (ms) |
| `cwd` | `string` | — | Working directory |
| `allowFileAccess` | `boolean` | `false` | Allow file:// navigation |
| `allowPrivateNetwork` | `boolean` | `false` | Allow private network access |
| `quiet` | `boolean` | `false` | Suppress obscura logs |
| `verbose` | `boolean` | `false` | Enable verbose logging |

#### `ObscuraBrowser.connect(options)`

Connect to an already-running obscura CDP server.

```typescript
const browser = await ObscuraBrowser.connect({
  endpointURL: 'ws://127.0.0.1:9222',
  timeout: 30000,
});
```

#### `ObscuraBrowser.connectOverCDP(endpointURL)`

Shorthand for connecting to a CDP endpoint.

```typescript
const browser = await ObscuraBrowser.connectOverCDP('ws://127.0.0.1:9222');
```

#### `browser.newPage()`

Create a new page (tab).

```typescript
const page = await browser.newPage();
```

#### `browser.pages()`

Get all currently open pages.

```typescript
const pages = browser.pages();
```

#### `browser.close()`

Close the browser and terminate the obscura process.

```typescript
await browser.close();
```

#### `browser.disconnect()`

Disconnect from the server without closing it (for `connect()` instances).

```typescript
await browser.disconnect();
```

#### `browser.isConnected`

Check if the browser connection is still active.

```typescript
if (browser.isConnected) {
  console.log('Connected');
}
```

#### `browser.playwrightBrowser`

Access the underlying Playwright Browser instance for advanced APIs.

```typescript
const contexts = browser.playwrightBrowser.contexts();
```

---

### ObscuraPage

Page wrapper with obscura-specific helpers.

#### `page.goto(url, options?)`

Navigate to a URL.

```typescript
await page.goto('https://example.com', {
  waitUntil: 'networkidle',  // 'load' | 'domcontentloaded' | 'networkidle' | 'commit'
  timeout: 30000,
});
```

#### `page.evaluate<T>(expression)`

Evaluate JavaScript in the page context.

```typescript
const title = await page.evaluate<string>('document.title');
const count = await page.evaluate<number>('document.querySelectorAll("a").length');
const data = await page.evaluate('({ url: location.href, title: document.title })');
```

#### `page.title()`

Get the page title.

```typescript
const title = await page.title();
```

#### `page.content()`

Get the full HTML content.

```typescript
const html = await page.content();
```

#### `page.markdown()`

Get the page content as Markdown (obscura-specific feature using `LP.getMarkdown` CDP domain).

```typescript
const markdown = await page.markdown();
console.log(markdown);
```

#### `page.textContent()`

Get the visible text content of the page body.

```typescript
const text = await page.textContent();
```

#### `page.url()`

Get the current URL.

```typescript
const url = page.url();
```

#### `page.$(selector)`

Query a single element by CSS selector.

```typescript
const el = await page.$('h1');
if (el) {
  const text = await el.textContent();
}
```

#### `page.$$(selector)`

Query all elements matching a CSS selector.

```typescript
const links = await page.$$('a');
for (const link of links) {
  const href = await link.getAttribute('href');
}
```

#### `page.$text(selector)`

Query a single element and return its text content.

```typescript
const heading = await page.$text('h1');
```

#### `page.$$text(selector)`

Query all matching elements and return their text contents.

```typescript
const titles = await page.$$text('.article-title');
```

#### `page.$attr(selector, name)`

Query a single element and return an attribute value.

```typescript
const src = await page.$attr('img', 'src');
```

#### `page.click(selector, options?)`

Click an element.

```typescript
await page.click('button.submit');
```

#### `page.fill(selector, value, options?)`

Fill an input element with a value.

```typescript
await page.fill('input[name="email"]', 'user@example.com');
```

#### `page.type(selector, text, options?)`

Type text into an input character by character.

```typescript
await page.type('input[name="search"]', 'hello world', { delay: 50 });
```

#### `page.pressKey(key, options?)`

Press a keyboard key.

```typescript
await page.pressKey('Enter');
await page.pressKey('Tab', { selector: 'input' });
```

#### `page.selectOption(selector, values)`

Select an option in a `<select>` element.

```typescript
await page.selectOption('select#country', 'US');
```

#### `page.waitForSelector(selector, options?)`

Wait for a CSS selector to appear.

```typescript
await page.waitForSelector('.loaded', { timeout: 10000 });
```

#### `page.waitForFunction(expression, options?)`

Wait for a JavaScript expression to return truthy.

```typescript
await page.waitForFunction('document.querySelector(".data") !== null');
```

#### `page.waitForTimeout(ms)`

Wait for a specified time.

```typescript
await page.waitForTimeout(2000); // 2 seconds
```

#### `page.screenshot(options?)`

Take a screenshot.

```typescript
const buffer = await page.screenshot({
  path: 'screenshot.png',
  fullPage: true,
});
```

#### `page.setViewportSize(width, height)`

Set the viewport size.

```typescript
await page.setViewportSize(1920, 1080);
```

#### `page.close()`

Close the page.

```typescript
await page.close();
```

#### `page.playwrightPage`

Access the underlying Playwright Page instance for advanced APIs.

```typescript
await page.playwrightPage.route('**/*.{png,jpg}', route => route.abort());
```

---

## Examples

### Web Scraping

```typescript
import { ObscuraBrowser } from 'obscura-ts';

async function scrapeHackerNews() {
  const browser = await ObscuraBrowser.launch({ stealth: true, quiet: true });
  const page = await browser.newPage();

  await page.goto('https://news.ycombinator.com');
  await page.waitForSelector('.titleline');

  const articles = await page.evaluate(`
    Array.from(document.querySelectorAll('.athing')).map(item => ({
      title: item.querySelector('.titleline > a')?.textContent,
      url: item.querySelector('.titleline > a')?.href,
    }))
  `);

  console.log(articles);
  await browser.close();
}
```

### Form Filling

```typescript
import { ObscuraBrowser } from 'obscura-ts';

async function fillForm() {
  const browser = await ObscuraBrowser.launch();
  const page = await browser.newPage();

  await page.goto('https://example.com/form');

  await page.fill('input[name="name"]', 'John Doe');
  await page.fill('input[name="email"]', 'john@example.com');
  await page.click('input[type="checkbox"]');
  await page.click('button[type="submit"]');

  await page.waitForTimeout(2000);
  await browser.close();
}
```

### Stealth Mode

```typescript
import { ObscuraBrowser } from 'obscura-ts';

async function stealthDemo() {
  const browser = await ObscuraBrowser.launch({
    stealth: true,
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/145.0.0.0',
  });

  const page = await browser.newPage();

  // Verify anti-detection
  const webdriver = await page.evaluate('navigator.webdriver');
  console.log('webdriver:', webdriver); // undefined (not true!)

  await page.goto('https://bot.sannysoft.com');
  await page.screenshot({ path: 'stealth-test.png', fullPage: true });

  await browser.close();
}
```

### Connecting to Existing Server

```typescript
import { ObscuraBrowser } from 'obscura-ts';

// Start obscura server separately:
// $ obscura serve --port 9222 --stealth

async function connectDemo() {
  const browser = await ObscuraBrowser.connect({
    endpointURL: 'ws://127.0.0.1:9222',
  });

  const page = await browser.newPage();
  await page.goto('https://example.com');
  console.log(await page.title());

  // Don't close the browser - just disconnect
  await browser.disconnect();
}
```

### Multiple Pages

```typescript
import { ObscuraBrowser } from 'obscura-ts';

async function multiPageDemo() {
  const browser = await ObscuraBrowser.launch();

  // Create multiple pages
  const pages = await Promise.all([
    browser.newPage(),
    browser.newPage(),
    browser.newPage(),
  ]);

  // Navigate each to different URLs
  await Promise.all([
    pages[0].goto('https://example.com'),
    pages[1].goto('https://example.org'),
    pages[2].goto('https://example.net'),
  ]);

  // Get all titles
  const titles = await Promise.all(pages.map(p => p.title()));
  console.log(titles);

  await browser.close();
}
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Your Application                      │
│                                                          │
│  import { ObscuraBrowser } from 'obscura-ts';           │
│  const browser = await ObscuraBrowser.launch();          │
└─────────────────────┬───────────────────────────────────┘
                      │ TypeScript API
                      ▼
┌─────────────────────────────────────────────────────────┐
│                    obscura-ts SDK                        │
│                                                          │
│  ObscuraBrowser ─── Playwright ─── CDP WebSocket         │
│  ObscuraPage                                               │
└─────────────────────┬───────────────────────────────────┘
                      │ Chrome DevTools Protocol
                      ▼
┌─────────────────────────────────────────────────────────┐
│                  obscura (Rust)                           │
│                                                          │
│  CDP Server ─── Browser Engine ─── V8 JavaScript         │
│  (port 9222)     (DOM, Network)    (Page JS)              │
└─────────────────────────────────────────────────────────┘
```

### Process Lifecycle

1. `ObscuraBrowser.launch()` spawns `obscura serve` as a child process
2. The SDK polls `/json/version` until the CDP server is ready
3. Playwright connects via WebSocket to `ws://127.0.0.1:9222`
4. Page operations are sent as CDP messages over the WebSocket
5. `browser.close()` disconnects Playwright and kills the obscura process

## Troubleshooting

### "obscura binary not found"

Make sure obscura is built and in your PATH, or specify `executablePath`:

```typescript
const browser = await ObscuraBrowser.launch({
  executablePath: '/path/to/obscura',
});
```

### "Timed out waiting for CDP server"

The server may be slow to start. Increase the timeout:

```typescript
const browser = await ObscuraBrowser.launch({
  timeout: 60000, // 60 seconds
});
```

### "JavaScript heap out of memory"

Increase V8's heap size:

```typescript
const browser = await ObscuraBrowser.launch({
  v8Flags: '--max-old-space-size=4096',
});
```

### Playwright dependency issues

Re-run the prepare script:

```bash
cd sdk/obscura_ts
./prepare_playwright.sh --force
npm install
```

## 发布

### 发布流程

obscura-ts 采用**方案 A：打包二进制文件**的方式发布，即 npm 包中包含 obscura 和 obscura-worker 二进制文件。

#### 1. 准备阶段

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

#### 2. 测试打包

```bash
# 测试打包（不实际创建文件）
npm pack --dry-run

# 实际打包（创建 .tgz 文件）
npm pack
```

#### 3. 发布到 npm

```bash
# 登录 npm（如果未登录）
npm login

# 发布
npm publish

# 或者发布到特定 tag
npm publish --tag beta
```

### 包结构

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

### 多平台支持

当前只打包了 **linux-x64** 版本。要支持其他平台：

#### ARM64 (Linux)
```bash
# 交叉编译
./_scripts/build.sh --arch aarch64 --release

# 复制二进制
node scripts/prepare-bin.js ./target/aarch64/aarch64-unknown-linux-gnu/release
```

#### macOS (Intel)
```bash
# 在 macOS Intel 机器上编译
./_scripts/build.sh --arch x86_64 --release

# 复制二进制
node scripts/prepare-bin.js
```

#### macOS (Apple Silicon)
```bash
# 在 macOS ARM64 机器上编译
./_scripts/build.sh --arch aarch64 --release

# 复制二进制
node scripts/prepare-bin.js
```

#### Windows
```bash
# 在 Windows 上编译
./_scripts/build.sh --arch x86_64 --release

# 复制二进制
node scripts/prepare-bin.js
```

**注意：** npm 包会包含所有平台的二进制文件，用户安装时只会使用对应平台的版本。

### 用户使用

```bash
# 从 npm 安装
npm install obscura-ts

# 或从本地 .tgz 安装
npm install ./obscura-ts-0.1.0.tgz
```

```typescript
import { ObscuraBrowser } from 'obscura-ts';

const browser = await ObscuraBrowser.launch({ stealth: true });
// SDK 会自动查找 bin/linux-x64/obscura
```

### 二进制查找逻辑

SDK 会按以下顺序查找 obscura 二进制文件：

1. 用户显式指定的 `executablePath`
2. PATH 环境变量
3. SDK 内置的 `bin/<platform>/` 目录
4. 已知的构建目录（如 `target/release/obscura`）

### 故障排查

#### 找不到 obscura 二进制

**解决方案：**
1. 检查 `bin/<platform>/` 目录是否存在
2. 确认二进制文件有执行权限：`chmod +x bin/linux-x64/obscura`
3. 手动指定路径：
   ```typescript
   const browser = await ObscuraBrowser.launch({
     executablePath: '/path/to/obscura'
   });
   ```

#### 包太大

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

## License

Apache-2.0

## Links

- [Obscura GitHub](https://github.com/h4ckf0r0day/obscura)
- [Playwright Documentation](https://playwright.dev/)
- [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/)

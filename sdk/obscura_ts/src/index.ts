/**
 * obscura-ts - TypeScript SDK for Obscura headless browser
 *
 * Provides a high-level API for browser automation using Obscura's
 * Chrome DevTools Protocol (CDP) implementation, powered by Playwright.
 *
 * @example
 * ```typescript
 * import { ObscuraBrowser } from 'obscura-ts';
 *
 * async function main() {
 *   const browser = await ObscuraBrowser.launch({ stealth: true });
 *   const page = await browser.newPage();
 *
 *   await page.goto('https://example.com');
 *   console.log(await page.title());
 *   console.log(await page.markdown());
 *
 *   await browser.close();
 * }
 *
 * main().catch(console.error);
 * ```
 *
 * @packageDocumentation
 */

// Node.js 版本检查（SDK 需要 >= 18.0.0）
const NODE_MAJOR = parseInt(process.versions.node.split('.')[0], 10);
if (NODE_MAJOR < 18) {
  const msg = `obscura-ts requires Node.js >= 18, current: ${process.version}\n`
    + `Please use Node.js 18+ to run, for example:\n`
    + `  /path/to/node-v18.20.4-linux-arm64/bin/node your_script.js\n`
    + `Or use run.sh which auto-detects the correct Node.js version.`;
  process.stderr.write(msg + '\n');
  process.exit(1);
}

// Main classes
export { ObscuraBrowser } from './browser';
export { ObscuraPage } from './page';

// Types
export {
  LaunchOptions,
  ConnectOptions,
  GotoOptions,
  WaitOptions,
  ScreenshotOptions,
  Cookie,
  NetworkRequest,
  ConsoleMessage,
  VersionInfo,
  TargetInfo,
  ResolvedLaunchOptions,
} from './types';

// Config utilities (for advanced usage)
export { DEFAULTS, resolveExecutablePath, resolveLaunchOptions } from './config';

// Launcher (for advanced usage)
export { launchObscura, LaunchedProcess } from './launcher';

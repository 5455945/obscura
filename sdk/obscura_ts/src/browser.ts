/**
 * ObscuraBrowser - Main browser class wrapping Playwright's CDP connection
 */

import { chromium, Browser, BrowserContext, Page as PlaywrightPage } from 'playwright-core';
import { LaunchOptions, ConnectOptions } from './types';
import { resolveLaunchOptions } from './config';
import { launchObscura, LaunchedProcess } from './launcher';
import { ObscuraPage } from './page';

/**
 * A browser instance connected to an obscura CDP server.
 *
 * Use `ObscuraBrowser.launch()` to start a new obscura process,
 * or `ObscuraBrowser.connect()` to connect to an existing server.
 *
 * @example
 * ```typescript
 * // Launch a new obscura process
 * const browser = await ObscuraBrowser.launch({ stealth: true });
 * const page = await browser.newPage();
 * await page.goto('https://example.com');
 * console.log(await page.title());
 * await browser.close();
 * ```
 *
 * @example
 * ```typescript
 * // Connect to an existing server
 * const browser = await ObscuraBrowser.connect({
 *   endpointURL: 'ws://127.0.0.1:9222'
 * });
 * const page = await browser.newPage();
 * ```
 */
export class ObscuraBrowser {
  private _browser: Browser;
  private _launchedProcess: LaunchedProcess | null;
  private _pages: ObscuraPage[] = [];

  private constructor(browser: Browser, launchedProcess: LaunchedProcess | null) {
    this._browser = browser;
    this._launchedProcess = launchedProcess;
  }

  /**
   * Launch a new obscura process and connect via CDP.
   *
   * @param options - Launch configuration
   * @returns Connected browser instance
   */
  static async launch(options?: LaunchOptions): Promise<ObscuraBrowser> {
    const config = resolveLaunchOptions(options);
    const launched = await launchObscura(config);

    try {
      const browser = await chromium.connectOverCDP({
        endpointURL: launched.wsEndpoint,
        timeout: config.timeout,
      });

      return new ObscuraBrowser(browser, launched);
    } catch (err) {
      // Clean up the process if connection fails
      await launched.kill();
      throw err;
    }
  }

  /**
   * Connect to an already-running obscura CDP server.
   *
   * @param options - Connection options with endpoint URL
   * @returns Connected browser instance
   */
  static async connect(options: ConnectOptions): Promise<ObscuraBrowser> {
    const browser = await chromium.connectOverCDP({
      endpointURL: options.endpointURL,
      timeout: options.timeout ?? 30000,
    });

    return new ObscuraBrowser(browser, null);
  }

  /**
   * Connect to an obscura CDP server using just a WebSocket URL string.
   *
   * @param endpointURL - WebSocket URL (e.g. "ws://127.0.0.1:9222")
   * @returns Connected browser instance
   */
  static async connectOverCDP(endpointURL: string): Promise<ObscuraBrowser> {
    return ObscuraBrowser.connect({ endpointURL });
  }

  /**
   * Create a new page (tab) in the browser.
   *
   * @returns New ObscuraPage instance
   */
  async newPage(): Promise<ObscuraPage> {
    // Get or create a browser context
    const contexts = this._browser.contexts();
    let context: BrowserContext;

    if (contexts.length > 0) {
      context = contexts[0];
    } else {
      context = await this._browser.newContext();
    }

    const playwrightPage = await context.newPage();
    const page = new ObscuraPage(playwrightPage);
    this._pages.push(page);

    // Remove from tracked pages when closed
    playwrightPage.on('close', () => {
      const idx = this._pages.indexOf(page);
      if (idx >= 0) {
        this._pages.splice(idx, 1);
      }
    });

    return page;
  }

  /**
   * Get all currently open pages.
   *
   * @returns Array of ObscuraPage instances
   */
  pages(): ObscuraPage[] {
    return [...this._pages];
  }

  /**
   * Close the browser and terminate the obscura process (if launched).
   *
   * For `connect()` instances, only disconnects from the server.
   * For `launch()` instances, also kills the obscura child process.
   */
  async close(): Promise<void> {
    // Close all tracked pages
    const closePromises = this._pages.map((p) => p.close().catch(() => {}));
    await Promise.all(closePromises);
    this._pages = [];

    // Close the browser connection
    try {
      await this._browser.close();
    } catch {
      // Browser may already be closed
    }

    // Kill the obscura process if we launched it
    if (this._launchedProcess) {
      await this._launchedProcess.kill();
      this._launchedProcess = null;
    }
  }

  /**
   * Disconnect from the CDP server without closing it.
   * Only applicable for `connect()` instances.
   */
  async disconnect(): Promise<void> {
    try {
      this._browser.close();
    } catch {
      // Already disconnected
    }
  }

  /**
   * Access the underlying Playwright Browser instance.
   *
   * Use this for advanced Playwright APIs not wrapped by ObscuraBrowser.
   */
  get playwrightBrowser(): Browser {
    return this._browser;
  }

  /**
   * Check if the browser connection is still active.
   */
  get isConnected(): boolean {
    return this._browser.isConnected();
  }

  /**
   * Get the CDP endpoint URL.
   */
  get endpointURL(): string {
    if (this._launchedProcess) {
      return this._launchedProcess.wsEndpoint;
    }
    // For connected instances, we don't track the original URL
    return 'unknown';
  }
}

/**
 * ObscuraPage - Page wrapper with obscura-specific helpers
 */

import {
  Page as PlaywrightPage,
  ElementHandle,
  Response,
  PageScreenshotOptions as PlaywrightScreenshotOptions,
} from 'playwright-core';
import { GotoOptions, ScreenshotOptions } from './types';

/**
 * A browser page wrapping Playwright's Page with obscura-specific helpers.
 *
 * Provides convenient methods for navigation, evaluation, and content extraction.
 * Access the underlying Playwright Page via `playwrightPage` for advanced APIs.
 *
 * @example
 * ```typescript
 * const page = await browser.newPage();
 * await page.goto('https://example.com');
 *
 * // Get page title
 * console.log(await page.title());
 *
 * // Evaluate JavaScript
 * const text = await page.evaluate<string>('document.querySelector("h1").textContent');
 *
 * // Get page as Markdown (obscura-specific)
 * const md = await page.markdown();
 *
 * await page.close();
 * ```
 */
export class ObscuraPage {
  private _page: PlaywrightPage;

  constructor(page: PlaywrightPage) {
    this._page = page;
  }

  /**
   * Navigate to a URL and wait for the page to load.
   *
   * @param url - The URL to navigate to
   * @param options - Navigation options
   * @returns The response from the server
   */
  async goto(url: string, options?: GotoOptions): Promise<Response | null> {
    return this._page.goto(url, {
      waitUntil: options?.waitUntil ?? 'load',
      timeout: options?.timeout,
      referer: options?.referer,
    });
  }

  /**
   * Navigate back in history.
   */
  async goBack(options?: { timeout?: number }): Promise<Response | null> {
    return this._page.goBack({
      waitUntil: 'load',
      timeout: options?.timeout,
    });
  }

  /**
   * Navigate forward in history.
   */
  async goForward(options?: { timeout?: number }): Promise<Response | null> {
    return this._page.goForward({
      waitUntil: 'load',
      timeout: options?.timeout,
    });
  }

  /**
   * Reload the current page.
   */
  async reload(options?: { timeout?: number }): Promise<Response | null> {
    return this._page.reload({
      waitUntil: 'load',
      timeout: options?.timeout,
    });
  }

  /**
   * Get the current page URL.
   */
  url(): string {
    return this._page.url();
  }

  /**
   * Get the page title.
   */
  async title(): Promise<string> {
    return this._page.title();
  }

  /**
   * Evaluate a JavaScript expression in the page context.
   *
   * @param expression - JavaScript expression or function to evaluate
   * @returns The result of the evaluation
   *
   * @example
   * ```typescript
   * const title = await page.evaluate<string>('document.title');
   * const count = await page.evaluate<number>('document.querySelectorAll("a").length');
   * const data = await page.evaluate('({ url: location.href, title: document.title })');
   * ```
   */
  async evaluate<T = unknown>(expression: string): Promise<T> {
    return this._page.evaluate(expression) as Promise<T>;
  }

  /**
   * Get the full HTML content of the page.
   */
  async content(): Promise<string> {
    return this._page.content();
  }

  /**
   * Get the page content as Markdown.
   *
   * Uses obscura's LP.getMarkdown CDP domain for high-quality
   * DOM-to-Markdown conversion.
   */
  async markdown(): Promise<string> {
    // Use the LP.getMarkdown CDP method via CDP session
    const client = await this._page.context().newCDPSession(this._page);
    try {
      const result = await client.send('LP.getMarkdown' as any);
      return (result as any).markdown || '';
    } catch {
      // Fallback: basic HTML to text extraction
      return this._page.evaluate(() => {
        return document.body?.innerText || document.body?.textContent || '';
      });
    } finally {
      await client.detach().catch(() => {});
    }
  }

  /**
   * Get the visible text content of the page body.
   */
  async textContent(): Promise<string> {
    return this._page.evaluate(() => {
      return document.body?.innerText || '';
    });
  }

  /**
   * Wait for a CSS selector to appear in the DOM.
   *
   * @param selector - CSS selector to wait for
   * @param options - Wait options
   * @returns The matched element handle
   */
  async waitForSelector(
    selector: string,
    options?: Parameters<PlaywrightPage['waitForSelector']>[1]
  ): Promise<ElementHandle<Element>> {
    const handle = await this._page.waitForSelector(selector, options as any);
    if (!handle) {
      throw new Error(`Selector "${selector}" not found`);
    }
    return handle as ElementHandle<Element>;
  }

  /**
   * Query a single element by CSS selector.
   *
   * @param selector - CSS selector
   * @returns Element handle or null if not found
   */
  async $(selector: string): Promise<ElementHandle<Element> | null> {
    return this._page.$(selector) as Promise<ElementHandle<Element> | null>;
  }

  /**
   * Query all elements matching a CSS selector.
   *
   * @param selector - CSS selector
   * @returns Array of element handles
   */
  async $$(selector: string): Promise<ElementHandle<Element>[]> {
    return this._page.$$(selector) as Promise<ElementHandle<Element>[]>;
  }

  /**
   * Query a single element and return its text content.
   *
   * @param selector - CSS selector
   * @returns Text content or empty string if not found
   */
  async $text(selector: string): Promise<string> {
    const el = await this._page.$(selector);
    if (!el) return '';
    return (await el.textContent()) || '';
  }

  /**
   * Query all matching elements and return their text contents.
   *
   * @param selector - CSS selector
   * @returns Array of text contents
   */
  async $$text(selector: string): Promise<string[]> {
    const elements = await this._page.$$(selector);
    return Promise.all(
      elements.map(async (el) => (await el.textContent()) || '')
    );
  }

  /**
   * Query a single element and return an attribute value.
   *
   * @param selector - CSS selector
   * @param name - Attribute name
   * @returns Attribute value or null
   */
  async $attr(selector: string, name: string): Promise<string | null> {
    const el = await this._page.$(selector);
    if (!el) return null;
    return el.getAttribute(name);
  }

  /**
   * Click an element matching the selector.
   *
   * @param selector - CSS selector
   * @param options - Click options
   */
  async click(selector: string, options?: { timeout?: number }): Promise<void> {
    await this._page.click(selector, { timeout: options?.timeout });
  }

  /**
   * Fill an input element with a value.
   *
   * @param selector - CSS selector for the input
   * @param value - Value to fill
   * @param options - Fill options
   */
  async fill(
    selector: string,
    value: string,
    options?: { timeout?: number }
  ): Promise<void> {
    await this._page.fill(selector, value, { timeout: options?.timeout });
  }

  /**
   * Type text into an input element (character by character).
   *
   * @param selector - CSS selector for the input
   * @param text - Text to type
   * @param options - Type options
   */
  async type(
    selector: string,
    text: string,
    options?: { delay?: number; timeout?: number }
  ): Promise<void> {
    await this._page.type(selector, text, {
      delay: options?.delay,
      timeout: options?.timeout,
    });
  }

  /**
   * Press a keyboard key.
   *
   * @param key - Key to press (e.g. "Enter", "Tab", "Escape")
   * @param options - Press options
   */
  async pressKey(key: string, options?: { selector?: string; delay?: number }): Promise<void> {
    if (options?.selector) {
      await this._page.press(options.selector, key, { delay: options.delay });
    } else {
      await this._page.keyboard.press(key, { delay: options?.delay });
    }
  }

  /**
   * Select an option in a <select> element.
   *
   * @param selector - CSS selector for the <select>
   * @param values - Option value(s) to select
   * @returns Array of selected option values
   */
  async selectOption(selector: string, values: string | string[]): Promise<string[]> {
    return this._page.selectOption(selector, values);
  }

  /**
   * Take a screenshot of the page.
   *
   * @param options - Screenshot options
   * @returns Screenshot buffer
   */
  async screenshot(options?: ScreenshotOptions): Promise<Buffer> {
    const pwOptions: PlaywrightScreenshotOptions = {
      path: options?.path,
      type: options?.type,
      quality: options?.quality,
      fullPage: options?.fullPage,
      clip: options?.clip,
    };
    return await this._page.screenshot(pwOptions);
  }

  /**
   * Wait for a specified timeout.
   *
   * @param ms - Milliseconds to wait
   */
  async waitForTimeout(ms: number): Promise<void> {
    await this._page.waitForTimeout(ms);
  }

  /**
   * Wait for a JavaScript expression to return truthy.
   *
   * @param expression - JavaScript expression to evaluate
   * @param options - Wait options
   */
  async waitForFunction(
    expression: string,
    options?: { timeout?: number; polling?: number | 'raf' }
  ): Promise<void> {
    await this._page.waitForFunction(expression, undefined, {
      timeout: options?.timeout,
      polling: options?.polling,
    });
  }

  /**
   * Close the page.
   */
  async close(): Promise<void> {
    await this._page.close();
  }

  /**
   * Bring the page to front (activate the tab).
   */
  async bringToFront(): Promise<void> {
    await this._page.bringToFront();
  }

  /**
   * Set the viewport size.
   */
  async setViewportSize(width: number, height: number): Promise<void> {
    await this._page.setViewportSize({ width, height });
  }

  /**
   * Get the current viewport size.
   */
  viewportSize(): { width: number; height: number } | null {
    return this._page.viewportSize();
  }

  /**
   * Check if the page is closed.
   */
  get isClosed(): boolean {
    return this._page.isClosed();
  }

  /**
   * Access the underlying Playwright Page instance.
   *
   * Use this for advanced Playwright APIs not wrapped by ObscuraPage.
   */
  get playwrightPage(): PlaywrightPage {
    return this._page;
  }
}

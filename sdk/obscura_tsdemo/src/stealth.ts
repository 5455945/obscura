/**
 * Stealth mode demo - Test anti-detection features
 *
 * Run: npm run demo:stealth
 */

import { ObscuraBrowser } from 'obscura-ts';

async function testStealthMode() {
  console.log('=== obscura-ts Demo: Stealth Mode ===\n');

  // Launch with stealth mode enabled
  const browser = await ObscuraBrowser.launch({
    stealth: true,
    quiet: true,
  });

  try {
    const page = await browser.newPage();

    // Test 1: navigator.webdriver should be undefined
    console.log('--- Anti-Detection Tests ---\n');

    const webdriver = await page.evaluate('navigator.webdriver');
    console.log(`navigator.webdriver: ${webdriver} ${webdriver === undefined ? '(PASS)' : '(FAIL - should be undefined)'}`);

    // Test 2: Check User-Agent
    const userAgent = await page.evaluate<string>('navigator.userAgent');
    console.log(`User-Agent: ${userAgent}`);
    console.log(`  Contains "HeadlessChrome": ${userAgent.includes('HeadlessChrome') ? '(FAIL)' : '(PASS)'}`);

    // Test 3: Check plugins
    const pluginCount = await page.evaluate<number>('navigator.plugins.length');
    console.log(`navigator.plugins.length: ${pluginCount} ${pluginCount > 0 ? '(PASS)' : '(FAIL)'}`);

    // Test 4: Check languages
    const languages = await page.evaluate<string[]>('Array.from(navigator.languages)');
    console.log(`navigator.languages: ${JSON.stringify(languages)}`);

    // Test 5: Check platform
    const platform = await page.evaluate<string>('navigator.platform');
    console.log(`navigator.platform: ${platform}`);

    // Test 6: Check WebGL vendor/renderer (fingerprinting vectors)
    const webglInfo = await page.evaluate(`
      (function() {
        try {
          const canvas = document.createElement('canvas');
          const gl = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
          if (!gl) return { vendor: 'N/A', renderer: 'N/A' };
          const debugInfo = gl.getExtension('WEBGL_debug_renderer_info');
          if (!debugInfo) return { vendor: 'N/A', renderer: 'N/A' };
          return {
            vendor: gl.getParameter(debugInfo.UNMASKED_VENDOR_WEBGL),
            renderer: gl.getParameter(debugInfo.UNMASKED_RENDERER_WEBGL),
          };
        } catch(e) {
          return { vendor: 'error', renderer: 'error' };
        }
      })()
    `);
    console.log(`WebGL vendor: ${(webglInfo as any).vendor}`);
    console.log(`WebGL renderer: ${(webglInfo as any).renderer}`);

    // Test 7: Visit a bot detection test page
    console.log('\n--- Bot Detection Test ---');
    console.log('Navigating to https://bot.sannysoft.com/...');

    await page.goto('https://bot.sannysoft.com');
    await page.waitForTimeout(3000); // Wait for page to fully render

    // Extract test results from the page
    const testResults = await page.evaluate(`
      (function() {
        const rows = document.querySelectorAll('table tr');
        const results = [];
        rows.forEach(row => {
          const cells = row.querySelectorAll('td');
          if (cells.length >= 2) {
            const name = cells[0]?.textContent?.trim();
            const value = cells[1]?.textContent?.trim();
            const passed = cells[1]?.classList?.contains('passed');
            const failed = cells[1]?.classList?.contains('failed');
            if (name && value) {
              results.push({ name, value, passed: !!passed, failed: !!failed });
            }
          }
        });
        return results;
      })()
    `);

    console.log('\nTest Results:');
    const results = testResults as Array<{ name: string; value: string; passed: boolean; failed: boolean }>;
    results.forEach(r => {
      const status = r.passed ? 'PASS' : r.failed ? 'FAIL' : 'INFO';
      console.log(`  [${status}] ${r.name}: ${r.value}`);
    });

    // Test 8: Take a screenshot for visual verification
    console.log('\nTaking screenshot...');
    const screenshot = await page.screenshot({ fullPage: true });
    console.log(`Screenshot captured: ${screenshot.length} bytes`);

    await page.close();
  } finally {
    await browser.close();
  }

  console.log('\nStealth mode demo complete!');
}

async function main() {
  try {
    await testStealthMode();
  } catch (err) {
    console.error('Error:', err);
    process.exit(1);
  }
}

main();

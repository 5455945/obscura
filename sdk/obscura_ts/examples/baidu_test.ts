/**
 * Baidu test - Verify obscura-ts works with www.baidu.com
 *
 * 简化版本：避免使用 obscura 不支持的 CDP 方法（如 scrollIntoViewIfNeeded）
 * 专注于验证核心功能：导航、内容获取、JavaScript 执行
 *
 * Run: npx ts-node examples/baidu_test.ts
 */

import { ObscuraBrowser } from 'obscura-ts';

async function main() {
  console.log('=== obscura-ts Baidu Test ===\n');

  // Launch obscura browser
  console.log('[1/5] Launching obscura browser...');
  const startTime = Date.now();
  const browser = await ObscuraBrowser.launch({
    stealth: true,
    quiet: true, // 隐藏 obscura 日志，减少输出噪音
  });
  console.log(`  ✓ Browser launched in ${Date.now() - startTime}ms`);
  console.log(`  ✓ Endpoint: ${browser.endpointURL}`);
  console.log(`  ✓ Connected: ${browser.isConnected}\n`);

  try {
    // Create a new page
    console.log('[2/5] Creating new page...');
    const page = await browser.newPage();
    console.log('  ✓ Page created\n');

    // Navigate to baidu.com
    console.log('[3/5] Navigating to https://www.baidu.com...');
    const navStart = Date.now();
    await page.goto('https://www.baidu.com', { timeout: 30000 });
    console.log(`  ✓ Navigated in ${Date.now() - navStart}ms`);
    console.log(`  ✓ URL: ${page.url()}`);
    console.log(`  ✓ Title: ${await page.title()}\n`);

    // Evaluate JavaScript
    console.log('[4/5] Evaluating JavaScript...');
    const searchInput = await page.$('#kw');
    console.log(`  ✓ Search input found: ${!!searchInput}`);

    const searchButton = await page.$('#su');
    console.log(`  ✓ Search button found: ${!!searchButton}`);

    // 使用 JavaScript 直接获取页面信息
    const pageInfo = await page.evaluate(`
      ({
        title: document.title,
        url: location.href,
        inputExists: !!document.querySelector('#kw'),
        buttonExists: !!document.querySelector('#su'),
        bodyTextLength: document.body.innerText.length
      })
    `);
    console.log(`  ✓ Page info:`, pageInfo);

    // Get page content summary (avoid getting full HTML which can hang on large pages)
    console.log('\n[5/5] Getting page summary...');
    const summary = await page.evaluate(`
      ({
        htmlLength: document.documentElement.outerHTML.length,
        bodyTextPreview: document.body.innerText.substring(0, 100).replace(/\\n/g, ' '),
        linkCount: document.querySelectorAll('a').length,
        imageCount: document.querySelectorAll('img').length
      })
    `) as { htmlLength: number; bodyTextPreview: string; linkCount: number; imageCount: number };
    console.log(`  ✓ HTML length: ${summary.htmlLength} characters`);
    console.log(`  ✓ Text preview: ${summary.bodyTextPreview}...`);
    console.log(`  ✓ Links: ${summary.linkCount}, Images: ${summary.imageCount}`);

    await page.close();
    console.log('\n✓ Page closed');
  } finally {
    await browser.close();
    console.log('✓ Browser closed');
  }

  console.log(`\n=== Total time: ${Date.now() - startTime}ms ===`);
  console.log('=== Test PASSED ✓ ===');
}

main().catch((err) => {
  console.error('\n✗ Test FAILED:', err);
  process.exit(1);
});

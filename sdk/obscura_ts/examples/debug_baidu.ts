/**
 * 诊断脚本 — 验证核心功能
 */

import { ObscuraBrowser } from 'obscura-ts';

async function main() {
  console.log('=== 诊断测试 ===\n');

  const browser = await ObscuraBrowser.launch({
    stealth: true,
    quiet: true,
  });

  try {
    const page = await browser.newPage();

    console.log('[1] 导航到百度...');
    await page.goto('https://www.baidu.com', { timeout: 30000 });
    console.log('  ✓ 导航完成\n');

    console.log('[2] 测试 page.title()...');
    const title = await page.title();
    console.log(`  ✓ 标题: ${title}\n`);

    console.log('[3] 测试 page.$()...');
    const searchInput = await page.$('#kw');
    console.log(`  ✓ 搜索框: ${!!searchInput}\n`);

    console.log('[4] 测试 page.evaluate()...');
    const text = await page.evaluate('document.body.innerText.substring(0, 100)');
    console.log(`  ✓ 文本预览: ${text}\n`);

    console.log('[5] 测试 page.content()...');
    const html = await page.content();
    console.log(`  ✓ HTML 长度: ${html.length} 字符\n`);

    await page.close();
    console.log('✓ 所有测试完成');

  } finally {
    await browser.close();
  }
}

main().catch((err) => {
  console.error('✗ 失败:', err);
  process.exit(1);
});

/**
 * 测试 userAgent 配置
 */

import { ObscuraBrowser } from 'obscura-ts';

async function main() {
  console.log('=== 测试 UserAgent 配置 ===\n');

  const customUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36';

  console.log('1. 启动浏览器（自定义 UserAgent）...');
  console.log(`   设置的 UserAgent: ${customUserAgent}\n`);

  const browser = await ObscuraBrowser.launch({
    userAgent: customUserAgent,
    quiet: false,
  });

  try {
    const page = await browser.newPage();

    console.log('2. 导航到百度...');
    await page.goto('https://www.baidu.com');
    console.log('   ✓ 导航成功\n');

    console.log('3. 检查 navigator.userAgent...');
    const actualUserAgent = await page.evaluate<string>('navigator.userAgent');
    console.log(`   实际 UserAgent: ${actualUserAgent}\n`);

    console.log('4. 验证结果...');
    if (actualUserAgent === customUserAgent) {
      console.log('   ✓ UserAgent 配置成功！完全匹配\n');
    } else {
      console.log('   ✗ UserAgent 不匹配\n');
      console.log('   期望:', customUserAgent);
      console.log('   实际:', actualUserAgent);
    }

    await page.close();
  } finally {
    await browser.close();
  }

  console.log('\n=== 测试完成 ===');
}

main().catch((err) => {
  console.error('测试失败:', err);
  process.exit(1);
});

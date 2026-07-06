/**
 * 简化版百度测试 - 验证 obscura-ts 核心功能
 *
 * 测试内容：
 * 1. 启动 obscura 浏览器
 * 2. 创建页面
 * 3. 导航到 baidu.com
 * 4. 获取页面标题
 * 5. 执行 JavaScript
 * 6. 关闭浏览器
 */

import { ObscuraBrowser } from 'obscura-ts';

async function main() {
  console.log('=== obscura-ts 百度测试（简化版）===\n');

  // 1. 启动浏览器
  console.log('[1/6] 启动 obscura 浏览器...');
  const startTime = Date.now();
  const browser = await ObscuraBrowser.launch({
    stealth: true,
    quiet: true,
  });
  console.log(`  ✓ 浏览器启动成功 (${Date.now() - startTime}ms)`);
  console.log(`  ✓ 端点: ${browser.endpointURL}`);
  console.log(`  ✓ 连接状态: ${browser.isConnected}\n`);

  try {
    // 2. 创建页面
    console.log('[2/6] 创建新页面...');
    const page = await browser.newPage();
    console.log('  ✓ 页面创建成功\n');

    // 3. 导航到百度
    console.log('[3/6] 导航到 https://www.baidu.com...');
    const navStart = Date.now();
    await page.goto('https://www.baidu.com', { timeout: 30000 });
    console.log(`  ✓ 导航完成 (${Date.now() - navStart}ms)`);
    console.log(`  ✓ URL: ${page.url()}`);
    console.log(`  ✓ 标题: ${await page.title()}\n`);

    // 4. 验证页面元素
    console.log('[4/6] 验证页面元素...');
    const searchInput = await page.$('#kw');
    console.log(`  ✓ 搜索框: ${searchInput ? '找到' : '未找到'}`);

    const searchButton = await page.$('#su');
    console.log(`  ✓ 搜索按钮: ${searchButton ? '找到' : '未找到'}\n`);

    // 5. 执行 JavaScript
    console.log('[5/6] 执行 JavaScript...');
    const pageInfo = await page.evaluate(`
      ({
        title: document.title,
        url: location.href,
        hasSearchInput: !!document.querySelector('#kw'),
        hasSearchButton: !!document.querySelector('#su'),
        bodyTextLength: document.body.innerText.length
      })
    `) as {
      title: string;
      url: string;
      hasSearchInput: boolean;
      hasSearchButton: boolean;
      bodyTextLength: number;
    };
    console.log('  ✓ 页面信息:');
    console.log(`    - 标题: ${pageInfo.title}`);
    console.log(`    - URL: ${pageInfo.url}`);
    console.log(`    - 搜索框: ${pageInfo.hasSearchInput ? '存在' : '不存在'}`);
    console.log(`    - 搜索按钮: ${pageInfo.hasSearchButton ? '存在' : '不存在'}`);
    console.log(`    - 页面文本长度: ${pageInfo.bodyTextLength} 字符\n`);

    // 6. 关闭页面
    console.log('[6/6] 关闭页面...');
    await page.close();
    console.log('  ✓ 页面关闭成功\n');

  } finally {
    // 关闭浏览器
    await browser.close();
    console.log('✓ 浏览器关闭成功\n');
  }

  console.log(`=== 测试完成 (${Date.now() - startTime}ms) ===`);
  console.log('=== ✓ 所有测试通过 ===');
}

main().catch((err) => {
  console.error('\n✗ 测试失败:', err);
  process.exit(1);
});

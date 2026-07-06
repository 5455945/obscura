/**
 * 验证 obscura-ts SDK 包是否正常工作
 */

import { ObscuraBrowser } from 'obscura-ts';

async function main() {
  console.log('=== 验证 obscura-ts SDK 包 ===\n');

  // 启动浏览器
  console.log('1. 启动 obscura 浏览器...');
  const browser = await ObscuraBrowser.launch({
    stealth: true,
    quiet: true,
  });
  console.log('   ✓ 浏览器启动成功\n');

  // 创建页面
  console.log('2. 创建新页面...');
  const page = await browser.newPage();
  console.log('   ✓ 页面创建成功\n');

  // 导航到百度
  console.log('3. 导航到 https://www.baidu.com...');
  await page.goto('https://www.baidu.com');
  console.log('   ✓ 导航成功\n');

  // 获取页面标题
  console.log('4. 获取页面标题...');
  const title = await page.title();
  console.log(`   ✓ 标题: ${title}\n`);

  // 执行 JavaScript
  console.log('5. 执行 JavaScript...');
  const result = await page.evaluate('document.querySelector("#kw") !== null');
  console.log(`   ✓ 搜索框存在: ${result}\n`);

  // 关闭浏览器
  console.log('6. 关闭浏览器...');
  await browser.close();
  console.log('   ✓ 浏览器已关闭\n');

  console.log('=== 验证完成 ===');
  console.log('obscura-ts SDK 包工作正常！');
}

main().catch((error) => {
  console.error('验证失败:', error);
  process.exit(1);
});

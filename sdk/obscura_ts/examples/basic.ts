/**
 * Basic usage example for obscura-ts SDK
 *
 * Run: npx ts-node examples/basic.ts
 */

import { ObscuraBrowser } from 'obscura-ts';

async function main() {
  console.log('=== obscura-ts Basic Example ===\n');

  // Launch obscura with stealth mode
  console.log('Launching obscura browser...');
  const browser = await ObscuraBrowser.launch({
    stealth: true,
    // verbose: true,  // Uncomment to see obscura logs
  });

  try {
    // Create a new page
    const page = await browser.newPage();
    console.log('New page created\n');

    // Navigate to example.com
    console.log('Navigating to https://example.com...');
    await page.goto('https://example.com');
    console.log(`  Page URL: ${page.url()}`);
    console.log(`  Page title: ${await page.title()}\n`);

    // Evaluate JavaScript
    const heading = await page.evaluate<string>('document.querySelector("h1")?.textContent');
    console.log(`H1 text: ${heading}`);

    // Get full HTML
    const html = await page.content();
    console.log(`\nHTML length: ${html.length} characters`);
    console.log('HTML preview (first 200 chars):');
    console.log(html.substring(0, 200));

    // Close the page
    await page.close();
    console.log('\nPage closed');

  } finally {
    // Always close the browser
    await browser.close();
    console.log('Browser closed');
  }
}

main().catch((err) => {
  console.error('Error:', err);
  process.exit(1);
});

/**
 * Basic demo - Navigate to a page and extract information
 *
 * Run: npm run demo:basic
 */

import { ObscuraBrowser } from 'obscura-ts';

async function main() {
  console.log('=== obscura-ts Demo: Basic Usage ===\n');

  // Launch obscura browser
  const browser = await ObscuraBrowser.launch({
    stealth: true,
    quiet: true, // Suppress obscura logs
  });

  try {
    const page = await browser.newPage();

    // Navigate to example.com
    console.log('Navigating to https://example.com...');
    await page.goto('https://example.com');

    // Extract page information
    const title = await page.title();
    const url = page.url();
    console.log(`Title: ${title}`);
    console.log(`URL: ${url}`);

    // Get the main heading
    const h1 = await page.$text('h1');
    console.log(`H1: ${h1}`);

    // Count links
    const links = await page.$$('a');
    console.log(`Links found: ${links.length}`);

    // Get all link texts and hrefs
    console.log('\nLinks:');
    for (const link of links) {
      const text = (await link.textContent())?.trim() || '(no text)';
      const href = await link.getAttribute('href');
      console.log(`  ${text}: ${href}`);
    }

    // Get page content
    console.log('\n--- Page Content ---');
    const textContent = await page.textContent();
    console.log(textContent.slice(0, 500)); // First 500 chars

    await page.close();
  } finally {
    await browser.close();
  }

  console.log('\nDemo complete!');
}

main().catch(console.error);

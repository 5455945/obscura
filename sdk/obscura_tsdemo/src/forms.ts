/**
 * Forms demo - Fill forms and handle login flows
 *
 * Run: npm run demo:forms
 */

import { ObscuraBrowser } from 'obscura-ts';

async function demoFormFilling() {
  console.log('=== obscura-ts Demo: Form Filling ===\n');

  const browser = await ObscuraBrowser.launch({ stealth: true, quiet: true });

  try {
    const page = await browser.newPage();

    // Navigate to a test form page
    console.log('Navigating to test form...');
    await page.goto('https://httpbin.org/forms/post');

    // Wait for form to load
    await page.waitForSelector('form');

    // Fill form fields
    console.log('Filling form fields...');

    // Text input
    await page.fill('input[name="custname"]', 'John Doe');
    console.log('  Filled: custname = John Doe');

    // Telephone
    await page.fill('input[name="custtel"]', '+1-555-0123');
    console.log('  Filled: custtel = +1-555-0123');

    // Email
    await page.fill('input[name="custemail"]', 'john@example.com');
    console.log('  Filled: custemail = john@example.com');

    // Radio button (select by clicking)
    await page.click('input[name="size"][value="medium"]');
    console.log('  Selected: size = medium');

    // Checkbox
    await page.click('input[name="topping"][value="cheese"]');
    await page.click('input[name="topping"][value="mushroom"]');
    console.log('  Checked: topping = cheese, mushroom');

    // Textarea
    await page.fill('textarea[name="comments"]', 'Please deliver after 6pm.');
    console.log('  Filled: comments = Please deliver after 6pm.');

    // Time input
    await page.fill('input[name="delivery"]', '18:30');
    console.log('  Filled: delivery = 18:30');

    // Submit the form by clicking the button
    console.log('\nSubmitting form...');
    await page.click('button[type="submit"]');

    // Wait for response
    await page.waitForSelector('body');

    // Check the response
    const responseText = await page.textContent();
    console.log('\n--- Form Response ---');
    console.log(responseText.slice(0, 500));

    await page.close();
  } finally {
    await browser.close();
  }
}

async function demoLoginFlow() {
  console.log('\n=== obscura-ts Demo: Login Flow ===\n');

  const browser = await ObscuraBrowser.launch({ stealth: true, quiet: true });

  try {
    const page = await browser.newPage();

    // Navigate to quotes.toscrape.com login page
    console.log('Navigating to login page...');
    await page.goto('https://quotes.toscrape.com/login');

    // Wait for form
    await page.waitForSelector('form');

    // Fill credentials
    console.log('Filling login credentials...');
    await page.fill('input[name="username"]', 'admin');
    await page.fill('input[name="password"]', 'admin');

    // Click login button
    console.log('Clicking login button...');
    await page.click('input[type="submit"]');

    // Wait for navigation (redirect after login)
    await page.waitForTimeout(2000);

    // Verify login success
    const currentUrl = page.url();
    console.log(`After login URL: ${currentUrl}`);

    // Check for logout link (indicates successful login)
    const logoutLink = await page.$('a[href="/logout"]');
    if (logoutLink) {
      console.log('Login successful! (logout link found)');
    } else {
      console.log('Login may have failed (no logout link found)');
    }

    // Get page title
    const title = await page.title();
    console.log(`Page title: ${title}`);

    // Extract some quotes (now logged in)
    const quotes = await page.evaluate(`
      (function() {
        const quoteEls = document.querySelectorAll('.quote');
        return Array.from(quoteEls).slice(0, 3).map(el => {
          const text = el.querySelector('.text')?.textContent?.trim() || '';
          const author = el.querySelector('.author')?.textContent?.trim() || '';
          return { text, author };
        });
      })()
    `);

    console.log('\n--- Quotes (first 3) ---');
    (quotes as Array<{ text: string; author: string }>).forEach((q, i) => {
      console.log(`${i + 1}. "${q.text}"`);
      console.log(`   - ${q.author}\n`);
    });

    await page.close();
  } finally {
    await browser.close();
  }
}

async function main() {
  try {
    await demoFormFilling();
    await demoLoginFlow();
  } catch (err) {
    console.error('Error:', err);
    process.exit(1);
  }

  console.log('\nForms demo complete!');
}

main();

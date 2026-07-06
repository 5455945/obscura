/**
 * Scraping demo - Extract structured data from multiple pages
 *
 * Run: npm run demo:scrape
 */

import { ObscuraBrowser } from 'obscura-ts';

interface ArticleData {
  title: string;
  url: string;
  score: string;
  author: string;
  comments: string;
}

async function scrapeHackerNews(): Promise<ArticleData[]> {
  const browser = await ObscuraBrowser.launch({ stealth: true, quiet: true });

  try {
    const page = await browser.newPage();

    console.log('Navigating to Hacker News...');
    await page.goto('https://news.ycombinator.com');

    // Wait for articles to load
    await page.waitForSelector('.titleline');

    // Extract article data
    const articles: ArticleData[] = await page.evaluate(`
      (function() {
        const items = document.querySelectorAll('.athing');
        return Array.from(items).slice(0, 10).map(item => {
          const titleEl = item.querySelector('.titleline > a');
          const subtextEl = item.nextElementSibling;
          const scoreEl = subtextEl?.querySelector('.score');
          const authorEl = subtextEl?.querySelector('.hnuser');
          const commentsEl = subtextEl?.querySelector('a:last-child');

          return {
            title: titleEl?.textContent || '',
            url: titleEl?.href || '',
            score: scoreEl?.textContent || '0 points',
            author: authorEl?.textContent || 'unknown',
            comments: commentsEl?.textContent || '0 comments',
          };
        });
      })()
    `);

    await page.close();
    return articles as unknown as ArticleData[];
  } finally {
    await browser.close();
  }
}

async function scrapeGitHubTrending(): Promise<Array<{ repo: string; description: string; stars: string }>> {
  const browser = await ObscuraBrowser.launch({ stealth: true, quiet: true });

  try {
    const page = await browser.newPage();

    console.log('Navigating to GitHub Trending...');
    await page.goto('https://github.com/trending');

    // Wait for repos to load
    await page.waitForSelector('article.Box-row');

    // Extract repo data
    const repos = await page.evaluate(`
      (function() {
        const rows = document.querySelectorAll('article.Box-row');
        return Array.from(rows).slice(0, 10).map(row => {
          const repoEl = row.querySelector('h2 a');
          const descEl = row.querySelector('p');
          const starsEl = row.querySelector('[href$="/stargazers"]');

          return {
            repo: repoEl?.textContent?.replace(/\\s+/g, '') || '',
            description: descEl?.textContent?.trim() || '',
            stars: starsEl?.textContent?.trim() || '0',
          };
        });
      })()
    `);

    await page.close();
    return repos as unknown as Array<{ repo: string; description: string; stars: string }>;
  } finally {
    await browser.close();
  }
}

async function main() {
  console.log('=== obscura-ts Demo: Web Scraping ===\n');

  // Scrape Hacker News
  console.log('--- Hacker News Top Stories ---');
  try {
    const hnArticles = await scrapeHackerNews();
    hnArticles.forEach((article, i) => {
      console.log(`\n${i + 1}. ${article.title}`);
      console.log(`   ${article.score} | ${article.author} | ${article.comments}`);
      console.log(`   ${article.url}`);
    });
  } catch (err) {
    console.error('Failed to scrape Hacker News:', err);
  }

  console.log('\n');

  // Scrape GitHub Trending
  console.log('--- GitHub Trending Repos ---');
  try {
    const ghRepos = await scrapeGitHubTrending();
    ghRepos.forEach((repo, i) => {
      console.log(`\n${i + 1}. ${repo.repo}`);
      console.log(`   ${repo.description}`);
      console.log(`   Stars: ${repo.stars}`);
    });
  } catch (err) {
    console.error('Failed to scrape GitHub Trending:', err);
  }

  console.log('\n\nScraping demo complete!');
}

main().catch(console.error);

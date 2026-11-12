// One JSONL job interface for stills and movie frames.
const fs = require('fs');
const { pathToFileURL } = require('url');

(async () => {
  let browser;
  try {
    const { chromium } = require('playwright');
    browser = await chromium.launch();
    if (process.argv[2] === '--check') return;
    const pages = new Map();
    const lines = require('readline').createInterface({
      input: fs.createReadStream(process.argv[2]), crlfDelay: Infinity,
    });
    for await (const line of lines) {
      const job = JSON.parse(line);
      if (!pages.has(job.scale)) {
        pages.set(job.scale, await browser.newPage({
          deviceScaleFactor: job.scale, viewport: { width: 2200, height: 1400 },
        }));
      }
      const page = pages.get(job.scale);
      await page.goto(pathToFileURL(job.html).href);
      await page.evaluate(() => document.fonts.ready);
      await page.locator('#t').screenshot({ path: job.png, omitBackground: !job.opaque });
    }
  } catch (error) {
    console.error('frames_png: ' + String(error.message).split('\n').join(' '));
    process.exitCode = 1;
  } finally {
    if (browser) await browser.close();
  }
})();

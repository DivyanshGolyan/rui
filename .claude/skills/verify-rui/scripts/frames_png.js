// Render only the frames in the index (never index.html itself).
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');

(async () => {
  let browser;
  try {
    const { chromium } = require('playwright');
    browser = await chromium.launch();
    if (process.argv[2] === '--check') return;
    const dir = path.resolve(process.argv[2]);
    const frames = JSON.parse(fs.readFileSync(path.join(dir, 'frames.json'), 'utf8'));
    const page = await browser.newPage({ deviceScaleFactor: 2, viewport: { width: 2200, height: 1400 } });
    for (const frame of frames) {
      if (!frame.files.html) continue;
      const src = path.join(dir, frame.files.html);
      const out = src.replace(/\.html$/, '.png');
      await page.goto(pathToFileURL(src).href);
      await page.evaluate(() => document.fonts.ready);
      await page.locator('#t').screenshot({ path: out, omitBackground: true });
    }
    // One page for the entire recording batch, using the exact still HTML.
    const movie = await browser.newPage({ deviceScaleFactor: 1, viewport: { width: 2200, height: 1400 } });
    for (const frame of frames) {
      if (!frame.files.recording) continue;
      const recording = JSON.parse(fs.readFileSync(path.join(dir, frame.files.recording), 'utf8'));
      for (const commit of recording.playback) {
        if (!commit.html) continue; // Consecutive identical cells are a hold.
        const src = path.join(dir, commit.html);
        await movie.goto(pathToFileURL(src).href);
        await movie.evaluate(() => document.fonts.ready);
        // An opaque canvas lets GIF reserve transparency for unchanged pixels,
        // rather than clearing and re-encoding the whole picture each frame.
        await movie.locator('#t').screenshot({ path: src.replace(/\.html$/, '.png'), omitBackground: false });
      }
    }
  } catch (error) {
    console.error('frames_png: ' + String(error.message).split('\n').join(' '));
    process.exitCode = 1;
  } finally {
    if (browser) await browser.close();
  }
})();

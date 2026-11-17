// Records docs/demo.gif from the made-up chats in headless WebKit: `node tests/demo.mjs` (needs ffmpeg).
import { webkit } from '/Users/mr/node_modules/playwright/index.mjs';
import { readFileSync, mkdtempSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { stub } from './stub.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dir = mkdtempSync(join(tmpdir(), 'one-text-demo-'));
const size = { width: 1100, height: 720 };
const browser = await webkit.launch();
const context = await browser.newContext({ viewport: size, deviceScaleFactor: 2, recordVideo: { dir, size } });
const page = await context.newPage();
await page.addInitScript(stub);
await page.route('http://chats.test/**', r => {
  const file = new URL(r.request().url()).pathname.slice(1) || 'index.html';
  r.fulfill({ body: readFileSync(join(root, 'ui', file)), contentType: { html: 'text/html', css: 'text/css', js: 'text/javascript' }[file.split('.').pop()] });
});
await page.goto('http://chats.test/index.html');
await page.waitForSelector('#people .row');
const pause = ms => page.waitForTimeout(ms);
const start = Date.now();

// Lea: Instagram and WhatsApp in one thread, the reel as a card.
await page.click('#people .row[data-id="ig-lea"]');
await pause(400);
await page.$eval('#thread .bubble.reel img', i => (i.src = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 9 16"><defs><linearGradient id="g" x2="0" y2="1"><stop stop-color="#f58529"/><stop offset=".5" stop-color="#dd2a7b"/><stop offset="1" stop-color="#515bd4"/></linearGradient></defs><rect width="9" height="16" fill="url(#g)"/></svg>')));
await pause(1400);
// Hover a message: the reaction bar.
await page.hover('#thread .msg:last-child .bubble');
await pause(1300);
// Reply: typed here, it goes to the ringed app.
await page.click('#input');
await page.keyboard.type('on my way', { delay: 60 });
await page.keyboard.press('Enter');
await pause(1400);
// Hugo, on Instagram and LinkedIn: the menu under the name, centred.
await page.mouse.move(10, 700);
await page.click('#people .row:has-text("Hugo R")');
await pause(700);
await page.click('header .who > b');
await pause(2200);
await page.keyboard.press('Escape');
await pause(500);
// ⌘D: everyone, by name or app.
await page.keyboard.press('Meta+d');
await pause(300);
await page.keyboard.type('to', { delay: 120 });
await pause(1500);
await page.keyboard.press('Escape');
await pause(500);
// Settings: the reel switch and every shortcut.
await page.click('#gear');
await pause(2600);
await page.keyboard.press('Escape');
await pause(600);

const skip = ((Date.now() - start) / 1000).toFixed(2), video = await page.video().path();
await context.close();
await browser.close();
const total = Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', video]).toString());
const from = Math.max(0, total - Number(skip)).toFixed(2);
const out = join(root, 'docs/demo.gif');
execFileSync('ffmpeg', ['-y', '-v', 'error', '-ss', from, '-i', video, '-vf', 'fps=15,scale=880:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle', out]);
console.log(out, readdirSync(dir).length, 'video(s), from', from, 's of', total.toFixed(2));

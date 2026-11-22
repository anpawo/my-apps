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
// What a long-used One Text holds: favorites, three groups, the chat open last, the most used reactions.
await page.addInitScript(() => {
  localStorage.favs = JSON.stringify(['ig-lea', 'wa-lea', 'sm-chloe', 'ig-chloe', 'wa-mom', 'grp-1']);
  localStorage.tabs = JSON.stringify([{ name: 'Friends', ids: ['dc-tom', 'wa-tom', 'dc-max', 'ig-zoe', 'sc-jules'] }, { name: 'Family', ids: ['wa-dad', 'wa-alice', 'wa-grandma'] },
    { name: 'Work', ids: ['te-sarah', 'te-emma', 'ig-hugo', 'li-hugo', 'li-anna', 'mx-noah'] }]);
  localStorage.lastChat = 'ig-lea';
  localStorage.reactCount = JSON.stringify({ '❤️': 9, '😂': 7, '👍': 4, '🔥': 3, '😮': 2 });
  // The recording has no pointer and no window: a drawn pointer, and the traffic lights the Mac window puts over the side bar.
  addEventListener('DOMContentLoaded', () => {
    document.body.insertAdjacentHTML('beforeend', `<div style="position:fixed;left:20px;top:15px;display:flex;gap:8px;z-index:99">${['#ff5f57', '#febc2e', '#28c840'].map(c => `<i style="width:12px;height:12px;border-radius:50%;background:${c}"></i>`).join('')}</div>
      <svg id="pointer" viewBox="0 0 12 18" style="position:fixed;left:0;top:0;width:14px;z-index:100;pointer-events:none;transform:translate(-50px,-50px)"><path d="M1 1v14l3.5-3.5 2.5 5.5 2-1-2.5-5.2H11z" fill="#000" stroke="#fff" stroke-width="1.2"/></svg>`);
    addEventListener('pointermove', e => (document.getElementById('pointer').style.transform = `translate(${e.clientX - 1}px, ${e.clientY - 1}px)`), true);
  });
});
await page.addInitScript(stub, true);
await page.route('http://chats.test/**', r => {
  const file = new URL(r.request().url()).pathname.slice(1) || 'index.html';
  r.fulfill({ body: readFileSync(join(root, 'ui', file)), contentType: { html: 'text/html', css: 'text/css', js: 'text/javascript', png: 'image/png', json: 'application/json' }[file.split('.').pop()] });
});
await page.goto('http://chats.test/index.html');
await page.waitForSelector('#thread .msg');
await page.mouse.move(800, 300);
const pause = ms => page.waitForTimeout(ms);
const glide = async (sel, dx = 0) => { const b = await page.locator(sel).boundingBox(); await page.mouse.move(b.x + b.width / 2 + dx, b.y + b.height / 2, { steps: 12 }); };
const start = Date.now();

// At launch: favorites on top, the groups above them, Lea's Instagram and WhatsApp in one thread.
await pause(2000);
// Up the thread: yesterday's reel card, and her reaction on my message.
const scroll = top => page.$eval('#msgs', (b, top) => b.scrollTo({ top: top ?? b.scrollHeight, behavior: 'smooth' }), top);
await page.mouse.move(800, 400, { steps: 6 });
await scroll(0);
await pause(2000);
await scroll();
await pause(800);
// The reaction bar at the bubble's edge: a heart on her last message.
const last = '#thread .msg:not(.me):last-of-type .bubble';
const b = await page.locator(last).boundingBox();
await page.mouse.move(b.x + b.width - 3, b.y + b.height / 2, { steps: 15 });
await pause(900);
await glide('#thread .msg:not(.me):last-of-type .quick button[data-e="❤️"]');
await page.mouse.down();
await page.mouse.up();
await pause(900);
// A reply, typed here, goes out on the ringed app.
await page.click('#input');
await page.keyboard.type('on my way', { delay: 60 });
await page.keyboard.press('Enter');
await pause(1400);
// Friends unfolds; the Flat 4B group chat is dragged into it.
await glide('.group[data-name="Friends"] .grouptile');
await page.mouse.down();
await page.mouse.up();
await pause(1300);
await glide('#people .row[data-id="grp-3"]');
await page.mouse.down();
await glide('.group[data-name="Friends"] .strip');
await pause(300);
await page.mouse.up();
await pause(1400);
// tom, from the group: a voice message, Discord formatting, a deleted message kept dimmed.
await glide('.group[data-name="Friends"] .fav[title="tom"]');
await page.mouse.down();
await page.mouse.up();
await pause(2600);
// ⌘D: everyone, by name or app; Hugo, on Instagram and LinkedIn, then the menu under his name.
await page.keyboard.press('Meta+d');
await pause(300);
await page.keyboard.type('hu', { delay: 140 });
await pause(1100);
await page.keyboard.press('Enter');
await pause(900);
await glide('header .who > b');
await page.mouse.down();
await page.mouse.up();
await pause(2600);
await page.keyboard.press('Escape');
await pause(400);
// Settings: the reel switch and every shortcut.
await glide('#gear');
await page.mouse.down();
await page.mouse.up();
await pause(2600);
await page.keyboard.press('Escape');
await pause(600);

const skip = ((Date.now() - start) / 1000).toFixed(2), video = await page.video().path();
await context.close();
await browser.close();
const total = Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', video]).toString());
const from = Math.max(0, total - Number(skip)).toFixed(2);
const out = join(root, 'docs/demo.gif');
// mpdecimate drops the still frames, which the video's noise otherwise re-encodes whole (3.1 MB without it); 12 fps keeps the GIF under 2.5 MB.
execFileSync('ffmpeg', ['-y', '-v', 'error', '-ss', from, '-i', video, '-vf', 'fps=12,mpdecimate,scale=880:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle', '-fps_mode', 'vfr', out]);
console.log(out, readdirSync(dir).length, 'video(s), from', from, 's of', total.toFixed(2));

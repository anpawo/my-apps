import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { webkit } from '/Users/mr/node_modules/playwright/index.mjs';
import { stub } from './stub.mjs';

const ui = join(dirname(fileURLToPath(import.meta.url)), '../ui');
const browser = await webkit.launch({ headless: true });
try {
  const page = await browser.newPage({ reducedMotion: 'reduce' });
  await page.addInitScript(stub);
  await page.addInitScript(() => {
    window.setInterval = () => 0;
    const invoke = window.__TAURI__.core.invoke;
    window.__TAURI__.core.invoke = async (cmd, args) => {
      const held = cmd === 'api' && args.method === 'GET' && args.path.includes('/messages') && window.__hold;
      if (held) {
        window.__heldRequests++;
        await window.__hold;
      }
      const result = await invoke(cmd, args);
      if (held) window.__settledRequests++;
      return result;
    };
  });
  await page.route('https://one-text.test/**', route => {
    const file = new URL(route.request().url()).pathname.slice(1) || 'index.html';
    const path = join(ui, file);
    return route.fulfill(existsSync(path) ? {
      body: readFileSync(path),
      contentType: { html: 'text/html', css: 'text/css', js: 'text/javascript' }[file.split('.').pop()]
    } : { status: 404, body: '' });
  });
  await page.goto('https://one-text.test/');
  await page.waitForFunction(() => state.byId.size > 1);
  await page.evaluate(async () => {
    const chats = [...state.byId.values()].filter(i => i.chats.length === 1 && __msgs[i.chats[0].id]?.length);
    window.__first = chats.find(i => i !== state.cur);
    window.__second = chats.find(i => i !== __first);
    await select(__first.id);
    window.__expected = state.msgs.map(m => m.id);
    await refreshList();
    await select(__second.id);
    window.__heldRequests = 0;
    window.__settledRequests = 0;
    window.__hold = new Promise(resolve => { window.__release = resolve; });
    window.__selection = select(__first.id);
  });
  const timeout = 500;
  await page.waitForFunction(() => __heldRequests > 0, { timeout });
  const visible = await page.evaluate(() => __expected.every(id =>
    [...document.querySelectorAll('#thread [data-id]')].some(row => row.dataset.id === id)));
  assert.ok(visible, 'recently viewed messages appear before a delayed refresh returns');
  await page.evaluate(() => {
    const m = __msgs[__first.chats[0].id].at(-1);
    m.text = 'Updated cached message';
    window.__updated = m.id;
    __release();
  });
  await page.waitForFunction(() => state.msgs.some(m => m.id === __updated && m.text === 'Updated cached message'));
  console.log('PASS: recently viewed messages appear before a delayed refresh returns');
  console.log('PASS: cached messages refresh after the delayed response returns');
  await page.evaluate(async () => {
    window.__hold = null;
    await select(__second.id);
    window.__hold = new Promise(resolve => { window.__release = resolve; });
    await select(__first.id);
    await select(__second.id);
    __release();
  });
  await page.waitForFunction(() => __settledRequests === __heldRequests);
  await page.waitForFunction(() => state.msgs.every(m => __second.chats.some(c => c.id === m.chatID)));
  assert.ok(await page.evaluate(() => recentChats.size <= RECENT_CHAT_LIMIT &&
    [...recentChats.values()].every(msgs => msgs.length <= RECENT_MESSAGE_LIMIT)),
  'recent chat snapshots stay bounded');
  console.log('PASS: delayed refresh stays in its conversation and snapshots stay bounded');
} finally {
  await browser.close();
}

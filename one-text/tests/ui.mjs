// Headless WebKit (the engine Tauri uses on macOS) on made-up data: `node tests/ui.mjs <out dir>`.
import { webkit } from '/Users/mr/node_modules/playwright/index.mjs';
import { readFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ui = join(dirname(fileURLToPath(import.meta.url)), '../ui');
const out = process.argv[2] || '/tmp/chats-ui';
mkdirSync(out, { recursive: true });

const stub = () => {
  const t = m => new Date(Date.now() - m * 60000).toISOString();
  const chat = (id, network, person, name, last, unread = 0) => ({ id, network, accountID: network.toLowerCase(), person, title: name, last, unread, preview: null });
  const chats = [
    chat('wa-lea', 'WhatsApp', 'lea', 'Lea Martin', t(30), 1),
    chat('ig-lea', 'Instagram', 'lea', 'Lea Martin', t(5), 2),
    chat('dc-tom', 'Discord', 'tom-dc', 'tom', t(60)),
    chat('wa-tom', 'WhatsApp', 'tom-wa', 'Tom B', t(90)),
    chat('ig-hugo', 'Instagram', 'hugo', 'Hugo R', t(200)),
    chat('li-hugo', 'LinkedIn', 'hugo', 'Hugo R', t(300)),
    chat('te-sarah', 'bridgev2', 'sarah', 'Sarah K', t(400)),
  ];
  chats[6].accountID = 'sh-teams';
  const msg = (chatID, id, text, min, isSender = false) => ({ id, chatID, text, timestamp: t(min), sortKey: String(1e9 - min), isSender, senderID: isSender ? 'me' : chatID, senderName: 'x' });
  const msgs = {
    'wa-lea': [msg('wa-lea', 'w1', 'dinner tonight still on?', 50), msg('wa-lea', 'w2', 'yes! where?', 45, true), msg('wa-lea', 'w3', 'the usual place', 30)],
    'ig-lea': [msg('ig-lea', 'i1', 'did you see the reel I sent?', 1500), msg('ig-lea', 'i2', 'haha yes, too good', 1490, true), { ...msg('ig-lea', 'i2r', '<p><a href="https://www.instagram.com/reel/ABC123/?id=1&amp;x=y" rel="noopener">https://www.instagram.com/reel/ABC123/</a></p>', 1480), attachments: [{ type: 'img', srcURL: 'mxc://thumb' }] }, msg('ig-lea', 'i3', 'see you at 8 then', 5)],
    'dc-tom': [msg('dc-tom', 'd1', 'gg last night', 60)],
    'wa-tom': [msg('wa-tom', 't1', 'call me when you can', 90)],
    'ig-hugo': [msg('ig-hugo', 'h1', 'sent you the deck', 200)], 'li-hugo': [msg('li-hugo', 'l1', 'congrats on the new role', 300)],
    'te-sarah': [msg('te-sarah', 's1', 'meeting moved to 3pm', 400)],
    'grp-1': [msg('grp-1', 'g1', 'who is in for friday?', 20)], 'grp-2': [msg('grp-2', 'g2', 'new release is out', 700)],
  };
  for (const c of chats) c.preview = { text: msgs[c.id].at(-1).text, isSender: msgs[c.id].at(-1).isSender };
  const groups = [
    { id: 'grp-1', name: 'Climbing crew', imgs: [], unread: 3, last: t(20), preview: { text: 'who is in for friday?', senderName: 'Nina' }, chats: [{ id: 'grp-1', network: 'WhatsApp', accountID: 'whatsapp', unread: 3, last: t(20) }] },
    { id: 'grp-2', name: 'Rust FR', imgs: [], unread: 0, last: t(700), preview: { text: 'new release is out', senderName: 'Bot' }, chats: [{ id: 'grp-2', network: 'Discord', accountID: 'discordgo', unread: 0, last: t(700) }] },
  ];
  let overrides = {};
  const log = (window.__log = []);
  function people() {
    const root = {};
    const find = k => (root[k] && root[k] !== k ? find(root[k]) : k);
    for (const [a, b] of overrides.merges || []) {
      const pa = chats.find(c => c.id === a)?.person, pb = chats.find(c => c.id === b)?.person;
      if (pa && pb) root[find(pa)] = find(pb);
    }
    const by = {};
    for (const c of chats) (by[find(c.person)] ||= []).push(c);
    return Object.values(by).map(cs => {
      cs.sort((a, b) => b.last.localeCompare(a.last));
      return { id: cs.map(c => c.id).sort()[0], name: cs.map(c => c.title).sort((a, b) => b.length - a.length)[0], imgs: ['mxc://ig', 'mxc://wa'],
        unread: cs.reduce((s, c) => s + c.unread, 0), last: cs[0].last, preview: cs[0].preview, chats: cs };
    }).sort((a, b) => b.last.localeCompare(a.last));
  }
  const invoke = async (cmd, args) => {
    log.push([cmd, args]);
    await new Promise(r => setTimeout(r, 30));
    if (cmd === 'people') return structuredClone({ people: people(), groups });
    if (cmd === 'overrides') return structuredClone(overrides);
    if (cmd === 'set_overrides') { overrides = args.value; return null; }
    if (cmd === 'open_url') return null;
    if (cmd === 'api') {
      const m = args.path.match(/^\/v1\/chats\/([^/]+)\/(messages|read)$/);
      const id = m && decodeURIComponent(m[1]);
      if (args.method === 'GET' && m) return { items: [...msgs[id]].reverse() };
      if (args.method === 'POST' && m[2] === 'messages') { msgs[id].push(msg(id, 'sent-' + msgs[id].length, args.body.text, 0, true)); return { id: 'ok' }; }
      if (args.method === 'POST' && m[2] === 'read') { const c = chats.find(c => c.id === id); if (c) c.unread = 0; return {}; }
    }
    throw new Error('unexpected ' + cmd + ' ' + JSON.stringify(args));
  };
  window.__TAURI__ = { core: { invoke } };
};

const fails = [];
const check = (ok, what) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`); if (!ok) fails.push(what); };
const monotonic = v => v.every((x, i) => i === 0 || x >= v[i - 1] - 0.5) || v.every((x, i) => i === 0 || x <= v[i - 1] + 0.5);

const browser = await webkit.launch();
const page = await browser.newPage({ viewport: { width: 1100, height: 720 }, deviceScaleFactor: 2 });
const errors = [];
page.on('pageerror', e => errors.push(e.message));
page.on('console', m => m.type() === 'error' && !/beeper:\/\/|unsupported URL/.test(m.text()) && errors.push(m.text()));
await page.addInitScript(stub);
await page.route('http://chats.test/**', r => {
  const file = new URL(r.request().url()).pathname.slice(1) || 'index.html';
  const type = { html: 'text/html', css: 'text/css', js: 'text/javascript' }[file.split('.').pop()];
  r.fulfill({ body: readFileSync(join(ui, file)), contentType: type });
});
await page.goto('http://chats.test/index.html');
await page.waitForSelector('#people .row');

const names = await page.$$eval('#people .row .name', ns => ns.map(n => n.textContent));
check(names.length === 5, `5 people listed (${names.join(', ')})`);
check(await page.$$eval('#groups .row', ns => ns.length) === 2, '2 groups in their own section');
check(!(await page.$('#people .net')), 'no network logos in the list');
const many = await page.evaluate(() => shown(Array.from({ length: 15 }, (_, i) => ({ id: 'x' + i, name: 'p' + i, unread: i === 12 ? 1 : 0 }))).map(i => i.id));
check(many.length === 11 && many.includes('x12'), `list keeps the 10 newest plus unread (${many.length})`);

// Opening Lea: mixed timeline, marks, auto target = Instagram (her last message), read sent.
await page.click('#people .row >> nth=0');
await page.waitForSelector('#thread .msg');
await page.waitForTimeout(700);
const thread = await page.$$eval('#thread .msg', ms => ms.map(m => m.dataset.net + ':' + m.textContent.trim()));
check(!(await page.$('#thread .net')), 'no network logos on messages');
const reel = await page.$$eval('#thread .bubble.reel', rs => rs.map(r => [r.getAttribute('href'), !!r.querySelector('img'), !!r.querySelector('.play')]));
check(JSON.stringify(reel) === JSON.stringify([['https://www.instagram.com/reel/ABC123/', true, true]]), `shared reel shows as a card (${JSON.stringify(reel)})`);
check(!(await page.textContent('#thread')).includes('<p>'), 'no raw HTML in the thread');
await page.click('#thread .bubble.reel');
check(await page.evaluate(() => __log.some(([c, a]) => c === 'open_url' && a.url === 'https://www.instagram.com/reel/ABC123/')), 'clicking the reel opens it in the browser');
const centered = await page.$eval('#people .row .name', n => { const a = n.getBoundingClientRect(), b = n.closest('.row').querySelector('.av').getBoundingClientRect(); return Math.abs((a.top + a.bottom) / 2 - (b.top + b.bottom) / 2); });
check(centered < 2, `name centered on the avatar (${centered.toFixed(1)} px off)`);
check(JSON.stringify(thread) === JSON.stringify(['instagram:did you see the reel I sent?', 'instagram:haha yes, too good', 'instagram:', 'whatsapp:dinner tonight still on?', 'whatsapp:yes! where?', 'whatsapp:the usual place', 'instagram:see you at 8 then']), 'merged timeline in time order with network marks');
const chips = await page.$$eval('header .chip', cs => cs.map(c => c.dataset.net + (c.classList.contains('on') ? '*' : '') + ':' + c.textContent.trim()));
check(JSON.stringify(chips.sort()) === JSON.stringify(['instagram*:', 'whatsapp:']), `header shows both logos, Instagram highlighted, no names (${chips})`);
const reads = await page.evaluate(() => __log.filter(([c, a]) => c === 'api' && a.path.endsWith('/read')).map(([, a]) => a.path));
check(reads.length === 0, `no read receipt sent (${reads.length})`);
await page.evaluate(() => refreshList());
check(!(await page.$('#people .row[data-id="ig-lea"] .badge')), 'badge stays cleared after a refresh');
check(!(await page.$('.row .preview')), 'no last message under the names');
const av = await page.$eval('#people .row[data-id="ig-lea"] .av', a => [a.textContent, a.querySelectorAll('img').length]);
check(av[0] === 'LM' && av[1] === 0, `every picture failing falls back to the initials (${av})`);
await page.click('#input');
await page.keyboard.press('Meta+d');
check(await page.evaluate(() => document.activeElement.id === 'search'), 'Cmd+D focuses the search bar');
await page.click('#input');
// beeper:// does not load here: a stand-in reel thumbnail, so the screenshot (docs/screenshot.png) shows the card.
await page.$eval('#thread .bubble.reel img', i => (i.src = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 9 16"><defs><linearGradient id="g" x2="0" y2="1"><stop stop-color="#f58529"/><stop offset=".5" stop-color="#dd2a7b"/><stop offset="1" stop-color="#515bd4"/></linearGradient></defs><rect width="9" height="16" fill="url(#g)"/></svg>')));
await page.waitForTimeout(100);
await page.screenshot({ path: join(out, '1-open.png') });

// The selection pill glides: sample it every frame while moving to Tom.
const pillTrack = await page.evaluate(async () => {
  const pill = document.querySelector('.sel'), out = [];
  document.querySelectorAll('#people .row')[2].click();
  const t0 = performance.now();
  while (performance.now() - t0 < 320) { await new Promise(r => requestAnimationFrame(r)); out.push(pill.getBoundingClientRect().top); }
  return out;
});
const distinct = new Set(pillTrack.map(Math.round)).size;
check(distinct >= 4 && monotonic(pillTrack), `selection pill moves through ${distinct} positions, one way only`);

// Header logos: back on Lea, clicking WhatsApp's moves the highlight; clicking Instagram's moves it back.
await page.click('#people .row >> nth=0');
await page.waitForTimeout(700);
const on = () => page.$eval('header .chip.on', c => c.dataset.net);
await page.click('.chip[data-net="whatsapp"]');
check(await on() === 'whatsapp', 'clicking a logo picks that network');
await page.waitForTimeout(300);
await page.screenshot({ path: join(out, '2-header.png') });
await page.click('.chip[data-net="instagram"]');
check(await on() === 'instagram', 'clicking the other logo picks it back');

// /ws switches the reply to WhatsApp; Enter sends there.
await page.click('#input');
await page.keyboard.type('/ws ');
check(await on() === 'whatsapp' && (await page.inputValue('#input')) === '', '/ws switches to WhatsApp and clears the command');
await page.keyboard.type('on my way');
await page.keyboard.press('Enter');
await page.waitForTimeout(100);
const sent = await page.evaluate(() => __log.filter(([c, a]) => c === 'api' && a.method === 'POST' && a.path.endsWith('/messages')).map(([, a]) => [a.path, a.body.text]));
check(JSON.stringify(sent) === JSON.stringify([['/v1/chats/wa-lea/messages', 'on my way']]), 'message sent to the WhatsApp chat');
check(await page.$$eval('#thread .msg.pending', ms => ms.length) === 1, 'pending bubble shown at once');
await page.waitForTimeout(1200);
check(await page.$$eval('#thread .msg.pending', ms => ms.length) === 0 && (await page.$$eval('#thread .msg.me', ms => ms.at(-1).textContent)).includes('on my way'), 'pending bubble replaced by the sent message');
check(await on() === 'whatsapp', 'manual choice holds after sending');

// Merge Tom (Discord) with Tom B (WhatsApp) through the ⋯ menu, then Undo.
await page.click('#people .row:has-text("tom")');
await page.waitForTimeout(500);
await page.click('.more');
await page.waitForTimeout(250);
await page.click('.menu .item:has-text("Merge with")');
await page.waitForTimeout(300);
await page.keyboard.type('tom b');
await page.screenshot({ path: join(out, '3-merge.png') });
await page.click('.menu .found .item >> nth=0');
await page.waitForTimeout(600);
check(await page.$$eval('#people .row:not([data-leaving])', ns => ns.length) === 4, 'merge leaves 4 people');
check(await page.evaluate(() => JSON.stringify(__log.filter(([c]) => c === 'set_overrides').at(-1)[1].value.merges)) === '[["dc-tom","wa-tom"]]', 'merge saved as an override');
check(JSON.stringify(await page.$$eval('header .chip', cs => cs.map(c => c.dataset.net).sort())) === '["discord","whatsapp"]', 'open conversation now shows both of Tom\'s logos');
check(await page.isVisible('.toast button'), 'toast offers Undo');
await page.screenshot({ path: join(out, '4-merged.png') });
await page.click('.toast button');
await page.waitForTimeout(600);
check(await page.$$eval('#people .row:not([data-leaving])', ns => ns.length) === 5, 'Undo brings back 5 people');

// Groups section folds with its content clipped.
const fold = await page.evaluate(async () => {
  const clip = document.querySelector('#groups-clip'), h = [];
  document.querySelector('#groups-toggle').click();
  const t0 = performance.now();
  while (performance.now() - t0 < 360) { await new Promise(r => requestAnimationFrame(r)); h.push(clip.getBoundingClientRect().height); }
  return h;
});
check(fold.some(h => h > 5 && h < 100) && monotonic(fold) && fold.at(-1) < 1, `groups fold smoothly (${fold.map(Math.round).join(' ')})`);

check(errors.length === 0, `no page errors ${errors.join(' | ')}`);
await browser.close();
console.log(fails.length ? `${fails.length} FAILED` : 'all passed');
process.exit(fails.length ? 1 : 0);

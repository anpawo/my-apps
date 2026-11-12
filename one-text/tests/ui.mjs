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
    { id: 'grp-1', name: 'Climbing crew', imgs: [], faces: ['mxc://nina', 'mxc://paul'], unread: 3, last: t(20), preview: { text: 'who is in for friday?', senderName: 'Nina' }, chats: [{ id: 'grp-1', network: 'WhatsApp', accountID: 'whatsapp', unread: 3, last: t(20) }] },
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
      return { id: cs.map(c => c.id).sort()[0], name: cs.map(c => c.title).sort((a, b) => b.length - a.length)[0], imgs: [...cs.map(c => overrides.pictures?.[c.id]).filter(Boolean), 'mxc://ig', 'mxc://wa'],
        unread: cs.reduce((s, c) => s + c.unread, 0), last: cs[0].last, preview: cs[0].preview, chats: cs };
    }).sort((a, b) => b.last.localeCompare(a.last));
  }
  const invoke = async (cmd, args) => {
    log.push([cmd, args]);
    await new Promise(r => setTimeout(r, 30));
    if (cmd === 'people') return structuredClone({ people: people(), groups: groups.map(g => ({ ...g, name: overrides.names?.[g.id] || g.name, original: overrides.names?.[g.id] ? g.name : null, hidden: (overrides.hidden || []).includes(g.id) })) });
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
check(names.length === 7, `5 people and 2 groups in one list (${names.join(', ')})`);
const lasts = await page.evaluate(() => [...document.querySelectorAll('#people .row')].map(r => state.byId.get(r.dataset.id).last));
check(lasts.every((l, i) => !i || lasts[i - 1] >= l) && names.includes('Climbing crew'), 'groups sit among people, newest first');
check(!(await page.$('#people .row:not([data-id^="grp"]) .net')), 'no network logos on people in the list');
const faces = await page.$eval('#people .row[data-id="grp-1"] .av.faces', a => [a.firstElementChild.className, a.firstElementChild.getBoundingClientRect().width, ...[...a.querySelectorAll('img')].map(i => i.getBoundingClientRect()).map(r => [r.left, r.width])]);
check(faces[0] === 'net' && faces[1] === 40 && faces.length === 4 && faces[2][1] === 40 && faces[3][0] < faces[2][0] + 40, `a group shows its app's logo, then its members' pictures overlapping (${JSON.stringify(faces)})`);
// A one-letter search over 1000 people: how long the list takes to draw, and how many rows it draws.
const searchCost = await page.evaluate(async () => {
  const saved = state.all;
  state.all = Array.from({ length: 1000 }, (_, i) => ({ id: 'f' + i, name: 'Person ' + i, imgs: [], unread: 0, kind: 'person', last: new Date(Date.now() - i * 6e4).toISOString(), chats: [{ id: 'f' + i, network: 'WhatsApp', accountID: 'whatsapp' }] }));
  openPalette();
  const field = document.querySelector('#search');
  field.value = 'p';
  const t0 = performance.now();
  field.dispatchEvent(new Event('input'));
  await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
  const ms = performance.now() - t0, rows = document.querySelectorAll('#results .row').length;
  state.all = saved; closePalette();
  await new Promise(r => setTimeout(r, 400));
  return [Math.round(ms), rows];
});
check(searchCost[0] < 150, `a one-letter search over 1000 people draws in ${searchCost[0]} ms (${searchCost[1]} rows)`);
const many = await page.evaluate(() => shown(Array.from({ length: 15 }, (_, i) => ({ id: 'x' + i, name: 'p' + i, unread: i === 12 ? 1 : 0, chats: [] }))).map(i => i.id));
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
await page.waitForTimeout(250);
const pal = await page.$eval('#palette .box', b => { const r = b.getBoundingClientRect(); return [document.activeElement.id, Math.round(r.left + r.width / 2 - innerWidth / 2)]; });
check(pal[0] === 'search' && Math.abs(pal[1]) < 2, `Cmd+D opens the search centered in the window (${pal})`);
await page.keyboard.type('hug');
await page.screenshot({ path: join(out, '0-search.png') });
await page.keyboard.press('Enter');
await page.waitForTimeout(300);
check(await page.isHidden('#palette') && await page.textContent('header .who') === 'HRHugo R', 'Enter opens the match and closes the search');
await page.click('#people .row[data-id="ig-lea"]');
await page.waitForTimeout(400);
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
check(await page.$$eval('#people .row:not([data-leaving])', ns => ns.length) === 6, 'merge leaves 4 people (and the 2 groups)');
check(await page.evaluate(() => JSON.stringify(__log.filter(([c]) => c === 'set_overrides').at(-1)[1].value.merges)) === '[["dc-tom","wa-tom"]]', 'merge saved as an override');
check(JSON.stringify(await page.$$eval('header .chip', cs => cs.map(c => c.dataset.net).sort())) === '["discord","whatsapp"]', 'open conversation now shows both of Tom\'s logos');
check(await page.isVisible('.toast button'), 'toast offers Undo');
await page.screenshot({ path: join(out, '4-merged.png') });
await page.click('.toast button');
await page.waitForTimeout(600);
check(await page.$$eval('#people .row:not([data-leaving])', ns => ns.length) === 7, 'Undo brings back 5 people');

// Favorites: right-click → Add to favorites moves Hugo to the picture strip; ⌘F over Sarah adds her too, and again removes her.
await page.click('#people .row:has-text("Hugo R")', { button: 'right' });
await page.click('.menu .item:has-text("Add to favorites")');
await page.waitForTimeout(400);
const favIds = () => page.$$eval('#favs .fav', fs => fs.map(f => f.dataset.id));
const hugo = (await favIds())[0];
check((await favIds()).length === 1 && !(await page.$(`#people .row[data-id="${hugo}"]:not([data-leaving])`)) && !(await page.$('#favs .name')), 'a favorite shows only its picture, above the list');
await page.hover('#people .row:has-text("Sarah K")');
await page.keyboard.press('Meta+f');
await page.waitForTimeout(400);
check((await favIds()).length === 2, 'Cmd+F over a person adds them to favorites');
await page.screenshot({ path: join(out, '5-favorites.png') });
await page.hover('#favs .fav:last-child');
await page.keyboard.press('Meta+f');
await page.waitForTimeout(400);
check((await favIds()).length === 1 && (await page.$$eval('#people .row:not([data-leaving])', ns => ns.length)) === 6, 'Cmd+F over a favorite puts it back in the list');
await page.reload();
await page.waitForSelector('#favs .fav');
check(JSON.stringify(await favIds()) === JSON.stringify([hugo]), 'favorites are kept after a restart');
// ⌘ + arrows reorder favorites, and the order survives a restart.
await page.hover('#people .row:has-text("Tom B")');
await page.keyboard.press('Meta+f');
await page.waitForTimeout(300);
const tomB = (await favIds())[1];
await page.hover(`#favs .fav[data-id="${tomB}"]`);
await page.keyboard.press('Meta+ArrowLeft');
await page.waitForTimeout(400);
check(JSON.stringify(await favIds()) === JSON.stringify([tomB, hugo]), `Cmd+Left moves a favorite first (${await favIds()})`);
await page.reload();
await page.waitForSelector('#favs .fav');
check(JSON.stringify(await favIds()) === JSON.stringify([tomB, hugo]), 'the favorites order is kept after a restart');
await page.hover(`#favs .fav[data-id="${tomB}"]`);
await page.keyboard.press('Meta+f');
await page.waitForTimeout(400);

// Hiding a group: right-click → Hide from the list; ⌘D still finds it.
await page.click('#people .row:has-text("Rust FR")', { button: 'right' });
await page.click('.menu .item:has-text("Hide from the list")');
await page.waitForTimeout(500);
await page.click('#people .row:has-text("Lea Martin")');
await page.waitForTimeout(500);
check(!(await page.$('#people .row[data-id="grp-2"]:not([data-leaving])')), 'a hidden group leaves the list');
await page.keyboard.press('Meta+d');
await page.keyboard.type('rust');
await page.waitForTimeout(300);
check(await page.$$eval('#results .row:not([data-leaving])', rs => rs.map(r => r.dataset.id).join()) === 'grp-2', 'the search still finds a hidden group');
await page.keyboard.press('Escape');

// A picture set by hand: setPicture saves it and the row shows it; the menu then offers to remove it.
const dot = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="#0a0"/></svg>');
await page.evaluate(d => setPicture(state.byId.get(state.all.find(i => i.name === 'Hugo R').id), d), dot);
await page.waitForTimeout(400);
check(await page.$eval('.fav img, #people .row:has-text("Hugo R") img', i => i.src.startsWith('data:image/svg')), 'a picture set by hand shows instead of the initials');
check(await page.evaluate(() => Object.keys(state.pictures || {}).length) === 1, 'the picture is kept in the overrides');

// Pinning a group: it keeps its row, under the favorites' pictures and above the list.
await page.click('#people .row[data-id="grp-1"]', { button: 'right' });
await page.click('.menu .item:has-text("Add to favorites")');
await page.waitForTimeout(500);
const pinned = await page.evaluate(() => {
  const row = document.querySelector('#pinned .row[data-id="grp-1"]'), favs = document.querySelector('#favs'), list = document.querySelector('#people');
  return row && [!!row.querySelector('.name'), !document.querySelector('#favs .fav[data-id="grp-1"]'), favs.getBoundingClientRect().bottom <= row.getBoundingClientRect().top, row.getBoundingClientRect().bottom <= list.getBoundingClientRect().top];
});
check(JSON.stringify(pinned) === '[true,true,true,true]', `a pinned group keeps its row between the favorites and the list (${pinned})`);
await page.screenshot({ path: join(out, '6-pinned.png') });

// ⌘F in the ⌘D search favorites the highlighted row, and the search stays open.
await page.keyboard.press('Meta+d');
await page.fill('#search', 'sarah');
await page.keyboard.press('Meta+f');
await page.waitForTimeout(400);
check(await page.evaluate(() => !document.querySelector('#palette').hidden && !!document.querySelector('#results .row.hot.faved') && !!document.querySelector('#favs .fav[title="Sarah K"]')), 'Cmd+F in the search adds the highlighted person to favorites');
await page.keyboard.press('Escape');

// Five favorites to a row.
const tops = await page.evaluate(() => {
  for (let i = 0; i < 9; i++) document.querySelector('#favs').insertAdjacentHTML('beforeend', '<button class="fav"><div class="av"></div></button>');
  return [...document.querySelectorAll('#favs .fav')].map(b => Math.round(b.getBoundingClientRect().top));
});
check(tops.filter(t => t === tops[0]).length === 5, `five favorites to a row (${tops})`);

// "/discord" in the search keeps only those on Discord; "/wh tom" those on WhatsApp named tom.
await page.keyboard.press('Meta+d');
await page.fill('#search', '/discord');
await page.waitForTimeout(400);
const dc = await page.$$eval('#results .row:not([data-leaving]) .name', ns => ns.map(n => n.textContent));
check(JSON.stringify(dc) === '["tom","Rust FR"]', `/discord keeps those on Discord (${dc})`);
await page.fill('#search', '/wh tom');
await page.waitForTimeout(400);
const wa = await page.$$eval('#results .row:not([data-leaving]) .name', ns => ns.map(n => n.textContent));
check(JSON.stringify(wa) === '["Tom B"]', `/wh tom keeps WhatsApp people named tom (${wa})`);
await page.keyboard.press('Escape');
// ⌘R on a group in the search renames it in the header; the search then finds it by either name and shows both.
await page.keyboard.press('Meta+d');
await page.fill('#search', 'climbing');
await page.waitForTimeout(300);
await page.keyboard.press('Meta+r');
await page.waitForSelector('header .who input');
await page.fill('header .who input', 'Climbers');
await page.keyboard.press('Enter');
await page.waitForTimeout(500);
const header = await page.$eval('header .who', w => w.textContent);
await page.keyboard.press('Meta+d');
await page.fill('#search', 'climbing crew');
await page.waitForTimeout(400);
const found = await page.$$eval('#results .row:not([data-leaving]) .name', ns => ns.map(n => [n.firstChild.textContent, n.querySelector('.orig')?.textContent]));
check(header === 'Climbers' && JSON.stringify(found) === '[["Climbers","Climbing crew"]]', `⌘R renames a group; searching its old name shows both (${header}, ${JSON.stringify(found)})`);
await page.keyboard.press('Escape');
await page.evaluate(() => invoke('set_overrides', { value: {} }).then(refreshList));
await page.waitForTimeout(300);

// Groups: favorites in no group stay on top; "+ New group" names one; Add to it moves her into it; every group stays open.
const topFavs = () => page.$$eval('#favs:not([hidden]) .fav[data-id]', fs => fs.map(f => f.title));
const groupFavs = name => page.$$eval(`.group[data-name="${name}"] .strip:not([hidden]) .fav`, fs => fs.map(f => f.title));
const topBefore = await topFavs();
await page.click('#tabbox .newgroup');
await page.keyboard.type('Family');
await page.keyboard.press('Enter');
await page.waitForTimeout(400);
check(!!(await page.$('.group[data-name="Family"] .favs-empty')) && JSON.stringify(await topFavs()) === JSON.stringify(topBefore), `a new group shows under the favorites in no group (${topBefore})`);
await page.click('#people .row:has-text("Lea Martin")', { button: 'right' });
await page.click('.menu .item:has-text("Move to Family")');
await page.waitForTimeout(400);
check(JSON.stringify(await groupFavs('Family')) === '["Lea Martin"]' && !(await topFavs()).includes('Lea Martin'), `Add to Family moves her into the group (${await groupFavs('Family')} / ${await topFavs()})`);
await page.click('#tabbox .newgroup');
await page.keyboard.type('Work');
await page.keyboard.press('Enter');
await page.waitForTimeout(300);
await page.click('#people .row:has-text("Tom B")', { button: 'right' });
await page.click('.menu .item:has-text("Move to Work")');
await page.waitForTimeout(400);
check(JSON.stringify(await groupFavs('Family')) === '["Lea Martin"]' && JSON.stringify(await groupFavs('Work')) === '["Tom B"]', 'two groups are open at once');
const order = await page.evaluate(() => ['#favs', '.group[data-name="Family"]', '.group[data-name="Work"]', '#pinned', '#people'].map(q => document.querySelector(q)).filter(e => e.offsetHeight).map(e => Math.round(e.getBoundingClientRect().top)));
check(order.every((t, k) => !k || order[k - 1] < t), `favorites in no group, then each group, then pinned groups, then the list (${order})`);
await page.screenshot({ path: join(out, '7-groups.png') });
const side = await page.evaluate(() => { const g = document.querySelector('.group[data-name="Family"]'), l = g.querySelector('.label').getBoundingClientRect(), f = g.querySelector('.fav').getBoundingClientRect(), t = document.querySelector('#favs .fav').getBoundingClientRect(); return [l.bottom <= f.top, Math.round(f.left - t.left)]; });
check(JSON.stringify(side) === '[true,0]', `a group's name sits above its pictures, which line up with the top strip (${side})`);
// Over 5 in a group: 4 pictures and a tile folding the rest; those with unread messages stay out unless 5 or more have some.
const fold = await page.evaluate(() => {
  const mk = (n, unread = 0) => Array.from({ length: n }, (_, k) => ({ id: 'f' + k, name: 'P' + k, unread: k >= n - unread ? 1 : 0, chats: [] }));
  const names = ([a, b]) => [a.map(i => i.name).join(), b.map(i => i.name).join()];
  const box = document.createElement('div');
  box.className = 'strip';
  document.querySelector('.group[data-name="Family"]').append(box);
  drawFavs(box, mk(8, 2), { name: 'T' });
  const tile = [box.querySelectorAll('.fav').length, box.querySelectorAll('.folder .av').length, box.querySelector('.folder').classList.contains('unread')];
  box.id = 'fold-demo';
  return [names(foldGroup(mk(5), { name: 'T' })), names(foldGroup(mk(8, 2), { name: 'T' })), names(foldGroup(mk(8, 5), { name: 'T' })), tile];
});
check(JSON.stringify(fold) === JSON.stringify([['P0,P1,P2,P3,P4', ''], ['P0,P1,P6,P7', 'P2,P3,P4,P5'], ['P0,P1,P2,P3', 'P4,P5,P6,P7'], [4, 4, false]]), `a group of 8 folds 4 into a tile of small pictures, the unread kept out (${JSON.stringify(fold)})`);
await page.screenshot({ path: join(out, '7b-folded.png'), clip: { x: 0, y: 0, width: 330, height: 560 } });
await page.$eval('#fold-demo', b => b.remove());
// Dragging Lea onto Work moves her out of Family; dragging Tom B onto the top strip takes him out of Work.
const drag = async (from, to) => {
  const a = await page.locator(from).boundingBox(), b = await page.locator(to).boundingBox();
  await page.mouse.move(a.x + a.width / 2, a.y + a.height / 2);
  await page.mouse.down();
  await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2, { steps: 8 });
  await page.mouse.up();
  await page.waitForTimeout(500);
};
await drag('.group[data-name="Family"] .fav[title="Lea Martin"]', '.group[data-name="Work"]');
check((await groupFavs('Family')).length === 0 && (await groupFavs('Work')).includes('Lea Martin') && (await groupFavs('Work')).includes('Tom B'), `dragging moves her from Family to Work (${await groupFavs('Family')} / ${await groupFavs('Work')})`);
await drag('.group[data-name="Work"] .fav[title="Tom B"]', '#favs');
check((await topFavs()).includes('Tom B') && !(await groupFavs('Work')).includes('Tom B'), `dragging onto the top strip takes him out of his group (${await topFavs()})`);
await page.click('.group[data-name="Work"] .fav[title="Lea Martin"]', { button: 'right' });
await page.click('.menu .item:has-text("Move to Family")');
await page.waitForTimeout(400);
await page.click('#favs .fav[title="Tom B"]', { button: 'right' });
await page.click('.menu .item:has-text("Move to Work")');
await page.waitForTimeout(400);
await page.reload();
await page.waitForSelector('.group');
await page.waitForTimeout(300);
check(JSON.stringify(await groupFavs('Family')) === '["Lea Martin"]' && JSON.stringify(await groupFavs('Work')) === '["Tom B"]', 'groups are kept after a restart');

// Dragging the sidebar's right edge widens it, and the width is kept after a restart.
const sideW = () => page.evaluate(() => document.querySelector('aside').offsetWidth);
const w0 = await sideW();
const grip = await page.locator('.resize').boundingBox();
await page.mouse.move(grip.x + grip.width / 2, 300);
await page.mouse.down();
await page.mouse.move(grip.x + grip.width / 2 + 80, 300, { steps: 6 });
await page.mouse.up();
const w1 = await sideW();
await page.reload();
await page.waitForSelector('aside');
check(w0 === 313 && w1 === 393 && (await sideW()) === 393, `the sidebar starts at 313 px and its edge drags to 393 px, kept after a restart (${w0}, ${w1}, ${await sideW()})`);
await page.evaluate(() => { delete localStorage.asideWidth; });
await page.reload();
await page.waitForSelector('#people .row');
await page.waitForTimeout(300);

// The list holds as many people as fit (10 at most), and a wheel turn at its end shows twice as many.
const before = await page.evaluate(() => {
  state.all = Array.from({ length: 40 }, (_, i) => ({ id: 'q' + i, name: 'Person ' + i, imgs: [], unread: 0, kind: 'person', last: new Date(Date.now() - i * 6e4).toISOString(), chats: [{ id: 'q' + i, network: 'WhatsApp', accountID: 'whatsapp' }] }));
  state.byId = new Map(state.all.map(i => [i.id, i]));
  state.cur = null; state.more = 0;
  showLists();
  const l = document.querySelector('#list');
  return [document.querySelectorAll('#people .row:not([data-leaving])').length];
});
await page.waitForTimeout(400);
before.push(await page.evaluate(() => { const l = document.querySelector('#list'); return l.scrollHeight <= l.clientHeight + 1; }));
await page.mouse.move(150, 600);
await page.mouse.wheel(0, 200);
await page.waitForTimeout(400);
const after = await page.evaluate(() => document.querySelectorAll('#people .row:not([data-leaving])').length);
check(before[1] && before[0] > 0 && before[0] <= 10 && after === before[0] * 2, `the list fits the window (${before}) and a wheel turn doubles it (${after})`);

check(errors.length === 0, `no page errors ${errors.join(' | ')}`);
await browser.close();
console.log(fails.length ? `${fails.length} FAILED` : 'all passed');
process.exit(fails.length ? 1 : 0);

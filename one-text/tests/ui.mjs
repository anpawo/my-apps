// Headless WebKit (the engine Tauri uses on macOS) on made-up data: `node tests/ui.mjs <out dir>`.
import { webkit } from '/Users/mr/node_modules/playwright/index.mjs';
import { readFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ui = join(dirname(fileURLToPath(import.meta.url)), '../ui');
const out = process.argv[2] || '/tmp/chats-ui';
mkdirSync(out, { recursive: true });

const stub = () => {
  // A message's own text: the hover reactions and the Sent/Seen line are not part of it.
  window.msgText = m => { const c = m.cloneNode(true); c.querySelectorAll('.quick, .receipt, .reacts').forEach(e => e.remove()); return c.textContent.trim(); };
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
  chats.forEach(c => (c.pid = 'p-' + c.id));
  const msg = (chatID, id, text, min, isSender = false) => ({ id, chatID, text, timestamp: t(min), sortKey: String(1e9 - min), isSender, senderID: isSender ? 'me' : chatID, senderName: 'x' });
  const msgs = {
    'wa-lea': [msg('wa-lea', 'w1', 'dinner tonight still on?', 50), msg('wa-lea', 'w2', 'yes! where?', 45, true), msg('wa-lea', 'w3', 'the usual place', 30)],
    'ig-lea': [msg('ig-lea', 'i1', 'did you see the reel I sent?', 1500), msg('ig-lea', 'i2', 'haha yes, too good', 1490, true), { ...msg('ig-lea', 'i2r', '<p><a href="https://www.instagram.com/reel/ABC123/?id=1&amp;x=y" rel="noopener">https://www.instagram.com/reel/ABC123/</a></p>', 1480), attachments: [{ type: 'img', srcURL: 'mxc://thumb' }] }, msg('ig-lea', 'i3', 'see you at 8 then', 5)],
    'dc-tom': [{ ...msg('dc-tom', 'v1', '', 120), attachments: [{ type: 'audio', isVoiceNote: true, srcURL: 'mxc://voice', mimeType: 'audio/wav' }] }, msg('dc-tom', 'd1', 'gg last night', 60)],
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
  let overrides = JSON.parse(sessionStorage.overrides || '{}');
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
      const name = cs.map(c => c.title).sort((a, b) => b.length - a.length)[0], alias = cs.map(c => overrides.names?.[c.id]).find(Boolean);
      return { id: cs.map(c => c.id).sort()[0], name: alias || name, original: alias ? name : null, imgs: [...cs.map(c => overrides.pictures?.[c.id]).filter(Boolean), 'mxc://ig', 'mxc://wa'],
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
      if (args.path === '/v1/assets/upload/base64') return { uploadID: 'up1', duration: 1.5 };
      if (args.method === 'DELETE' && !args.path.includes('/reactions')) { const [, c, id] = args.path.match(/chats\/([^/]+)\/messages\/([^/]+)/); msgs[decodeURIComponent(c)] = msgs[decodeURIComponent(c)].filter(x => x.id !== decodeURIComponent(id)); return {}; }
      if (args.path.includes('/reactions') || ['PATCH', 'PUT'].includes(args.method)) return {};
      const [path, query] = args.path.split('?');
      const one = path.match(/^\/v1\/chats\/([^/]+)$/);
      if (args.method === 'GET' && one) {
        const cid = decodeURIComponent(one[1]);
        if (cid === 'grp-1') return { id: cid, description: 'Bouldering on fridays', participants: { total: 4, hasMore: false, items: [{ id: 'me', isSelf: true }, { id: 'p-nina', fullName: 'Nina', username: 'nina.climbs' }, { id: 'p-wa-lea', fullName: 'Lea M', phoneNumber: '+33 6 00 00 00 00', isAdmin: true }] } };
        return { id: cid, participants: { total: 2, items: [{ id: 'me', isSelf: true }, { id: 'p-' + cid, fullName: chats.find(c => c.id === cid)?.title, username: cid.split('-')[1] }] } };
      }
      const m = path.match(/^\/v1\/chats\/([^/]+)\/(messages|read)$/);
      const id = m && decodeURIComponent(m[1]);
      if (args.method === 'GET' && m) {
        const before = new URLSearchParams(query).get('cursor');
        const all = [...msgs[id]].reverse().filter(x => !before || Number(x.sortKey) < Number(before));
        const items = all.slice(0, window.__page || 20);
        return { items, hasMore: all.length > items.length, oldestCursor: items.at(-1)?.sortKey };
      }
      if (args.method === 'POST' && m[2] === 'messages') { msgs[id].push({ ...msg(id, 'sent-' + id + '-' + msgs[id].length, (args.body.text || '').replace(/^- /, ''), 0, true), attachments: args.body.attachment && [{ type: 'audio', isVoiceNote: true, srcURL: 'mxc://up', mimeType: 'audio/mp4' }] }); return { id: 'ok' }; }
      if (args.method === 'POST' && m[2] === 'read') { const c = chats.find(c => c.id === id); if (c) c.unread = 0; return {}; }
    }
    throw new Error('unexpected ' + cmd + ' ' + JSON.stringify(args));
  };
  window.__msgs = msgs;
  window.__TAURI__ = { core: { invoke } };
};

const fails = [];
const check = (ok, what) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`); if (!ok) fails.push(what); };
const monotonic = v => v.every((x, i) => i === 0 || x >= v[i - 1] - 0.5) || v.every((x, i) => i === 0 || x <= v[i - 1] + 0.5);

const browser = await webkit.launch();
const page = await browser.newPage({ viewport: { width: 1100, height: 720 }, deviceScaleFactor: 2 });
const errors = [];
page.on('pageerror', e => !/localhost\/asset/.test(e.message) && errors.push(e.message));
page.on('console', m => m.type() === 'error' && !/beeper:\/\/|unsupported URL|Cross origin requests|\/localhost\/asset/.test(m.text()) && errors.push(m.text()));
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
const logos = await page.$$eval('#people .row:not([data-id^="grp"])', rs => rs.map(r => [...r.querySelectorAll('.net')].map(n => [n.title, n.getBoundingClientRect().width])));
check(logos.every(l => l.length === 1 && l[0][1] === 26) && (await page.$eval('#people .row:has-text("Lea Martin") .net', n => n.title)) === 'Instagram', `each person in the list shows the logo of the app of their latest message, 26 px (${JSON.stringify(logos)})`);
const faces = await page.$eval('#people .row[data-id="grp-1"] .av.faces', a => [a.firstElementChild.className, a.firstElementChild.getBoundingClientRect().width, a.querySelector('.tile').getBoundingClientRect().width, a.querySelectorAll('.tile img').length]);
check(JSON.stringify(faces) === '["net",26,40,2]', `a group shows its app's logo, then its members' pictures in one round tile (${JSON.stringify(faces)})`);
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
const thread = await page.$$eval('#thread .msg', ms => ms.map(m => m.dataset.net + ':' + msgText(m)));
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
check(!!(await page.$('#people .row[data-id="ig-lea"] .badge')), 'opening a conversation keeps its badge');
await page.keyboard.press('Meta+k');
await page.waitForTimeout(300);
await page.evaluate(() => refreshList());
check(!(await page.$('#people .row[data-id="ig-lea"] .badge')), '⌘K clears the badge, and it stays cleared after a refresh');
const readSent = await page.evaluate(() => __log.filter(([c, a]) => c === 'api' && a.path.endsWith('/read')).map(([, a]) => a.path).sort());
check(JSON.stringify(readSent) === JSON.stringify(['/v1/chats/ig-lea/read', '/v1/chats/wa-lea/read']), `⌘K sends the read receipt to each app (${readSent})`);
// ⌘F finds a word in the open conversation, accents and case aside; Enter goes to the older match.
await page.mouse.move(900, 300);
await page.keyboard.press('Meta+f');
await page.keyboard.type('YES');
await page.waitForTimeout(300);
const found1 = await page.evaluate(() => [CSS.highlights.get('find').size, document.querySelector('#find .count').textContent, CSS.highlights.get('find-cur').values().next().value.startContainer.data]);
await page.keyboard.press('Enter');
const found2 = await page.evaluate(() => [document.querySelector('#find .count').textContent, CSS.highlights.get('find-cur').values().next().value.startContainer.data]);
await page.keyboard.press('Escape');
await page.waitForTimeout(300);
check(JSON.stringify([found1, found2]) === JSON.stringify([[2, '1 of 2', 'yes! where?'], ['2 of 2', 'haha yes, too good']]) && (await page.$eval('#find', f => f.hidden)) && !(await page.evaluate(() => isFav(state.cur))), `⌘F finds and steps back through matches (${JSON.stringify([found1, found2])})`);
// A voice message: the mic records, the upload goes to Beeper, then the message carries it as a voice note.
await page.evaluate(() => {
  window.MediaRecorder = class { constructor(s) { this.stream = s; this.mimeType = 'audio/mp4'; } static isTypeSupported(t) { return t === 'audio/mp4'; } start() {} stop() { this.ondataavailable({ data: new Blob(['abc'], { type: 'audio/mp4' }) }); this.onstop(); } };
  Object.defineProperty(navigator, 'mediaDevices', { value: { getUserMedia: async () => ({ getTracks: () => [] }) }, configurable: true });
});
await page.click('#mic');
await page.waitForTimeout(200);
const recording = await page.evaluate(() => [document.querySelector('#mic').classList.contains('recording'), document.querySelector('#input').placeholder]);
await page.click('#mic');
await page.waitForTimeout(400);
const voiceOut = await page.evaluate(() => __log.filter(([c, a]) => c === 'api' && a.method === 'POST' && /upload|messages$/.test(a.path)).slice(-2).map(([, a]) => [a.path, a.body.mimeType || a.body.attachment]));
check(recording[0] && recording[1].startsWith('Recording') && JSON.stringify(voiceOut) === JSON.stringify([['/v1/assets/upload/base64', 'audio/mp4'], ['/v1/chats/ig-lea/messages', { uploadID: 'up1', type: 'voice-note', duration: 1.5 }]]), `the mic records and sends a voice note (${JSON.stringify([recording, voiceOut])})`);
// ":" and a few letters list emoji by name, the emoji on the right; Enter puts it in place of what was typed.
await page.click('#input');
await page.keyboard.type('so :joy');
await page.waitForSelector('#emoji:not([hidden]) .item');
const emoRows = await page.$$eval('#emoji .item', is => is.map(i => [i.querySelector('span').textContent, i.querySelector('b').textContent, i.querySelector('b').getBoundingClientRect().left > i.querySelector('span').getBoundingClientRect().right]));
await page.waitForTimeout(300);
await page.screenshot({ path: join(out, '1c-emoji.png'), clip: { x: 300, y: 500, width: 400, height: 170 } });
await page.keyboard.press('Enter');
const emoText = await page.inputValue('#input');
check(emoRows[0]?.[0] === 'face with tears of joy' && emoRows[0][1] === '😂' && emoRows.every(r => r[2]) && emoText === 'so 😂' && !(await page.$('.msg.pending')), `":joy" offers 😂 by name, emoji on the right, Enter inserts it without sending (${JSON.stringify([emoRows.slice(0, 3), emoText])})`);
await page.fill('#input', '');
// ⌘R over a message replies to it: a bar names it, and the send carries its id to its chat.
await page.hover('#thread .msg:not(.me):has-text("dinner tonight")');
await page.keyboard.press('Meta+r');
await page.waitForTimeout(300);
const bar = await page.evaluate(() => [document.querySelector('#reply').hidden, document.querySelector('#reply').textContent, document.activeElement.id]);
await page.keyboard.type('8pm');
await page.keyboard.press('Enter');
await page.waitForTimeout(400);
const replied = await page.evaluate(() => __log.filter(([c, a]) => c === 'api' && a.method === 'POST' && a.path.endsWith('/messages')).map(([, a]) => [a.path.split('/')[3], a.body.replyToMessageID]).at(-1));
const quote = await page.$eval('#thread .msg.me:last-child .quote', q => q.textContent);
const sentEnd = await page.evaluate(() => { const b = document.querySelector('#msgs'); return [b.scrollHeight > b.clientHeight, Math.round(b.scrollHeight - b.clientHeight - b.scrollTop)]; });
check(sentEnd[0] && sentEnd[1] < 2, `the thread follows a sent message to its end while it opens (${JSON.stringify(sentEnd)})`);
await page.evaluate(() => { const b = document.querySelector('#msgs'); b.scrollTop = b.scrollHeight; });
await page.screenshot({ path: join(out, '1b-reply.png'), clip: { x: 600, y: 440, width: 500, height: 200 } });
check(quote === 'dinner tonight still on?', `a reply shows what it answers above it (${quote})`);
check(!bar[0] && bar[1].includes('dinner tonight') && bar[2] === 'input' && replied[0] === 'wa-lea' && !!replied[1] && (await page.$eval('#reply', r => r.hidden)), `⌘R replies to the hovered message on its app (${JSON.stringify([bar, replied])})`);

// Older messages come a page at a time as the thread is scrolled up, or until it fills the window; both apps stay in time order.
await page.evaluate(() => { window.__page = 1; return select('grp-1').then(() => select('ig-lea')); });
await page.waitForTimeout(1500);
const older = await page.evaluate(() => [[...document.querySelectorAll('#thread .msg')].map(b => msgText(b)), state.msgs.map(m => m.id).join(), __log.filter(([c, a]) => c === 'api' && a.method === 'GET' && a.path.includes('cursor=')).length]);
await page.evaluate(() => { window.__page = 0; });
check(JSON.stringify(older[0]) === JSON.stringify(['did you see the reel I sent?', 'haha yes, too good', '', 'dinner tonight still on?', 'yes! where?', 'the usual place', 'see you at 8 then', '', '8pm']) && older[2] >= 4, `older messages load a page at a time, in order (${JSON.stringify(older)})`);
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
// The hover reaction bar, level with the bubble's middle, is taller than a one-line bubble: showing it must not grow the row.
const tallRows = await page.$$eval('#thread .msg:has(.quick)', rs => rs.map(r => {
  const h0 = r.getBoundingClientRect().height, b = r.querySelector('.bubble').getBoundingClientRect();
  r.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, clientX: r.classList.contains('me') ? b.left + 2 : b.right - 2, clientY: b.top + 2 }));
  const grew = [r.classList.contains('hot'), r.getBoundingClientRect().height - h0];
  document.querySelector('#thread').dispatchEvent(new PointerEvent('pointerleave'));
  return [msgText(r), ...grew];
}).filter(([, hot, d]) => !hot || d !== 0));
check(!tallRows.length, `the reaction bar shows on hover without growing the row (${JSON.stringify(tallRows)})`);

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
await page.keyboard.type('- on my way');
await page.keyboard.press('Enter');
const pend = await page.$$eval('#thread .msg.pending', ms => ms.map(m => msgText(m)));
await page.waitForTimeout(100);
const sent = await page.evaluate(() => __log.filter(([c, a]) => c === 'api' && a.method === 'POST' && a.path.endsWith('/messages')).map(([, a]) => [a.path, a.body.text]));
check(JSON.stringify(sent.at(-1)) === JSON.stringify(['/v1/chats/wa-lea/messages', '- on my way']), 'message sent to the WhatsApp chat');
check(JSON.stringify(pend) === '["- on my way"]', `pending bubble shown at once (${JSON.stringify(pend)})`);
await page.waitForTimeout(1200);
const mine = await page.$$eval('#thread .msg.me', ms => ms.map(m => msgText(m)).filter(t => t.includes('on my way')));
check(await page.$$eval('#thread .msg.pending', ms => ms.length) === 0 && JSON.stringify(mine) === '["on my way"]', `pending bubble replaced by the sent message, even when the app rewrote it (${mine} ${await page.$$eval('#thread .msg.failed', ms => ms.map(m => m.title))})`);
check(await on() === 'whatsapp', 'manual choice holds after sending');

// A sent message flies from the field to its place, every frame one way, and the app's confirmation then moves nothing.
await page.click('#input');
await page.keyboard.type('flying over');
const flight = await page.evaluate(async () => {
  const f = document.querySelector('#input').getBoundingClientRect(), out = [], rect = el => { const r = el.getBoundingClientRect(); return [r.left, r.top, r.width]; };
  document.querySelector('#send').click();
  const t0 = performance.now();
  while (performance.now() - t0 < 500) { const g = document.querySelector('.bubble.flying'); out.push(g && rect(g)); await new Promise(r => requestAnimationFrame(r)); }
  const b = document.querySelector('#thread .msg.pending .bubble');
  return { from: [f.left, f.top, f.width], out, landed: b && [...rect(b), b.style.visibility] };
});
const flown = flight.out.filter(Boolean);
check(flown.length >= 8 && Math.abs(flown[0][0] - flight.from[0]) < 1 && Math.abs(flown[0][2] - flight.from[2]) < 1 && monotonic(flown.map(r => r[0])) && monotonic(flown.map(r => r[2])) && flight.out.at(-1) === null && flight.landed?.[3] === '' && Math.abs(flown.at(-1)[0] - flight.landed[0]) < 2,
  `the bubble flies from the field to its place, one way (${flown.length} frames, ${JSON.stringify([flight.from, flown[0], flown.at(-1), flight.landed])})`);
const beforeEcho = await page.$eval('#thread .msg.pending .bubble', b => b.getBoundingClientRect().top);
await page.waitForTimeout(1200);
const afterEcho = await page.evaluate(() => { const b = [...document.querySelectorAll('#thread .msg.me:not(.pending) .bubble')].find(b => b.textContent.includes('flying over')); return b && [b.getBoundingClientRect().top, b.closest('.msg').querySelector('.receipt')?.textContent]; });
check(afterEcho && Math.abs(afterEcho[0] - beforeEcho) < 0.5 && afterEcho[1] === 'Sent', `the confirmed message stays where it landed, Sent under it (${beforeEcho} → ${JSON.stringify(afterEcho)})`);

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
const pinnedFaces = await page.$$eval('#pinned .row .stack img', is => is.map(i => i.getBoundingClientRect()).map(r => [Math.round(r.left), Math.round(r.top), r.width]));
check(pinnedFaces.length === 2 && pinnedFaces[0][1] === pinnedFaces[1][1] && pinnedFaces[1][0] - pinnedFaces[0][0] === 26 && pinnedFaces.every(r => r[2] === 40), `a pinned group shows all its members at full size, overlapping to the right (${JSON.stringify(pinnedFaces)})`);
await page.screenshot({ path: join(out, '6-pinned.png') });

// ⌘F in the ⌘D search favorites the highlighted row, and the search stays open.
// ⌘M on one row, then ⌘M on another: the second gets the field, focused.
await page.hover('#people .row:has-text("Lea Martin")');
await page.keyboard.press('Meta+m');
await page.waitForSelector('header .who input');
await page.hover('#people .row:has-text("Tom B")');
await page.keyboard.press('Meta+m');
await page.waitForTimeout(800);
const second = await page.evaluate(() => [state.cur.name, document.activeElement === document.querySelector('header .who input')]);
check(JSON.stringify(second) === '["Tom B",true]', `a second ⌘M moves the alias field to the other person, focused (${second})`);
await page.keyboard.press('Escape');
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
// ⌘M on a group in the search renames it in the header; the search then finds it by either name and shows both.
await page.keyboard.press('Meta+d');
await page.fill('#search', 'climbing');
await page.waitForTimeout(300);
await page.keyboard.press('Meta+m');
await page.waitForSelector('header .who input');
await page.fill('header .who input', 'Climbers');
await page.keyboard.press('Enter');
await page.waitForTimeout(500);
const header = await page.$eval('header .who', w => w.textContent);
await page.keyboard.press('Meta+d');
await page.fill('#search', 'climbing crew');
await page.waitForTimeout(400);
const found = await page.$$eval('#results .row:not([data-leaving]) .name', ns => ns.map(n => [n.firstChild.textContent, n.querySelector('.orig')?.textContent]));
check(header === 'Climbers' && JSON.stringify(found) === '[["Climbers","Climbing crew"]]', `⌘M renames a group; searching its old name shows both (${header}, ${JSON.stringify(found)})`);
await page.keyboard.press('Escape');
await page.keyboard.press('Meta+d');
await page.fill('#search', 'sarah');
await page.waitForTimeout(300);
await page.keyboard.press('Meta+m');
await page.waitForSelector('header .who input');
await page.fill('header .who input', 'Sassy');
await page.keyboard.press('Enter');
await page.waitForTimeout(500);
const alias = await page.evaluate(() => [document.querySelector('header .who b').textContent, state.byId.get(state.cur.id).name, state.byId.get(state.cur.id).original]);
await page.click('.more');
await page.waitForTimeout(250);
await page.screenshot({ path: join(out, '8-menu.png') });
const sections = await page.$$eval('.menu > *', es => es.map(e => e.classList.contains('sep') ? '|' : e.textContent.replace(/⌘.|⌘D.*/, '').trim()).join(','));
await page.keyboard.press('Escape');
check(JSON.stringify(alias) === '["Sassy","Sassy","Sarah K"]' && sections.endsWith('favorites,Add to a group…,|,Alias…,Change picture…,|,Muteno badge, no count,|,Merge with…'), `⌘M gives a person an alias; the menu has one section per kind (${alias} / ${sections})`);
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
await page.click('.menu .item:has-text("group…")');
await page.click('.menu .item:has-text("Family")');
await page.waitForTimeout(400);
check(JSON.stringify(await groupFavs('Family')) === '["Lea Martin"]' && !(await topFavs()).includes('Lea Martin'), `Add to Family moves her into the group (${await groupFavs('Family')} / ${await topFavs()})`);
await page.click('#tabbox .newgroup');
await page.keyboard.type('Work');
await page.keyboard.press('Enter');
await page.waitForTimeout(300);
await page.click('#people .row:has-text("Tom B")', { button: 'right' });
await page.click('.menu .item:has-text("group…")');
await page.click('.menu .item:has-text("Work")');
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
await page.click('.menu .item:has-text("group…")');
await page.click('.menu .item:has-text("Family")');
await page.waitForTimeout(400);
await page.click('#favs .fav[title="Tom B"]', { button: 'right' });
await page.click('.menu .item:has-text("group…")');
await page.click('.menu .item:has-text("Work")');
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

// Under my last message: Seen and its time once the other side's read marker reaches it, Sent before.
await page.evaluate(() => {
  const t = new Date(Date.now() - 60000).toISOString();
  __msgs['ig-hugo'].push({ id: 'h2', chatID: 'ig-hugo', text: 'thanks!', timestamp: t, sortKey: String(1e9 - 1), isSender: true, senderID: 'me', senderName: 'x', seen: { 'ig-hugo': t } });
  __msgs['li-hugo'].push({ id: 'l2', chatID: 'li-hugo', text: 'thank you', timestamp: new Date().toISOString(), sortKey: String(1e9), isSender: true, senderID: 'me', senderName: 'x' });
  return refreshList().then(() => select([...state.byId.values()].find(i => i.chats.some(c => c.id === 'li-hugo')).id));
});
await page.waitForSelector('#thread .receipt');
const sentOnly = await page.$eval('#thread .receipt', r => [r.textContent, r.closest('.msg').dataset.id]);
await page.evaluate(() => { __msgs['li-hugo'].at(-1).seen = { 'li-hugo': new Date().toISOString() }; return pollThread(); });
await page.waitForTimeout(100);
const seenNow = await page.$$eval('#thread .receipt', rs => rs.map(r => r.textContent));
check(JSON.stringify(sentOnly) === '["Sent","l2"]' && seenNow.length === 1 && /^Seen \d\d:\d\d$/.test(seenNow[0]), `my last message says Sent, then Seen at its time (${sentOnly} / ${seenNow})`);

// The pointer in the right fifth of a bubble shows my five most used reactions beside it, level with the bubble; a click reacts, a second click takes it back.
const rightFifth = async sel => { const [x, y] = await page.$eval(`${sel} .bubble`, r => { const b = r.getBoundingClientRect(); return [b.right - b.width * .1, b.top + b.height / 2]; }); await page.mouse.move(x, y); };
await page.hover('#thread .msg[data-id="h1"] .bubble', { position: { x: 14, y: 14 } });
await page.waitForTimeout(250);
const offBubble = await page.$eval('#thread .msg[data-id="h1"] .quick', q => getComputedStyle(q).opacity);
await rightFifth('#thread .msg[data-id="h1"]');
await page.waitForTimeout(250);
const quick = await page.$eval('#thread .msg[data-id="h1"]', m => { const q = m.querySelector('.quick').getBoundingClientRect(), b = m.querySelector('.bubble').getBoundingClientRect(); return [m.querySelectorAll('.quick button[data-e]').length, q.left >= b.right, Math.abs((q.top + q.bottom) / 2 - (b.top + b.bottom) / 2) < 1.5]; });
check(offBubble === '0', `the hover bar stays hidden while the pointer is on the left of the bubble (opacity ${offBubble})`);
await page.click('#thread .msg[data-id="h1"] .quick button[data-e="👍"]');
const pill = await page.$eval('#thread .msg[data-id="h1"] .reacts button', b => [b.textContent, b.classList.contains('me')]);
const posted = await page.evaluate(() => __log.filter(([c, a]) => c === 'api' && a.path.includes('/messages/h1/reactions')).map(([, a]) => a.method + ' ' + (a.body?.reactionKey || a.path.split('/').pop())));
await page.click('#thread .msg[data-id="h1"] .reacts button');
const undone = await page.evaluate(() => [document.querySelectorAll('#thread .msg[data-id="h1"] .reacts button').length, __log.filter(([c, a]) => c === 'api' && a.method === 'DELETE').length]);
check(JSON.stringify(quick) === '[5,true,true]' && JSON.stringify(pill) === '["👍",true]' && posted.join() === 'POST 👍' && JSON.stringify(undone) === '[0,1]', `the hover bar reacts and the pill takes it back (${quick} / ${pill} / ${posted} / ${undone})`);

// The + at the end of the hover bar opens every emoji, 5 to a row, searchable by name.
await rightFifth('#thread .msg[data-id="h1"]');
await page.waitForTimeout(250);
await page.click('#thread .msg[data-id="h1"] .quick .all');
await page.waitForTimeout(250);
const pick = await page.evaluate(() => { const p = document.querySelector('#picker'), g = p.querySelector('.grid'); return [p.hidden, document.activeElement === p.querySelector('input'), g.children.length > 25, Math.round(g.clientHeight / g.children[0].offsetHeight), getComputedStyle(g).gridTemplateColumns.split(' ').length]; });
await page.keyboard.type('joy');
await page.waitForTimeout(100);
await page.keyboard.press('Enter');
await page.waitForTimeout(250);
const picked = await page.evaluate(() => [document.querySelector('#picker').hidden, __log.filter(([c, a]) => c === 'api' && a.method === 'POST' && a.path.includes('/reactions')).at(-1)[1].body.reactionKey]);
check(JSON.stringify(pick) === '[false,true,true,5,5]' && JSON.stringify(picked) === '[true,"😂"]', `the + opens the emoji block, :joy then ↵ reacts 😂 (${pick} / ${picked})`);

// A group's bubble of faces in the list: the first click opens the chat, a click on the open one opens its members.
await page.click('#people .row[data-id="grp-1"] .av, #pinned .row[data-id="grp-1"] .av');
await page.waitForTimeout(500);
const firstClick = await page.evaluate(() => [state.cur.id, !profile.box.hidden]);
await page.click('#people .row[data-id="grp-1"] .av, #pinned .row[data-id="grp-1"] .av');
await page.waitForTimeout(500);
const prof = [...firstClick, ...(await page.evaluate(() => [state.cur.id, !profile.box.hidden]))];
await page.keyboard.press('Escape');
await page.waitForTimeout(300);
await page.evaluate(() => select([...state.byId.values()].find(i => i.chats.some(c => c.id === 'li-hugo')).id));
await page.waitForTimeout(300);
check(JSON.stringify(prof) === '["grp-1",false,"grp-1",true]', `a group's picture opens the chat, then on the open chat its profile (${prof})`);

// Right-click on a message: reply, react, copy; on mine, edit and delete too (delete asks a second click).
const menuOf = async id => { await page.click(`#thread .msg[data-id="${id}"] .bubble`, { button: 'right' }); await page.waitForTimeout(250); const t = await page.$$eval('.menu .item span:first-of-type', s => s.map(x => x.textContent)); await page.keyboard.press('Escape'); await page.waitForTimeout(200); return t.join(); };
const theirs = await menuOf('h1'), ours = await menuOf('l2');
await page.click('#thread .msg[data-id="l2"] .bubble', { button: 'right' });
await page.waitForTimeout(250);
await page.click('.menu .item:has-text("Edit")');
const editing = await page.evaluate(() => [document.querySelector('#reply b').textContent, document.querySelector('#input').value]);
await page.fill('#input', 'thank you so much');
await page.keyboard.press('Enter');
await page.waitForTimeout(150);
const edited = await page.evaluate(() => [msgText(document.querySelector('#thread .msg[data-id="l2"]')), __log.filter(([c, a]) => c === 'api' && a.method === 'PUT').map(([, a]) => a.body.text).join(), document.querySelector('#input').value]);
await page.click('#thread .msg[data-id="l2"] .bubble', { button: 'right' });
await page.waitForTimeout(250);
await page.click('.menu .item:has-text("Delete")');
const stillThere = await page.evaluate(() => [!!document.querySelector('.menu'), __log.filter(([c, a]) => c === 'api' && a.method === 'DELETE' && !a.path.includes('/reactions')).length]);
await page.click('.menu .item:has-text("Delete for everyone")');
await page.waitForTimeout(400);
const deleted = await page.evaluate(() => [!!document.querySelector('#thread .msg[data-id="l2"]'), __log.filter(([c, a]) => c === 'api' && a.method === 'DELETE' && !a.path.includes('/reactions')).length]);
check(theirs === 'Reply,React…,Copy' && ours === 'Reply,React…,Copy,Edit,Delete' && JSON.stringify(editing) === '["Editing","thank you"]' && JSON.stringify(edited) === '["thank you so much","thank you so much",""]' && JSON.stringify(stillThere) === '[true,0]' && JSON.stringify(deleted) === '[false,1]',
  `right-click: ${theirs} / ${ours}; edit ${editing} → ${edited}; delete ${stillThere} → ${deleted}`);

// Muting asks each app to mute and shows the bell; merging two group chats keeps the pair.
await page.evaluate(() => mute(state.byId.get(state.cur.id), true));
await page.waitForTimeout(300);
const muted = await page.evaluate(() => [__log.filter(([c, a]) => c === 'api' && a.method === 'PATCH' && a.body.isMuted === true).length, !!document.querySelector(`#people .row[data-id="${state.cur.id}"] .muted, #favs [data-id="${state.cur.id}"] .muted`)]);
await page.evaluate(() => mergeGroups(state.byId.get('grp-1'), state.byId.get('grp-2')));
await page.waitForTimeout(200);
const merged = await page.evaluate(() => __log.filter(([c]) => c === 'set_overrides').at(-1)[1].value.groupMerges);
check(muted[0] === 2 && JSON.stringify(merged) === '[["grp-1","grp-2"]]', `mute PATCHes both chats; merging two groups keeps the pair (${muted} / ${JSON.stringify(merged)})`);

// A voice message plays in the thread: its file is fetched whole, then a play button, a track and the time.
await page.evaluate(() => {
  const wav = (() => { const n = 8000, b = new DataView(new ArrayBuffer(44 + n)); const w = (o, s) => [...s].forEach((c, i) => b.setUint8(o + i, c.charCodeAt(0)));
    w(0, 'RIFF'); b.setUint32(4, 36 + n, true); w(8, 'WAVE'); w(12, 'fmt '); b.setUint32(16, 16, true); b.setUint16(20, 1, true); b.setUint16(22, 1, true); b.setUint32(24, 8000, true); b.setUint32(28, 8000, true); b.setUint16(32, 1, true); b.setUint16(34, 8, true); w(36, 'data'); b.setUint32(40, n, true); for (let i = 0; i < n; i++) b.setUint8(44 + i, 128); return b.buffer; })();
  const real = fetch;
  window.fetch = (u, o) => (String(u).startsWith('beeper://') ? Promise.resolve(new Response(wav)) : real(u, o));
  return refreshList().then(() => select([...state.byId.values()].find(i => i.chats.some(c => c.id === 'dc-tom')).id));
});
await page.waitForSelector('#thread .bubble.voice');
await page.waitForTimeout(600);
const unplayed = await page.evaluate(() => { const v = document.querySelector('#thread .bubble.voice'); return [v.querySelector('.time').textContent, getComputedStyle(v.querySelector('.dot')).opacity]; });
check(JSON.stringify(unplayed) === '["0:01","1"]', `a voice message shows its length and a dot before it is played (${unplayed})`);
await page.click('#thread .bubble.voice .toggle');
await page.waitForTimeout(1600);
const heardNow = await page.evaluate(() => [document.querySelector('#thread .bubble.voice').classList.contains('heard'), JSON.parse(localStorage.heard || '[]').length]);
check(heardNow[0] && heardNow[1] === 1, `played to the end, it is kept as heard (${heardNow})`);
const voice = await page.evaluate(() => { const v = document.querySelector('#thread .bubble.voice'); return [!!v._audio, v.classList.contains('failed'), v.querySelector('.time').textContent, v._audio?.readyState, v._audio?.duration, v._audio?.error?.code, v._audio?.paused]; });
check(voice[0] && !voice[1] && /^0:0\d$/.test(voice[2]), `a voice message loads and plays (${voice})`);

// A click on the group bubble at the top slides in its profile: description and members, admins first; a member who
// is someone in the list opens as that person, ‹ goes back, esc closes.
await page.evaluate(() => select('grp-1'));
await page.waitForSelector('#thread .msg');
await page.click('header .who > .av');
await page.waitForTimeout(110);
const sliding = await page.$eval('#profile .sheet', s => new DOMMatrix(getComputedStyle(s).transform).m41);
await page.waitForSelector('#profile .member');
await page.waitForTimeout(400);
const group = await page.$eval('#profile', p => [p.querySelector('h2').textContent, p.querySelector('.desc')?.textContent, [...p.querySelectorAll('.member b')].map(b => b.textContent), p.querySelector('.member i')?.textContent, p.querySelector('.more-members')?.textContent, Math.round(p.querySelector('.sheet').getBoundingClientRect().right) === Math.round(p.getBoundingClientRect().right)]);
await page.screenshot({ path: join(out, 'profile-group.png') });
check(sliding > 0 && JSON.stringify(group) === JSON.stringify(['Climbing crew', 'Bouldering on fridays', ['Lea Martin', 'Nina'], 'Admin', 'and 1 more', true]), `the group bubble opens the group's profile, sliding in (${Math.round(sliding)} px mid-way, ${JSON.stringify(group)})`);
await page.click('#profile .member >> nth=0');
await page.waitForSelector('#profile .open');
await page.waitForTimeout(400);
const person = await page.$eval('#profile', p => [p.querySelector('h2').textContent, [...p.querySelectorAll('section h3 > span:not(.net)')].map(s => s.textContent), [...p.querySelectorAll('.line b')].map(b => b.textContent), !!p.querySelector('.back')]);
await page.screenshot({ path: join(out, 'profile-person.png') });
check(JSON.stringify(person) === JSON.stringify(['Lea Martin', ['Instagram', 'WhatsApp'], ['Lea Martin', '@lea', 'Lea Martin', '@lea'], true]), `a member who is in the list opens as that person, each app's details (${JSON.stringify(person)})`);
// Merge with… from the profile: the same picker as the ⋯ menu, under the button.
await page.click('#profile .merge');
await page.waitForSelector('.menu .found .item');
const mergeWith = await page.$eval('.menu .found .item span', s => s.textContent);
await page.click('.menu .found .item >> nth=0');
await page.waitForFunction(() => __log.filter(([c]) => c === 'set_overrides').at(-1)?.[1].value.merges?.length);
const saved = await page.evaluate(() => [profile.view.chats[0].id, __log.filter(([c]) => c === 'set_overrides').at(-1)[1].value.merges.at(-1)]);
check(saved[1]?.[0] === saved[0], `Merge with… in a profile merges that person with the one picked (${mergeWith}: ${JSON.stringify(saved)})`);
await page.evaluate(() => invoke('set_overrides', { value: {} }).then(refreshList));
await page.click('#profile .back');
await page.waitForSelector('#profile .member');
await page.keyboard.press('Escape');
await page.waitForTimeout(300);
check(await page.$eval('#profile', p => p.hidden), '‹ goes back to the group, esc closes the profile');

await page.evaluate(() => (sessionStorage.overrides = JSON.stringify({ openAtLaunch: 'te-sarah' })));
await page.reload();
await page.waitForSelector('#thread .msg');
check((await page.textContent('#thread')).includes('meeting moved to 3pm'), "overrides' openAtLaunch opens that chat at launch");

check(errors.length === 0, `no page errors ${errors.join(' | ')}`);
await browser.close();
console.log(fails.length ? `${fails.length} FAILED` : 'all passed');
process.exit(fails.length ? 1 : 0);

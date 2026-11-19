// Reproductions of the deep review's defects (F1 to F5, then R<row of its report>), headless WebKit on the stub of
// ui.mjs: `node tests/dr-repro.mjs`.
// Each check asserts the correct behaviour, so FAIL means the defect is real.
import { webkit } from '/Users/mr/node_modules/playwright/index.mjs';
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { stub } from './stub.mjs';

const ui = join(dirname(fileURLToPath(import.meta.url)), '../ui');
const XSS = '<img src=x onerror="window.__xss=1">';

// Runs after stub(): media served for beeper://, blob URL counters, gates that hold an API call, and extra data.
const extra = XSS => {
  const n = 8000, b = new DataView(new ArrayBuffer(44 + n)), w = (o, s) => [...s].forEach((c, i) => b.setUint8(o + i, c.charCodeAt(0)));
  w(0, 'RIFF'); b.setUint32(4, 36 + n, true); w(8, 'WAVE'); w(12, 'fmt '); b.setUint32(16, 16, true); b.setUint16(20, 1, true); b.setUint16(22, 1, true); b.setUint32(24, 8000, true); b.setUint32(28, 8000, true); b.setUint16(32, 1, true); b.setUint16(34, 8, true); w(36, 'data'); b.setUint32(40, n, true); for (let i = 0; i < n; i++) b.setUint8(44 + i, 128);
  const realFetch = window.fetch;
  window.fetch = (u, o) => (String(u).startsWith('beeper://') ? Promise.resolve(new Response(b.buffer.slice(0))) : realFetch(u, o));
  const blobs = (window.__blobs = { made: 0, revoked: 0 });
  const mk = URL.createObjectURL.bind(URL), rv = URL.revokeObjectURL.bind(URL);
  URL.createObjectURL = o => (blobs.made++, mk(o));
  URL.revokeObjectURL = u => (blobs.revoked++, rv(u));
  const real = window.__TAURI__.core.invoke;
  window.__gates = {};
  window.hold = (name, method, re) => { let open; const g = { method, re: new RegExp(re), hits: 0, p: new Promise(r => (open = r)) }; g.release = () => { g.off = true; open(); }; window.__gates[name] = g; };
  window.__TAURI__.core.invoke = async (cmd, args) => {
    const g = cmd === 'api' && Object.values(window.__gates).find(g => !g.off && g.method === args.method && g.re.test(args.path));
    if (g) { g.hits++; await g.p; if (g.fail) throw g.fail; }
    return real(cmd, args);
  };
  const M = window.__msgs, t = m => new Date(Date.now() - m * 60000).toISOString();
  const msg = (chatID, id, text, min) => ({ id, chatID, text, timestamp: t(min), sortKey: String(1e9 - min), type: 'TEXT', isSender: false, senderID: chatID, senderName: 'x' });
  M['wa-tom'].splice(1, 0, { ...msg('wa-tom', 'tvo', '', 93), attachments: [{ type: 'audio', isVoiceNote: true, srcURL: 'mxc://voice2', mimeType: 'audio/wav' }] });
  M['wa-tom'].at(-1).reactions = [{ participantID: 'wa-tom', reactionKey: XSS }];
  M['te-sarah'].unshift(...Array.from({ length: 15 }, (_, i) => msg('te-sarah', 's-old-' + (14 - i), 'old ' + (14 - i), 500 + (14 - i) * 10)));
};

const browser = await webkit.launch();
async function fresh() {
  const page = await browser.newPage({ viewport: { width: 1100, height: 720 } });
  await page.addInitScript(stub);
  await page.addInitScript(extra, XSS);
  await page.route('http://chats.test/**', r => {
    const file = new URL(r.request().url()).pathname.slice(1) || 'index.html';
    if (!existsSync(join(ui, file))) return r.fulfill({ status: 404, body: '' });
    r.fulfill({ body: readFileSync(join(ui, file)), contentType: { html: 'text/html', css: 'text/css', js: 'text/javascript' }[file.split('.').pop()] });
  });
  page.errors = [];
  page.on('pageerror', e => page.errors.push(String(e)));
  await page.goto('http://chats.test/index.html');
  await page.waitForSelector('#people .row');
  page.open = chat => page.evaluate(c => select([...state.byId.values()].find(i => i.chats.some(x => x.id === c)).id), chat);
  return page;
}
const report = (id, ok, what) => console.log(`${ok === null ? 'UNREACHED' : ok ? 'ok' : 'FAIL'} ${id} ${what}`);
const live = page => page.evaluate(() => __blobs.made - __blobs.revoked);

// F1: blob URLs of thread videos and voice messages are never revoked across conversation switches.
{
  const page = await fresh();
  await page.open('wa-tom');
  await page.waitForTimeout(1000);
  const media = await page.evaluate(() => [document.querySelector('#thread .bubble.video video')?.src.startsWith('blob:'), !!document.querySelector('#thread .bubble.voice[data-id^="tvo/"]')?._audio]);
  const counts = [await live(page)];
  for (let i = 0; i < 5; i++) {
    await page.open('ig-hugo');
    await page.waitForTimeout(400);
    await page.open('wa-tom');
    await page.waitForTimeout(1000);
    counts.push(await live(page));
  }
  if (!media[0] || !media[1]) report('F1', null, `video blob / voice audio not loaded (${media})`);
  else report('F1', counts.at(-1) <= counts[0], `live blob URLs after open then each of 5 switches back: ${counts.join(', ')}`);
  await page.close();
}

// F2: closing the viewer revokes the thread video's own blob URL.
{
  const page = await fresh();
  await page.open('wa-tom');
  await page.waitForSelector('#thread .bubble.video video[src^="blob:"]');
  await page.waitForTimeout(500);
  const loads = () => page.evaluate(async () => { const s = document.querySelector('#thread .bubble.video video').src; return [s, await fetch(s).then(r => r.ok).catch(() => false)]; });
  const viewerVideo = () => page.evaluate(() => { const v = document.querySelector('#viewer:not([hidden]) video'); return v ? [v.src, v.error?.code ?? null, v.readyState] : null; });
  const before = await loads();
  await page.click('#thread .bubble.video.clip video');
  await page.waitForTimeout(700);
  const first = await viewerVideo();
  await page.keyboard.press('Escape');
  await page.waitForTimeout(700);
  const after = await loads();
  await page.click('#thread .bubble.video.clip video');
  await page.waitForTimeout(700);
  const second = await viewerVideo();
  if (!first) report('F2', null, 'the viewer did not open on the thread video');
  else report('F2', after[1] && second && second[1] === null && second[2] >= first[2], `thread blob fetch ok before/after close: ${before[1]}/${after[1]}, same src: ${before[0] === after[0]}, viewer [error, readyState] first ${JSON.stringify(first.slice(1))}, reopened ${JSON.stringify(second?.slice(1))}`);
  await page.close();
}

// F3: a reaction key from another user lands unescaped in the hover bar and the emoji picker.
{
  const page = await fresh();
  await page.open('wa-tom');
  await page.waitForTimeout(600);
  const clicked = await page.evaluate(x => { const b = [...document.querySelectorAll('#thread .reacts button')].find(b => b.dataset.e === x); b?.click(); return !!b; }, XSS);
  await page.waitForTimeout(600);
  const afterReact = await page.evaluate(() => [window.__xss || 0, document.querySelectorAll('#thread .quick img').length]);
  await page.evaluate(() => { window.__xss = 0; return openPicker(document.querySelector('#thread .msg[data-id="t1"]')); });
  await page.waitForTimeout(600);
  const afterPicker = await page.evaluate(() => [window.__xss || 0, document.querySelectorAll('#picker .grid img').length]);
  if (!clicked) report('F3', null, 'the reaction button with the crafted key was not drawn');
  else report('F3', !afterReact[0] && !afterPicker[0], `after "react the same": __xss=${afterReact[0]}, <img> in hover bars=${afterReact[1]}; after opening the picker: __xss=${afterPicker[0]}, <img> in grid=${afterPicker[1]}`);
  await page.close();
}

// F4: a send that completes after another conversation opened marks that other conversation read.
{
  const page = await fresh();
  await page.open('wa-tom');
  await page.waitForTimeout(600);
  await page.evaluate(() => hold('send', 'POST', '^/v1/chats/wa-tom/messages$'));
  await page.focus('#input');
  await page.keyboard.type('hello');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(300);
  await page.open('ig-lea');
  await page.waitForTimeout(600);
  const leaReads = () => page.evaluate(() => [__log.filter(([c, a]) => c === 'api' && a.method === 'POST' && /^\/v1\/chats\/(wa|ig)-lea\/read$/.test(a.path)).length, state.cur.unread, document.querySelector(`#list .row[data-id="${CSS.escape(state.cur.id)}"] .badge`)?.textContent || '', __gates.send.hits]);
  const before = await leaReads();
  await page.evaluate(() => __gates.send.release());
  await page.waitForTimeout(1000);
  const after = await leaReads();
  if (before[3] !== 1) report('F4', null, `the send never reached the held API call (hits ${before[3]})`);
  else report('F4', after[0] === 0 && after[1] > 0, `Lea (opened while the send to Tom was in flight) [read calls, unread, badge] before the send landed ${JSON.stringify(before.slice(0, 3))}, after ${JSON.stringify(after.slice(0, 3))}`);
  await page.close();
}

// F5: an older page of A still in flight when B opens lands in B's pool, then in B's thread.
{
  const page = await fresh();
  await page.evaluate(() => hold('older', 'GET', '^/v1/chats/te-sarah/messages\\?cursor='));
  await page.open('te-sarah');
  await page.waitForTimeout(500);
  const hits = await page.evaluate(() => __gates.older.hits);
  await page.open('ig-hugo');
  await page.waitForTimeout(500);
  await page.evaluate(() => __gates.older.release());
  await page.waitForTimeout(500);
  const sarah = () => page.evaluate(() => [state.pool.filter(m => m.chatID === 'te-sarah').length, state.msgs.filter(m => m.chatID === 'te-sarah').length, document.querySelectorAll('#thread .msg[data-id^="s-old-"]').length]);
  const landed = await sarah();
  const loaded = await page.evaluate(() => loadOlder());
  await page.waitForTimeout(500);
  const end = await sarah();
  if (hits !== 1) report('F5', null, `A's older page was never requested (hits ${hits})`);
  else report('F5', [...landed, ...end].every(x => x === 0), `Sarah's messages in Hugo's [pool, msgs, thread rows] once A's page landed ${JSON.stringify(landed)}, after Hugo's own older load (returned ${loaded}) ${JSON.stringify(end)}`);
  await page.close();
}

// R6: a draft is kept by the conversation, not by whichever of its chats is newest.
{
  const page = await fresh();
  await page.open('ig-lea');
  await page.waitForTimeout(500);
  await page.focus('#input');
  await page.keyboard.type('draft for lea');
  const first = await page.evaluate(() => state.cur.chats[0].id);
  // Lea then writes on her other app: that chat becomes the newest.
  await page.evaluate(() => state.cur.chats.reverse());
  await page.open('ig-hugo');
  await page.waitForTimeout(400);
  await page.open('ig-lea');
  await page.waitForTimeout(400);
  const back = await page.evaluate(() => [state.cur.chats[0].id, input.value]);
  report('R6', back[1] === 'draft for lea', `draft typed while ${first} was newest, reopened with ${back[0]} newest: ${JSON.stringify(back[1])}`);
  await page.close();
}

// R7: a playing voice message stops once its row leaves the thread.
{
  const page = await fresh();
  await page.open('dc-tom');
  await page.waitForSelector('#thread .bubble.voice');
  await page.waitForTimeout(400);
  await page.click('#thread .bubble.voice .toggle');
  await page.waitForTimeout(500);
  const playing = await page.evaluate(() => { const au = (window.__au = document.querySelector('#thread .bubble.voice')._audio); if (au) au.loop = true; return !!au && !au.paused; });
  await page.open('ig-hugo');
  await page.waitForTimeout(600);
  const paused = await page.evaluate(() => __au.paused);
  if (!playing) report('R7', null, 'the voice message did not start playing');
  else report('R7', paused, `voice message paused after another conversation opened: ${paused}`);
  await page.close();
}

// R8: a recording goes to the conversation it was started in, and stopping it with no target yet throws nothing.
{
  const page = await fresh();
  await page.evaluate(() => {
    window.__tracks = 0;
    Object.defineProperty(navigator, 'mediaDevices', { value: { getUserMedia: async () => (__tracks++, { getTracks: () => [{ stop: () => __tracks-- }] }) } });
    window.MediaRecorder = class {
      static isTypeSupported(t) { return t === 'audio/mp4'; }
      constructor(stream, o) { this.stream = stream; this.mimeType = o.mimeType; }
      start() {}
      stop() { this.ondataavailable({ data: new Blob(['x'], { type: 'audio/mp4' }) }); setTimeout(() => this.onstop()); }
    };
  });
  const sends = () => page.evaluate(() => ['lea', 'tom'].map(p => __log.filter(([c, a]) => c === 'api' && a.method === 'POST' && new RegExp(`^/v1/chats/\\w+-${p}/messages$`).test(a.path)).length));
  await page.open('ig-lea');
  await page.waitForTimeout(500);
  await page.click('#mic');
  await page.waitForTimeout(200);
  await page.open('dc-tom');
  await page.waitForTimeout(600);
  await page.click('#mic');
  await page.waitForTimeout(800);
  const a = [...(await sends()), await page.evaluate(() => __tracks)];
  await page.open('ig-lea');
  await page.waitForTimeout(600);
  await page.click('#mic');
  await page.waitForTimeout(200);
  const err = await page.evaluate(async () => { select([...state.byId.values()].find(i => i.chats.some(c => c.id === 'dc-tom')).id); try { await toggleRecord(); return null; } catch (e) { return String(e); } });
  await page.waitForTimeout(800);
  const b = [...(await sends()), await page.evaluate(() => __tracks)];
  report('R8', a[0] === 1 && a[1] === 0 && a[2] === 0 && !err && b[0] === 2 && b[1] === 0 && b[2] === 0,
    `started in Lea, stopped in Tom: [sent to Lea, to Tom, live mic tracks] ${JSON.stringify(a)}; stopped with no target yet: error ${err}, then ${JSON.stringify(b)}`);
  await page.close();
}

// R12: a pasted image goes to the conversation it was pasted in, even when another one opens while it decodes.
{
  const page = await fresh();
  await page.open('ig-lea');
  await page.waitForTimeout(500);
  const pasted = await page.evaluate(() => {
    const png = Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='), c => c.charCodeAt(0));
    const dt = new DataTransfer();
    dt.items.add(new File([png], 'p.png', { type: 'image/png' }));
    const ev = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true });
    input.dispatchEvent(ev);
    select([...state.byId.values()].find(i => i.chats.some(c => c.id === 'dc-tom')).id);
    return ev.defaultPrevented;
  });
  await page.waitForTimeout(1000);
  const sent = await page.evaluate(() => ['lea', 'tom'].map(p => __log.filter(([c, a]) => c === 'api' && a.method === 'POST' && new RegExp(`^/v1/chats/\\w+-${p}/messages$`).test(a.path)).length));
  if (!pasted) report('R12', null, 'the paste handler did not take the image');
  else report('R12', sent[0] === 1 && sent[1] === 0 && !page.errors.length, `[sent to Lea, to Tom] ${JSON.stringify(sent)}, page errors: ${JSON.stringify(page.errors)}`);
  await page.close();
}

// R13: splitting off the app replied on moves the reply target and takes that app's messages out of the thread.
{
  const page = await fresh();
  await page.evaluate(async () => { await invoke('set_overrides', { value: { merges: [['dc-tom', 'wa-tom']], splits: [] } }); await refreshList(); });
  await page.open('dc-tom');
  await page.waitForTimeout(600);
  const merged = await page.evaluate(() => { setTarget(state.cur.chats.find(c => c.id === 'wa-tom'), true); return state.cur.chats.length; });
  await page.evaluate(() => split(state.cur, state.cur.chats.find(c => c.id === 'wa-tom')));
  await page.waitForTimeout(600);
  const after = await page.evaluate(() => [state.cur.chats.map(c => c.id).join(), state.target?.chat.id, state.msgs.filter(m => m.chatID === 'wa-tom').length, document.querySelectorAll('#thread .msg[data-id="t1"]').length]);
  if (merged !== 2) report('R13', null, `Tom's two chats were not merged (${merged})`);
  else report('R13', after[0] === 'dc-tom' && after[1] === 'dc-tom' && after[2] === 0 && after[3] === 0, `after splitting WhatsApp off: [chats, target, WhatsApp messages kept, WhatsApp rows shown] ${JSON.stringify(after)}`);
  await page.close();
}

// R14: a send that fails gives its text back: to the field, or to the draft of a conversation left meanwhile.
{
  const page = await fresh();
  await page.open('wa-tom');
  await page.waitForTimeout(600);
  const failing = () => page.evaluate(() => { hold('send', 'POST', '^/v1/chats/wa-tom/messages$'); __gates.send.fail = 'Beeper Server is down'; });
  await failing();
  await page.focus('#input');
  await page.keyboard.type('see you soon');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(300);
  await page.evaluate(() => __gates.send.release());
  await page.waitForTimeout(500);
  const here = await page.evaluate(() => input.value);
  await page.evaluate(() => { input.value = ''; autosize(); });
  await failing();
  await page.focus('#input');
  await page.keyboard.type('second try');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(300);
  await page.open('ig-hugo');
  await page.waitForTimeout(400);
  await page.evaluate(() => __gates.send.release());
  await page.waitForTimeout(400);
  await page.open('wa-tom');
  await page.waitForTimeout(400);
  const away = await page.evaluate(() => input.value);
  report('R14', here === 'see you soon' && away === 'second try', `field after a failed send: ${JSON.stringify(here)}; after one that failed while Hugo was open, back in Tom: ${JSON.stringify(away)}`);
  await page.close();
}

await browser.close();

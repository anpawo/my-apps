// Made-up chats behind a stand-in Tauri invoke, shared by the checks (ui.mjs) and the README recording (demo.mjs).
// `demo` adds the fuller made-up address book the README recording shows (favorites, groups, pictures); the checks run without it.
export const stub = demo => {
  // A message's own text: the hover reactions and the Sent/Seen line are not part of it.
  window.msgText = m => { const c = m.cloneNode(true); c.querySelectorAll('.quick, .receipt, .reacts, .at').forEach(e => e.remove()); return c.textContent.trim(); };
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
  const msg = (chatID, id, text, min, isSender = false) => ({ id, chatID, text, timestamp: t(min), sortKey: String(1e9 - min), type: 'TEXT', isSender, senderID: isSender ? 'me' : chatID, senderName: 'x' });
  const msgs = {
    'wa-lea': [msg('wa-lea', 'w1', 'dinner tonight still on?', 50), msg('wa-lea', 'w2', 'yes! where?', 45, true), msg('wa-lea', 'w3', 'the usual place', 30)],
    'ig-lea': [msg('ig-lea', 'i1', 'did you see the reel I sent?', 1500), msg('ig-lea', 'i2', 'haha yes, too good', 1490, true), { ...msg('ig-lea', 'i2r', '<p><a href="https://www.instagram.com/reel/ABC123/?id=1&amp;x=y" rel="noopener">https://www.instagram.com/reel/ABC123/</a></p>', 1480), attachments: [{ type: 'img', srcURL: 'mxc://thumb' }] }, msg('ig-lea', 'i3', 'see you at 8 then', 5)],
    'dc-tom': [{ ...msg('dc-tom', 'v1', '', 120), attachments: [{ type: 'audio', isVoiceNote: true, srcURL: 'mxc://voice', mimeType: 'audio/wav' }] }, msg('dc-tom', 'd1', 'gg last night', 60)],
    'wa-tom': [{ ...msg('wa-tom', 'tv', '', 95), attachments: [{ type: 'video', srcURL: 'file:///clip.mp4', mimeType: 'video/mp4', size: { width: 720, height: 1280 } }] }, msg('wa-tom', 't1', 'call me when you can', 90)],
    'ig-hugo': [msg('ig-hugo', 'h1', 'sent you the deck', 200)], 'li-hugo': [msg('li-hugo', 'l1', 'congrats on the new role', 300)],
    'te-sarah': [msg('te-sarah', 's1', 'meeting moved to 3pm', 400)],
    'grp-1': [{ ...msg('grp-1', 'g0', 'Nina joined the chat', 25), type: undefined }, msg('grp-1', 'g1', 'who is in for friday?', 20)], 'grp-2': [msg('grp-2', 'g2', 'new release is out', 700)],
  };
  for (const c of chats) c.preview = { text: msgs[c.id].at(-1).text, isSender: msgs[c.id].at(-1).isSender };
  const groups = [
    { id: 'grp-1', name: 'Climbing crew', imgs: [], faces: ['mxc://nina', 'mxc://paul'], unread: 3, last: t(20), preview: { text: 'who is in for friday?', senderName: 'Nina' }, chats: [{ id: 'grp-1', network: 'WhatsApp', accountID: 'whatsapp', unread: 3, last: t(20) }] },
    { id: 'grp-2', name: 'Rust FR', imgs: [], unread: 0, last: t(700), preview: { text: 'new release is out', senderName: 'Bot' }, chats: [{ id: 'grp-2', network: 'Discord', accountID: 'discordgo', unread: 0, last: t(700) }] },
  ];
  let overrides = JSON.parse(sessionStorage.overrides || '{}');

  if (demo) {
    // Drawn faces, so every picture in the recording is invented.
    const face = (bg, skin, hair, shirt, long) => 'data:image/svg+xml,' + encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" fill="${bg}"/>${long ? `<path d="M17 30c0-13 7-18 15-18s15 5 15 18v16H17z" fill="${hair}"/>` : ''}<path d="M10 66c0-15 10-23 22-23s22 8 22 23z" fill="${shirt}"/><circle cx="32" cy="29" r="12.5" fill="${skin}"/><path d="M19.5 28c0-10 6-15.5 12.5-15.5S44.5 18 44.5 28c-3-5-7.5-7-12.5-7s-9.5 2-12.5 7z" fill="${hair}"/></svg>`);
    const pic = (w, h, sky, ground) => 'data:image/svg+xml,' + encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}"><defs><linearGradient id="s" x2="0" y2="1"><stop stop-color="${sky[0]}"/><stop offset="1" stop-color="${sky[1]}"/></linearGradient></defs><rect width="${w}" height="${h}" fill="url(#s)"/><circle cx="${w * 0.7}" cy="${h * 0.42}" r="${h * 0.12}" fill="#ffe3a3"/><path d="M0 ${h * 0.7}q${w * 0.25}-${h * 0.18} ${w * 0.5} 0t${w * 0.5} 0V${h}H0z" fill="${ground}"/></svg>`);
    const faces = {
      lea: face('#f2b8a0', '#f1c9a5', '#5a3825', '#2f6f8f', true), 'tom-dc': face('#9fc5e8', '#e0ac69', '#2b2b2b', '#c0392b'), 'tom-wa': face('#b6d7a8', '#f3d2b3', '#a0522d', '#34495e'),
      hugo: face('#d5a6bd', '#c68642', '#1b1b1b', '#16a085'), sarah: face('#ffe599', '#f1c27d', '#8b4513', '#8e44ad', true), chloe: face('#a4c2f4', '#fddbb4', '#e6b450', '#e67e22', true),
      mom: face('#ead1dc', '#f5d0b0', '#6d4c41', '#d35400', true), dad: face('#cfe2f3', '#e8b48f', '#9e9e9e', '#2c3e50'), alice: face('#d9ead3', '#f7d7c4', '#3e2723', '#c2185b', true),
      emma: face('#fce5cd', '#ffdfc4', '#b5651d', '#1abc9c', true), anna: face('#d0e0e3', '#f2d6cb', '#f4d03f', '#5d6d7e', true), noah: face('#f4cccc', '#8d5524', '#111', '#f39c12'),
      jules: face('#fff2cc', '#f0c8a0', '#7b3f00', '#27ae60'), max: face('#c9daf8', '#e6b98f', '#4a2c17', '#7f8c8d'), zoe: face('#e6b8af', '#ffe0bd', '#c0392b', '#2980b9', true), grandma: face('#ddd', '#f3cfb3', '#eee', '#7d3c98', true),
    };
    const add = (id, network, person, name, min, unread = 0, extra = {}) => chats.push({ ...chat(id, network, person, name, t(min), unread), pid: 'p-' + id, ...extra });
    add('sm-chloe', 'Google Messages', 'chloe', 'Chloe Dubois', 12, 1);
    add('ig-chloe', 'Instagram', 'chloe', 'chloe.dubois', 240);
    add('wa-mom', 'WhatsApp', 'mom', 'Mom', 75);
    add('wa-dad', 'WhatsApp', 'dad', 'Dad', 600);
    add('wa-alice', 'WhatsApp', 'alice', 'Alice', 1300);
    add('wa-grandma', 'WhatsApp', 'grandma', 'Grandma', 3000);
    add('te-emma', 'bridgev2', 'emma', 'Emma Laurent', 150, 0, { accountID: 'sh-teams' });
    add('li-anna', 'LinkedIn', 'anna', 'Anna Schmidt', 2000);
    add('mx-noah', 'Matrix', 'noah', 'Noah V', 1800);
    add('sc-jules', 'Snapchat', 'jules', 'Jules P', 35, 2);
    add('dc-max', 'Discord', 'max', 'maxou', 110);
    add('ig-zoe', 'Instagram', 'zoe', 'Zoe', 500);
    for (const c of chats) c.img = faces[c.person];
    overrides.names ||= { 'dc-max': 'Max from the gym' };
    const sky = pic(400, 300, ['#ff9a8b', '#ff6a88'], '#3b2a4a');
    Object.assign(msgs['ig-lea'][2].attachments[0], { srcURL: pic(90, 160, ['#f58529', '#515bd4'], '#dd2a7b') });
    msgs['ig-lea'][1].reactions = [{ participantID: 'ig-lea', reactionKey: '😂' }];
    msgs['wa-lea'].splice(2, 0, { ...msg('wa-lea', 'w2p', '', 32), attachments: [{ type: 'img', srcURL: sky, size: { width: 200, height: 150 } }] });
    msgs['wa-lea'].at(-1).linkedMessageID = 'w2';
    Object.assign(msgs, {
      'sm-chloe': [msg('sm-chloe', 'c1', 'landed! 🛬', 12)], 'ig-chloe': [msg('ig-chloe', 'c0', 'cute pic', 240, true)],
      'wa-mom': [msg('wa-mom', 'm1', 'call me back when you can ❤️', 75)], 'wa-dad': [msg('wa-dad', 'f1', 'the car is fixed', 600)],
      'wa-alice': [msg('wa-alice', 'a1', 'happy birthday!!', 1300, true)], 'wa-grandma': [msg('wa-grandma', 'gm1', 'thank you my dear', 3000)],
      'te-emma': [msg('te-emma', 'e1', 'slides look great', 150)], 'li-anna': [msg('li-anna', 'n1', 'thanks for connecting', 2000)],
      'mx-noah': [msg('mx-noah', 'x1', 'pushed the fix', 1800)], 'sc-jules': [msg('sc-jules', 'j0', 'look at this', 36), msg('sc-jules', 'j1', 'snap me back', 35)],
      'dc-max': [msg('dc-max', 'mx1', 'leg day tomorrow?', 110)], 'ig-zoe': [msg('ig-zoe', 'z1', 'loved your story', 500)],
      'grp-3': [{ ...msg('grp-3', 'f3', 'who took my oat milk', 55), senderName: 'Zoe' }], 'grp-4': [{ ...msg('grp-4', 'f4', 'notes from today are up', 900), senderName: 'Noah' }],
    });
    msgs['dc-tom'].splice(1, 0, { ...msg('dc-tom', 'd0', '<p>the fix:</p><pre><code>git pull --rebase\ncargo build --release</code></pre><ul><li><strong>then</strong> restart it</li><li>works on <code>main</code></li></ul>', 70) },
      { ...msg('dc-tom', 'dx', 'wrong chat sorry', 65), isDeleted: true });
    for (const c of chats) c.preview = { text: msgs[c.id].at(-1).text, isSender: msgs[c.id].at(-1).isSender };
    groups[0].faces = [faces.zoe, faces.noah, faces.lea, faces.jules];
    groups[1].faces = [faces['tom-dc'], faces.max];
    groups[1].chats[0].muted = true;
    groups.push(
      { id: 'grp-3', name: 'Flat 4B', imgs: [], faces: [faces.zoe, faces.max, faces.chloe], unread: 0, last: t(55), preview: { text: 'who took my oat milk', senderName: 'Zoe' }, chats: [{ id: 'grp-3', network: 'WhatsApp', accountID: 'whatsapp', unread: 0, last: t(55) }] },
      { id: 'grp-4', name: 'Study group', imgs: [], faces: [faces.noah, faces.anna, faces.emma], unread: 0, last: t(900), preview: { text: 'notes from today are up', senderName: 'Noah' }, chats: [{ id: 'grp-4', network: 'Matrix', accountID: 'matrix', unread: 0, last: t(900) }] });
  }
  const log = (window.__log = []);
  function people() {
    const root = {};
    const find = k => (root[k] && root[k] !== k ? find(root[k]) : k);
    for (const [a, b] of overrides.merges || []) {
      const pa = chats.find(c => c.id === a)?.person, pb = chats.find(c => c.id === b)?.person;
      if (pa && pb) root[find(pa)] = find(pb);
    }
    const by = {};
    for (const c of chats.filter(c => !c.archived)) (by[find(c.person)] ||= []).push(c);
    return Object.values(by).map(cs => {
      cs.sort((a, b) => b.last.localeCompare(a.last));
      const name = cs.map(c => c.title).sort((a, b) => b.length - a.length)[0], alias = cs.map(c => overrides.names?.[c.id]).find(Boolean);
      return { id: cs.map(c => c.id).sort()[0], name: alias || name, original: alias ? name : null, imgs: [...cs.map(c => overrides.pictures?.[c.id]).filter(Boolean), ...cs.map(c => c.img).filter(Boolean), 'mxc://ig', 'mxc://wa'],
        unread: cs.reduce((s, c) => s + c.unread, 0), last: cs[0].last, preview: cs[0].preview, chats: cs };
    }).sort((a, b) => b.last.localeCompare(a.last));
  }
  const invoke = async (cmd, args) => {
    log.push([cmd, args]);
    await new Promise(r => setTimeout(r, 30));
    if (cmd === 'people') return structuredClone({ people: people(), groups: groups.map(g => ({ ...g, ...(overrides.pictures?.[g.id] && { imgs: [overrides.pictures[g.id]], faces: [] }), name: overrides.names?.[g.id] || g.name, original: overrides.names?.[g.id] ? g.name : null, hidden: (overrides.hidden || []).includes(g.id) })) });
    if (cmd === 'overrides') return structuredClone(overrides);
    if (cmd === 'set_overrides') { overrides = args.value; return null; }
    if (cmd === 'open_url') return null;
    if (cmd === 'reel') return new Uint8Array(8).buffer;
    if (cmd === 'update_build') return window.__update || null;
    if (cmd === 'api') {
      if (args.path === '/v1/assets/upload/base64') return { uploadID: 'up1', duration: 1.5 };
      const arc = args.path.match(/^\/v1\/chats\/([^/]+)\/archive$/);
      if (arc) { chats.find(c => c.id === decodeURIComponent(arc[1])).archived = args.body.archived; return null; }
      if (args.method === 'DELETE' && !args.path.includes('/reactions')) { const [, c, id] = args.path.match(/chats\/([^/]+)\/messages\/([^/]+)/); msgs[decodeURIComponent(c)] = msgs[decodeURIComponent(c)].filter(x => x.id !== decodeURIComponent(id)); return {}; }
      if (args.path.includes('/reactions') || ['PATCH', 'PUT'].includes(args.method)) return {};
      if (args.path === '/v1/accounts') return [{ accountID: 'discordgo', network: 'Discord' }, { accountID: 'matrix', network: 'Beeper' }];
      if (args.path.startsWith('/v1/accounts/matrix/')) throw new Error('Beeper account searched');
      if (args.path.startsWith('/v1/accounts/discordgo/contacts?query=')) {
        const q = decodeURIComponent(args.path.split('=')[1]);
        return { items: 'le_tamanoir martin'.includes(q) ? [{ id: '777', fullName: 'Martin', username: 'le_tamanoir' }] : [] };
      }
      if (args.method === 'POST' && args.path === '/v1/chats') {
        if (!chats.some(c => c.id === 'dc-martin')) { chats.push({ ...chat('dc-martin', 'Discord', 'martin', 'Martin', t(0)), accountID: 'discordgo', pid: '@discordgo_777:beeper.local' }); msgs['dc-martin'] = []; }
        return { id: 'dc-martin' };
      }
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
        if (!before && window.__held?.has(id)) await new Promise(() => {});
        const all = [...msgs[id]].reverse().filter(x => !before || Number(x.sortKey) < Number(before));
        const items = all.slice(0, window.__page || 20);
        return { items, hasMore: all.length > items.length, oldestCursor: items.at(-1)?.sortKey };
      }
      if (args.method === 'POST' && m[2] === 'messages') { msgs[id].push({ ...msg(id, 'sent-' + id + '-' + msgs[id].length, (args.body.text || '').replace(/^- /, ''), 0, true), linkedMessageID: args.body.replyToMessageID, attachments: args.body.attachment && [{ type: 'audio', isVoiceNote: true, srcURL: 'mxc://up', mimeType: 'audio/mp4' }] }); return { id: 'ok' }; }
      if (args.method === 'POST' && m[2] === 'read') { const c = chats.find(c => c.id === id); if (c) c.unread = 0; return {}; }
    }
    throw new Error('unexpected ' + cmd + ' ' + JSON.stringify(args));
  };
  window.__msgs = msgs;
  window.__TAURI__ = { core: { invoke } };
};

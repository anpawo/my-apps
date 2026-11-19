// Made-up chats behind a stand-in Tauri invoke, shared by the checks (ui.mjs) and the README recording (demo.mjs).
export const stub = () => {
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
    if (cmd === 'people') return structuredClone({ people: people(), groups: groups.map(g => ({ ...g, ...(overrides.pictures?.[g.id] && { imgs: [overrides.pictures[g.id]], faces: [] }), name: overrides.names?.[g.id] || g.name, original: overrides.names?.[g.id] ? g.name : null, hidden: (overrides.hidden || []).includes(g.id) })) });
    if (cmd === 'overrides') return structuredClone(overrides);
    if (cmd === 'set_overrides') { overrides = args.value; return null; }
    if (cmd === 'open_url') return null;
    if (cmd === 'reel') return new Uint8Array(8).buffer;
    if (cmd === 'update_build') return window.__update || null;
    if (cmd === 'api') {
      if (args.path === '/v1/assets/upload/base64') return { uploadID: 'up1', duration: 1.5 };
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

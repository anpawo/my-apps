const invoke = (cmd, args) => window.__TAURI__.core.invoke(cmd, args);
const api = (method, path, body) => invoke('api', { method, path, body });
const $ = s => document.querySelector(s);
const enc = encodeURIComponent;
const EASE = 'cubic-bezier(.32, .72, 0, 1)';
const RM = matchMedia('(prefers-reduced-motion: reduce)');

// Logos: simple-icons 16.37 (CC0) paths; Teams is its macOS app icon; LinkedIn is not in simple-icons, so its "in".
const svg = (d, fill = '#fff') => `<svg viewBox="0 0 24 24"><path fill="${fill}" d="${d}"/></svg>`;
const NETS = {
  whatsapp: { label: 'WhatsApp', color: '#25D366', cmd: 'ws', logo: svg('M17.472 14.382c-.297-.149-1.758-.867-2.03-.967-.273-.099-.471-.148-.67.15-.197.297-.767.966-.94 1.164-.173.199-.347.223-.644.075-.297-.15-1.255-.463-2.39-1.475-.883-.788-1.48-1.761-1.653-2.059-.173-.297-.018-.458.13-.606.134-.133.298-.347.446-.52.149-.174.198-.298.298-.497.099-.198.05-.371-.025-.52-.075-.149-.669-1.612-.916-2.207-.242-.579-.487-.5-.669-.51-.173-.008-.371-.01-.57-.01-.198 0-.52.074-.792.372-.272.297-1.04 1.016-1.04 2.479 0 1.462 1.065 2.875 1.213 3.074.149.198 2.096 3.2 5.077 4.487.709.306 1.262.489 1.694.625.712.227 1.36.195 1.871.118.571-.085 1.758-.719 2.006-1.413.248-.694.248-1.289.173-1.413-.074-.124-.272-.198-.57-.347m-5.421 7.403h-.004a9.87 9.87 0 01-5.031-1.378l-.361-.214-3.741.982.998-3.648-.235-.374a9.86 9.86 0 01-1.51-5.26c.001-5.45 4.436-9.884 9.888-9.884 2.64 0 5.122 1.03 6.988 2.898a9.825 9.825 0 012.893 6.994c-.003 5.450-4.437 9.884-9.885 9.884m8.413-18.297A11.815 11.815 0 0012.05 0C5.495 0 .16 5.335.157 11.892c0 2.096.547 4.142 1.588 5.945L.057 24l6.305-1.654a11.882 11.882 0 005.683 1.448h.005c6.554 0 11.89-5.335 11.893-11.893a11.821 11.821 0 00-3.48-8.413Z') },
  instagram: { label: 'Instagram', color: 'radial-gradient(circle at 30% 107%, #fdf497 0%, #fdf497 5%, #fd5949 45%, #d6249f 60%, #285aeb 90%)', cmd: 'ig', logo: svg('M7.0301.084c-1.2768.0602-2.1487.264-2.911.5634-.7888.3075-1.4575.72-2.1228 1.3877-.6652.6677-1.075 1.3368-1.3802 2.127-.2954.7638-.4956 1.6365-.552 2.914-.0564 1.2775-.0689 1.6882-.0626 4.947.0062 3.2586.0206 3.6671.0825 4.9473.061 1.2765.264 2.1482.5635 2.9107.308.7889.72 1.4573 1.388 2.1228.6679.6655 1.3365 1.0743 2.1285 1.38.7632.295 1.6361.4961 2.9134.552 1.2773.056 1.6884.069 4.9462.0627 3.2578-.0062 3.668-.0207 4.9478-.0814 1.28-.0607 2.147-.2652 2.9098-.5633.7889-.3086 1.4578-.72 2.1228-1.3881.665-.6682 1.0745-1.3378 1.3795-2.1284.2957-.7632.4966-1.636.552-2.9124.056-1.2809.0692-1.6898.063-4.948-.0063-3.2583-.021-3.6668-.0817-4.9465-.0607-1.2797-.264-2.1487-.5633-2.9117-.3084-.7889-.72-1.4568-1.3876-2.1228C21.2982 1.33 20.628.9208 19.8378.6165 19.074.321 18.2017.1197 16.9244.0645 15.6471.0093 15.236-.005 11.977.0014 8.718.0076 8.31.0215 7.0301.0839m.1402 21.6932c-1.17-.0509-1.8053-.2453-2.2287-.408-.5606-.216-.96-.4771-1.3819-.895-.422-.4178-.6811-.8186-.9-1.378-.1644-.4234-.3624-1.058-.4171-2.228-.0595-1.2645-.072-1.6442-.079-4.848-.007-3.2037.0053-3.583.0607-4.848.05-1.169.2456-1.805.408-2.2282.216-.5613.4762-.96.895-1.3816.4188-.4217.8184-.6814 1.3783-.9003.423-.1651 1.0575-.3614 2.227-.4171 1.2655-.06 1.6447-.072 4.848-.079 3.2033-.007 3.5835.005 4.8495.0608 1.169.0508 1.8053.2445 2.228.408.5608.216.96.4754 1.3816.895.4217.4194.6816.8176.9005 1.3787.1653.4217.3617 1.056.4169 2.2263.0602 1.2655.0739 1.645.0796 4.848.0058 3.203-.0055 3.5834-.061 4.848-.051 1.17-.245 1.8055-.408 2.2294-.216.5604-.4763.96-.8954 1.3814-.419.4215-.8181.6811-1.3783.9-.4224.1649-1.0577.3617-2.2262.4174-1.2656.0595-1.6448.072-4.8493.079-3.2045.007-3.5825-.006-4.848-.0608M16.953 5.5864A1.44 1.44 0 1 0 18.39 4.144a1.44 1.44 0 0 0-1.437 1.4424M5.8385 12.012c.0067 3.4032 2.7706 6.1557 6.173 6.1493 3.4026-.0065 6.157-2.7701 6.1506-6.1733-.0065-3.4032-2.771-6.1565-6.174-6.1498-3.403.0067-6.156 2.771-6.1496 6.1738M8 12.0077a4 4 0 1 1 4.008 3.9921A3.9996 3.9996 0 0 1 8 12.0077') },
  discord: { label: 'Discord', color: '#5865F2', cmd: 'dc', logo: svg('M20.317 4.3698a19.7913 19.7913 0 00-4.8851-1.5152.0741.0741 0 00-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 00-.0785-.037 19.7363 19.7363 0 00-4.8852 1.515.0699.0699 0 00-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 00.0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 00.0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 00-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 01-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 01.0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 01.0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 01-.0066.1276 12.2986 12.2986 0 01-1.873.8914.0766.0766 0 00-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 00.0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 00.0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 00-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z') },
  teams: { label: 'Teams', color: 'transparent', cmd: 'te', logo: '<img src="nets/teams.png" alt="">' },
  linkedin: { label: 'LinkedIn', color: '#0A66C2', cmd: 'li', logo: '<b>in</b>' },
  sms: { label: 'SMS', color: '#fff', cmd: 'sm', logo: svg('M12 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0zM4.911 7.089h11.456a2.197 2.197 0 0 1 2.165 2.19v5.863a2.213 2.213 0 0 1-2.177 2.178H8.04c-1.174 0-2.04-.99-2.04-2.178v-4.639L4.503 7.905c-.31-.42-.05-.816.408-.816zm3.415 2.19c-.347 0-.68.21-.68.544 0 .334.333.544.68.544h7.905c.346 0 .68-.21.68-.544 0-.334-.334-.545-.68-.545zm0 2.177c-.347 0-.68.21-.68.544 0 .334.333.544.68.544h7.905c.346 0 .68-.21.68-.544 0-.334-.334-.544-.68-.544zm-.013 2.19c-.346 0-.68.21-.68.544 0 .334.334.544.68.544h5.728c.347 0 .68-.21.68-.544 0-.334-.333-.545-.68-.545z', '#1A73E8') },
  matrix: { label: 'Matrix', color: 'transparent', cmd: 'mx', logo: '<img src="nets/element.png" alt="">' },
  other: { label: 'Other', color: '#8a8a92', cmd: null, logo: '<b>?</b>' },
};
function netOf(chat) {
  const s = `${chat.network} ${chat.accountID}`.toLowerCase();
  if (s.includes('whatsapp')) return 'whatsapp';
  if (s.includes('instagram')) return 'instagram';
  if (s.includes('discord')) return 'discord';
  if (s.includes('teams')) return 'teams';
  if (s.includes('linkedin')) return 'linkedin';
  if (s.includes('google messages') || s.includes('gmessages') || s.includes('sms')) return 'sms';
  if (s.includes('matrix') || s.includes('hungryserv')) return 'matrix';
  return 'other';
}

// Reduce Motion keeps every change visible as a short fade, never a jump.
function anim(el, frames, ms, easing = EASE) {
  if (RM.matches) {
    frames = frames.opacity ? { opacity: frames.opacity } : { opacity: [0.4, 1] };
    ms = Math.min(ms, 120);
  }
  return el.animate(frames, { duration: ms, easing });
}

// Height and opacity together, the content clipped by its own box, so what follows moves with it.
function collapse(el, hide, ms = 240) {
  if (el.hidden === hide && !el._anim) return Promise.resolve();
  el._anim?.cancel();
  el.hidden = false;
  const h = el.scrollHeight, cs = getComputedStyle(el);
  const open = { height: h + 'px', opacity: 1, paddingTop: cs.paddingTop, paddingBottom: cs.paddingBottom, marginTop: cs.marginTop, marginBottom: cs.marginBottom };
  const shut = { height: '0px', opacity: 0, paddingTop: '0px', paddingBottom: '0px', marginTop: '0px', marginBottom: '0px' };
  el.style.overflow = 'hidden';
  const a = (el._anim = anim(el, Object.fromEntries(Object.keys(open).map(k => [k, hide ? [open[k], shut[k]] : [shut[k], open[k]]])), ms));
  return a.finished
    .then(() => { el._anim = null; el.style.overflow = ''; el.hidden = hide; })
    .catch(() => {});
}

// Lowercase, accents off, Greek and Cyrillic lookalikes as Latin: "faustine" finds "ƒαustine".
const LOOK = { ƒ: 'f', α: 'a', β: 'b', ε: 'e', η: 'n', ι: 'i', κ: 'k', ν: 'v', ο: 'o', ρ: 'p', τ: 't', υ: 'u', χ: 'x', ω: 'w', а: 'a', е: 'e', о: 'o', р: 'p', с: 'c', х: 'x', ı: 'i', ł: 'l' };
const fold = s => String(s || '').normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase().replace(/./g, c => LOOK[c] || c);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => `&#${c.charCodeAt(0)};`);
const linkify = s => esc(s).replace(/https?:\/\/[^\s<]+/g, u => `<a href="${u}" target="_blank" rel="noreferrer">${u}</a>`);
const asset = url => /^(data|blob):/.test(url) ? url : `beeper://localhost/asset?url=${enc(url)}`;
const netMark = key => { const n = NETS[key]; return `<span class="net" style="background:${n.color}" title="${n.label}">${n.logo}</span>`; };
function hue(s) { let h = 0; for (const c of s) h = (h * 31 + c.charCodeAt(0)) % 360; return h; }
// Each picture in turn (Instagram's default comes back 404), the initials only once none loads.
function avatar(item, all) {
  const initials = (item.name || '?').split(/\s+/).filter(Boolean).slice(0, 2).map(w => [...w][0]).join('').toUpperCase();
  const color = `hsl(${hue(item.name || '')} 55% 62%)`;
  // A group chat: the logo of the app it comes from, then up to 4 of its members' pictures in one round tile, like a
  // folded group of favorites (its own picture when no member has one).
  if (item.kind === 'group' && !item._plain) {
    const faces = item.faces || [];
    const logo = netMark(netOf(item.chats[0]));
    if (!faces.length) return `<div class="av faces members">${logo}${avatar({ ...item, _plain: true })}</div>`;
    const img = f => `<img src="${esc(asset(f))}" onerror="this.onerror=null;this.src='data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22/%3E'">`;
    // A pinned group: every member, overlapping more as there are more, so all fit in the same width.
    if (all) return `<div class="av faces members">${logo}<div class="stack" style="--n:${faces.length}">${faces.map(img).join('')}</div></div>`;
    return `<div class="av faces members">${logo}<div class="av tile">${faces.slice(0, 4).map(img).join('')}</div></div>`;
  }
  const [first, ...rest] = item.imgs || [];
  if (!first) return `<div class="av" style="background:${color}">${esc(initials)}</div>`;
  return `<div class="av" data-initials="${esc(initials)}" data-color="${color}"><img src="${esc(asset(first))}" data-next="${esc(JSON.stringify(rest))}" onerror="nextPicture(this)"></div>`;
}
function nextPicture(img) {
  const [url, ...rest] = JSON.parse(img.dataset.next);
  if (url) { img.dataset.next = JSON.stringify(rest); img.src = asset(url); return; }
  const av = img.parentNode;
  av.style.background = av.dataset.color;
  av.textContent = av.dataset.initials;
}
function when(iso, long) {
  if (!iso) return '';
  const d = new Date(iso), now = new Date();
  if (d.toDateString() === now.toDateString()) return d.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });
  if (now - d < 6 * 864e5) return d.toLocaleDateString('fr-FR', { weekday: long ? 'long' : 'short' });
  return d.toLocaleDateString('fr-FR', long ? { day: 'numeric', month: 'long', year: 'numeric' } : { day: '2-digit', month: '2-digit' });
}
const netsOf = item => [...new Set(item.chats.map(netOf))];

const state = { byId: new Map(), cur: null, seq: 0, msgs: [], older: {}, pool: [], target: null, favs: new Set(JSON.parse(localStorage.favs || '[]')) };

/* ---------- Sidebar ---------- */

const MUTED = '<svg class="muted" viewBox="0 0 16 16" aria-label="Muted"><path d="M4 6.5a4 4 0 0 1 6.9-2.7M12 7v2.5l1.5 2H5M6.5 13.5a1.5 1.5 0 0 0 3 0M2.5 2.5l11 11"/></svg>';
function fill(n, item, all) {
  // A person: the logo of the app with their latest message only.
  const nets = item.kind === 'person' ? [netOf(item.chats.reduce((a, c) => (c.last > a.last ? c : a)))] : [];
  const muted = item.chats.length && item.chats.every(c => c.muted);
  const sig = JSON.stringify([item.name, item.original, item.imgs, item.faces, item.unread, item.last, nets, all, muted]);
  if (n._sig === sig) return;
  const wasUnread = n._unread || 0;
  n._sig = sig;
  n._unread = item.unread;
  n.classList.toggle('unread', item.unread > 0);
  const pic = nets.length ? `<div class="av faces members">${nets.map(netMark).join('')}${avatar(item)}</div>` : avatar(item, all);
  n.innerHTML = `${pic}<div class="body"><div class="top"><span class="name">${esc(item.name || 'Unnamed')}${muted ? MUTED : ''}${item.original ? `<span class="orig">${esc(item.original)}</span>` : ''}</span><span class="time">${when(item.last)}</span></div>
    <div class="bottom">${item.unread ? `<span class="badge">${item.unread}</span>` : ''}</div></div>`;
  if (item.unread && !wasUnread && n.isConnected) anim(n.querySelector('.badge'), { scale: [0.4, 1], opacity: [0, 1] }, 200);
}

// FLIP: rows keep their place on screen, then glide to where the new order puts them.
function renderList(box, items) {
  const before = new Map([...box.children].map(n => [n.dataset.id, n.getBoundingClientRect().top]));
  const keep = new Set(items.map(i => i.id));
  for (const n of [...box.children]) {
    if (!keep.has(n.dataset.id) && !n.dataset.leaving) {
      n.dataset.leaving = '1';
      collapse(n, true, 220).then(() => n.remove());
    }
  }
  let prev = null;
  for (const item of items) {
    let n = box.querySelector(`:scope > [data-id="${CSS.escape(item.id)}"]`);
    const fresh = !n;
    if (fresh) {
      n = document.createElement('div');
      n.className = 'row';
      n.dataset.id = item.id;
      // On the open conversation, its picture (a group's bubble of faces) opens the profile: who someone is, who is in the group.
      n.onclick = e => {
        if (n._dragged) return;
        if (e.target.closest('.av') && state.cur?.id === n.dataset.id) return profile.box.hidden || profile.closing ? openProfile(state.cur) : closeProfile();
        select(n.dataset.id);
      };
      if (box.id === 'people') dragFrom(n);
      n.oncontextmenu = e => { e.preventDefault(); select(n.dataset.id); openMore(n); };
    }
    fill(n, item, box.id === 'pinned');
    let at = prev ? prev.nextSibling : box.firstChild;
    while (at && at.dataset.leaving) at = at.nextSibling;
    if (n !== at) box.insertBefore(n, at);
    if (fresh && before.size) anim(n, { opacity: [0, 1] }, 220);
    prev = n;
  }
  for (const n of box.children) {
    const top = before.get(n.dataset.id);
    if (top == null || n.dataset.leaving) continue;
    const dy = top - n.getBoundingClientRect().top;
    if (Math.abs(dy) > 1) anim(n, { transform: [`translateY(${dy}px)`, 'none'] }, 300);
  }
}

// The selection pill (tab-pill template, vertical): its front edge leads, so for a moment it covers both rows.
function movePill(ms) {
  const pill = $('.sel'), inner = $('.inner');
  const n = state.cur && document.querySelector(`#list .row[data-id="${CSS.escape(state.cur.id)}"]`);
  document.querySelectorAll('#list .row.on').forEach(r => r !== n && r.classList.remove('on'));
  const visible = n && !n.hidden && !n.dataset.leaving;
  if (!visible) { pill.style.opacity = 0; return; }
  n.classList.add('on');
  const top = n.offsetTop, bottom = inner.offsetHeight - top - n.offsetHeight;
  const was = pill.style.opacity === '1';
  const down = top > parseFloat(pill.style.top || 0);
  const [front, back] = RM.matches ? [0, 0] : ms ? [ms, ms] : [170, 250];
  pill.style.transition = was ? `top ${down ? back : front}ms ${EASE}, bottom ${down ? front : back}ms ${EASE}, opacity 150ms` : 'opacity 150ms';
  Object.assign(pill.style, { top: top + 'px', bottom: bottom + 'px', opacity: 1 });
}

// Drawing every person (hundreds of rows and pictures) made the app slow: the list holds the newest that fit
// on screen (10 at most), those with unread messages and the open one; scrolling past the end doubles it.
// A search looks through everyone but draws the 30 newest matches.
function fits() {
  const list = $('#list'), row = $('#people .row:not([data-leaving])')?.offsetHeight || 56;
  const room = list.clientHeight - $('#pinned').offsetHeight - parseFloat(getComputedStyle(list).paddingBottom);
  return Math.max(3, Math.min(10, Math.floor(room / row)));
}
function shown(items) {
  items = items.filter(i => !isFav(i) && (!i.hidden || i.id === state.cur?.id));
  const max = state.more || fits();
  return items.filter((i, n) => n < max || i.unread > 0 || i.id === state.cur?.id);
}
// A wheel turn at the bottom of the list, even one too short to scroll, shows twice as many people.
$('#list').addEventListener('wheel', e => {
  const list = $('#list');
  if (e.deltaY <= 0 || list.scrollHeight - list.scrollTop - list.clientHeight > 40) return;
  const have = $('#people').querySelectorAll('.row:not([data-leaving])').length;
  if (have >= (state.all || []).filter(i => !isFav(i) && !i.hidden).length) return;
  state.more = have * 2;
  showLists();
}, { passive: true });
// A favorite is kept by its chats' ids, so it stays one after a merge or a split changes the person's id.
const isFav = item => item.chats.some(c => state.favs.has(c.id));
function toggleFav(item) {
  const on = !isFav(item);
  for (const c of item.chats) on ? state.favs.add(c.id) : state.favs.delete(c.id);
  if (!on) { for (const t of state.tabs) t.ids = t.ids.filter(id => !item.chats.some(c => c.id === id)); saveTabs(); }
  localStorage.favs = JSON.stringify([...state.favs]);
  showLists();
}
// Favorites keep the order he gives them (⌘ + arrows), new ones last.
const favRank = item => Math.min(...item.chats.map(c => [...state.favs].indexOf(c.id)).filter(n => n >= 0));
function moveFav(item, key) {
  const favs = (state.all || []).filter(isFav).sort((a, b) => favRank(a) - favRank(b));
  const tab = state.tabs.find(t => inTab(item, t)), strip = tab ? favs.filter(i => inTab(i, tab)) : favs.filter(i => !grouped(i));
  const same = strip.filter(i => (i.kind === 'group') === (item.kind === 'group'));
  const step = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: item.kind === 'group' ? -1 : -5, ArrowDown: item.kind === 'group' ? 1 : 5 }[key];
  const from = same.indexOf(item), to = Math.max(0, Math.min(same.length - 1, from + step));
  if (from < 0 || to === from) return;
  same.splice(to, 0, ...same.splice(from, 1));
  const order = [...same, ...favs.filter(i => !same.includes(i))].flatMap(i => i.chats.map(c => c.id)).filter(id => state.favs.has(id));
  state.favs = new Set([...order, ...state.favs]);
  localStorage.favs = JSON.stringify([...state.favs]);
  showLists();
}
const grouped = item => state.tabs.some(t => inTab(item, t));
// Favorites in no group on top, then each group of favorites; pinned group chats keep their row below.
function showLists() {
  const all = state.all || [];
  const favs = all.filter(isFav).sort((a, b) => favRank(a) - favRank(b));
  drawFavs($('#favs'), favs.filter(i => i.kind !== 'group' && !grouped(i)));
  drawGroups(favs);
  const groups = favs.filter(i => i.kind === 'group');
  renderList($('#pinned'), groups);
  $('#pinned').classList.toggle('some', groups.length > 0);
  renderList($('#people'), shown(all));
  movePill();
}
// Favorites: their pictures in a strip above the list, in his order; a dot when unread.
function drawFavs(box, items, tab) {
  const was = new Map([...box.children].map(b => [b.dataset.id, b.getBoundingClientRect()]));
  const had = new Set(was.keys());
  // An emptied strip folds away with what it showed; one that comes back unfolds (not on the first draw).
  if (!items.length && !tab) {
    if (!box.hidden && !box._closing) { box._closing = true; collapse(box, true).then(() => (box._closing = false)); }
    return;
  }
  const opening = box._drawn && (box.hidden || box._closing);
  box._closing = false;
  box._drawn = true;
  box.hidden = false;
  const [shown, folded] = foldGroup(items, tab), h0 = box.offsetHeight;
  box.innerHTML = tab && !items.length ? `<div class="favs-empty">Drag someone here</div>` : shown.map(i => `<button class="fav${i.id === state.cur?.id ? ' on' : ''}${i.unread ? ' unread' : ''}" data-id="${esc(i.id)}" title="${esc(i.name || 'Unnamed')}">${avatar(i)}</button>`).join('')
    + (folded.length ? `<button class="folder${folded.some(i => i.unread) ? ' unread' : ''}" title="${folded.length} more: ${esc(folded.map(i => i.name).join(', '))}">${folded.slice(0, 4).map(avatar).join('')}</button>`
      : tab && state.unfolded.has(tab.name) && items.length > 5 ? '<button class="folder less" title="Fold">–</button>' : '');
  const folder = box.querySelector('.folder');
  if (folder) folder.onclick = () => { state.unfolded[folded.length ? 'add' : 'delete'](tab.name); showLists(); };
  if (!opening && h0 && box.offsetHeight !== h0) {
    box.style.overflow = 'hidden';
    anim(box, { height: [h0 + 'px', box.offsetHeight + 'px'] }, 260).finished.then(() => (box.style.overflow = ''), () => {});
  }
  box.querySelectorAll('.fav').forEach(b => {
    b.onclick = () => b._dragged || select(b.dataset.id);
    dragFrom(b);
    b.oncontextmenu = e => { e.preventDefault(); select(b.dataset.id); openMore(b); };
    if (had.size && !had.has(b.dataset.id)) anim(b, { scale: [0.5, 1], opacity: [0, 1] }, 260);
    const old = was.get(b.dataset.id), now = b.getBoundingClientRect();
    if (old && (old.left !== now.left || old.top !== now.top)) anim(b, { translate: [`${old.left - now.left}px ${old.top - now.top}px`, '0 0'] }, 260);
  });
  if (opening) collapse(box, false);
}

// A group of more than 5 shows 4 and folds the rest into one tile of small pictures; the open person and
// those with unread messages stay out of it, unless 5 or more have some.
state.unfolded = new Set();
function foldGroup(items, tab) {
  if (!tab || items.length <= 5 || state.unfolded.has(tab.name)) return [items, []];
  const unread = items.filter(i => i.unread).length;
  const out = new Set(items.filter(i => (unread < 5 && i.unread) || i.id === state.cur?.id).slice(0, 4));
  for (const i of items) if (out.size < 4) out.add(i);
  return [items.filter(i => out.has(i)), items.filter(i => !out.has(i))];
}

// Groups: named sets of favorites, each always open under the favorites in no group.
state.tabs = JSON.parse(localStorage.tabs || '[]');
// Groups made before "one group at most" could share people: each stays in the first one.
{ const seen = new Set(); for (const t of state.tabs) { t.ids = t.ids.filter(id => !seen.has(id)); t.ids.forEach(id => seen.add(id)); } }
const saveTabs = () => { localStorage.tabs = JSON.stringify(state.tabs); };
const tabOf = name => state.tabs.find(t => t.name === name);
const inTab = (item, tab) => item.chats.some(c => tab.ids.includes(c.id));
function drawGroups(favs) {
  const box = $('#tabbox');
  if (box.querySelector('input')) return;
  box.hidden = !state.tabs.length && !favs.length;
  const keep = new Set(state.tabs.map(t => t.name));
  for (const sec of [...box.querySelectorAll('.group')]) if (!keep.has(sec.dataset.name)) collapse(sec, true).then(() => sec.remove());
  let prev = null;
  for (const tab of state.tabs) {
    let sec = [...box.querySelectorAll('.group')].find(g => g.dataset.name === tab.name);
    if (!sec) {
      sec = Object.assign(document.createElement('section'), { className: 'group' });
      sec.dataset.name = tab.name;
      sec.innerHTML = '<div class="strip" hidden></div>';
      if (box.querySelector('.group')) requestAnimationFrame(() => collapse(sec, false));
    }
    if (!sec.querySelector('.label')) sec.prepend(Object.assign(document.createElement('button'), { className: 'label' }));
    const label = sec.querySelector('.label');
    label.textContent = tab.name;
    label.oncontextmenu = e => {
      e.preventDefault();
      menu(label, m => m.append(
        item('Rename…', { action: () => { closeMenu(); nameTab(label, tab.name, name => { sec.dataset.name = name; tab.name = name; }); } }),
        item(`Delete ${tab.name}`, { hint: 'favorites stay', action: () => { closeMenu(); state.tabs = state.tabs.filter(t => t !== tab); saveTabs(); showLists(); } })));
    };
    const at = prev ? prev.nextSibling : box.firstChild;
    if (sec !== at) box.insertBefore(sec, at);
    drawFavs(sec.querySelector('.strip'), favs.filter(i => i.kind !== 'group' && inTab(i, tab)), tab);
    prev = sec;
  }
  let add = box.querySelector('.newgroup');
  if (!add) { add = Object.assign(document.createElement('button'), { className: 'newgroup', textContent: '+ New group' }); add.onclick = () => newTab(add); }
  box.append(add);
}
// A name typed in place of the label; Enter keeps it, esc drops it.
function nameTab(button, value, done) {
  const field = Object.assign(document.createElement('input'), { value, placeholder: 'Group name', spellcheck: false });
  button.replaceWith(field);
  field.focus();
  field.select();
  let over = false;
  const end = keep => {
    if (over) return;
    over = true;
    const name = field.value.trim();
    field.replaceWith(button);
    if (keep && name && (name === value || !tabOf(name))) { done(name); saveTabs(); }
    showLists();
  };
  field.onkeydown = e => { e.stopPropagation(); if (e.key === 'Enter') end(true); if (e.key === 'Escape') end(false); };
  field.onblur = () => end(true);
}
function newTab(button, person) {
  nameTab(button, '', name => {
    state.tabs.push({ name, ids: [] });
    if (person) addToTab(person, name);
  });
}
// One group at most: joining one leaves the other.
function addToTab(item, name, on = true) {
  if (on && !isFav(item)) toggleFav(item);
  for (const t of state.tabs) t.ids = t.ids.filter(id => !item.chats.some(c => c.id === id));
  if (on) tabOf(name).ids.push(...item.chats.map(c => c.id));
  saveTabs();
  showLists();
}
// Drag a favorite or a person of the list onto a group to move them there, or onto the top strip to take them out of their group.
function dragFrom(el) {
  el.addEventListener('pointerdown', e => {
    if (e.button !== 0) return;
    const item = state.byId.get(el.dataset.id);
    if (!item || item.kind !== 'person') return;
    const x0 = e.clientX, y0 = e.clientY;
    let ghost = null, over = null;
    const move = ev => {
      if (!ghost) {
        if (Math.hypot(ev.clientX - x0, ev.clientY - y0) < 6) return;
        ghost = el.querySelector('.av').cloneNode(true);
        ghost.classList.add('ghost');
        document.body.append(ghost);
        el.classList.add('dragging');
        const top = $('#favs');
        if (top.hidden) { top.hidden = false; top.innerHTML = '<div class="favs-empty">Drop here to take them out of their group</div>'; collapse(top, false); }
        anim(ghost, { scale: [0.8, 1] }, 160);
      }
      ghost.style.left = ev.clientX - 24 + 'px';
      ghost.style.top = ev.clientY - 24 + 'px';
      const t = document.elementFromPoint(ev.clientX, ev.clientY)?.closest('.group, #favs, #tabbox .newgroup') || null;
      if (t !== over) { over?.classList.remove('drop'); over = t; over?.classList.add('drop'); }
    };
    const up = () => {
      removeEventListener('pointermove', move);
      removeEventListener('pointerup', up);
      if (!ghost) return;
      ghost.remove();
      el.classList.remove('dragging');
      over?.classList.remove('drop');
      el._dragged = true;
      setTimeout(() => (el._dragged = false));
      if (!over) return showLists();
      if (over.id === 'favs') { if (!isFav(item)) toggleFav(item); addToTab(item, '', false); }
      else if (over.classList.contains('newgroup')) newTab(over, item);
      else addToTab(item, over.dataset.name);
    };
    addEventListener('pointermove', move);
    addEventListener('pointerup', up);
  });
}

// ⌘D: a search palette in the middle of the window, over everyone; ↑ ↓ pick, ↵ opens, esc closes.
const palette = $('#palette'), search = $('#search');
function openPalette() {
  if (!palette.hidden && !palette.closing) return search.select();
  // ⌘D right after esc: the closing fade is cut short instead of hiding the reopened palette.
  palette.closing = false;
  palette.hidden = false;
  search.value = '';
  drawResults();
  search.focus();
  anim(palette.firstElementChild, { opacity: [0, 1], scale: [0.96, 1] }, 220);
  anim(palette, { opacity: [0, 1] }, 220);
}
function closePalette() {
  if (palette.hidden || palette.closing) return;
  palette.closing = true;
  const done = () => { if (palette.closing) { palette.hidden = true; palette.closing = false; } };
  anim(palette.firstElementChild, { opacity: [1, 0], scale: [1, 0.96] }, 160);
  anim(palette, { opacity: [1, 0] }, 160).finished.then(done, done);
}
// "/whatsapp lea", "/wh lea" or "/ws lea": only those on that app.
function drawResults() {
  let q = search.value.trim().toLowerCase(), net = null;
  const m = q.match(/^\/([a-z]+)\s*/);
  if (m) {
    net = Object.keys(NETS).find(k => NETS[k].cmd && (NETS[k].cmd === m[1] || k.startsWith(m[1])));
    if (net) q = q.slice(m[0].length);
  }
  const all = net ? (state.all || []).filter(i => netsOf(i).includes(net)) : state.all || [];
  q = fold(q);
  const items = (q ? all.filter(i => fold(i.name).includes(q) || fold(i.original).includes(q)) : all).slice(0, q || net ? 30 : 8);
  renderList($('#results'), items);
  $('#results').querySelectorAll('.row:not([data-leaving])').forEach((r, i) => { r.classList.toggle('hot', i === 0); r.classList.toggle('faved', isFav(items.find(i => i.id === r.dataset.id))); r.onclick = () => { closePalette(); select(r.dataset.id); }; });
}
search.addEventListener('input', drawResults);
search.addEventListener('keydown', e => {
  const rows = [...$('#results').querySelectorAll('.row:not([data-leaving])')];
  const at = rows.findIndex(r => r.classList.contains('hot'));
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    const to = rows[Math.max(0, Math.min(rows.length - 1, at + (e.key === 'ArrowDown' ? 1 : -1)))];
    rows.forEach(r => r.classList.toggle('hot', r === to));
    to?.scrollIntoView({ block: 'nearest' });
  } else if (e.key === 'Enter' && rows[at]) { e.preventDefault(); closePalette(); select(rows[at].dataset.id); }
  else if (e.key === 'Escape') closePalette();
  else if (e.metaKey && e.key.toLowerCase() === 'm' && rows[at]) {
    e.preventDefault(); e.stopPropagation();
    const id = rows[at].dataset.id;
    closePalette();
    select(id).then(rename);
  }
  else if (e.metaKey && e.key.toLowerCase() === 'f' && rows[at]) {
    e.preventDefault(); e.stopPropagation();
    toggleFav(state.byId.get(rows[at].dataset.id));
    rows[at].classList.toggle('faved', isFav(state.byId.get(rows[at].dataset.id)));
  }
});
palette.addEventListener('pointerdown', e => { if (e.target === palette) closePalette(); });

let loading = false;
async function refreshList() {
  if (loading) return;
  loading = true;
  try {
    const { people, groups } = await invoke('people');
    people.forEach(p => (p.kind = 'person'));
    groups.forEach(g => (g.kind = 'group'));
    [...people, ...groups].forEach(applySeen);
    state.byId = new Map([...people, ...groups].map(i => [i.id, i]));
    $('#banner').hidden = true;
    // Groups sit among the people, by their latest message.
    state.all = [...people, ...groups].sort((a, b) => (b.last || '').localeCompare(a.last || ''));
    showLists();
    // overrides.json's openAtLaunch (a chat id): the conversation open at launch, on the first list that loads.
    const launch = state.openAtLaunch && [...state.byId.values()].find(i => i.chats.some(c => c.id === state.openAtLaunch));
    state.openAtLaunch = null;
    if (launch && !state.cur) select(launch.id);
    if (state.cur) {
      // A merge or a split gives the person a new id: follow the chat we had open.
      const first = state.cur.chats[0].id;
      const now = state.byId.get(state.cur.id) || [...state.byId.values()].find(i => i.chats.some(c => c.id === first));
      if (now) { const changed = now.id !== state.cur.id || now.chats.length !== state.cur.chats.length; state.cur = now; if (changed) drawHeader(); }
    }
    // The open profile follows a merge or a split the same way, showing the apps it now has.
    const shown = !profile.box.hidden && !profile.closing && profile.view?.chats && profile.view;
    if (shown) {
      const now = [...state.byId.values()].find(i => i.chats.some(c => c.id === shown.chats[0].id));
      if (now && (now.id !== shown.id || now.chats.length !== shown.chats.length)) showProfile(now);
    }
    requestAnimationFrame(() => movePill(300));
    seedReactions();
  } catch (e) {
    $('#banner').textContent = String(e).startsWith('Beeper Server') ? e : `Beeper Server isn't answering (${e}). Retrying…`;
    $('#banner').hidden = false;
  } finally {
    loading = false;
  }
}

addEventListener('click', e => {
  const a = e.target.closest('a[href^="http"]');
  if (a) { e.preventDefault(); invoke('open_url', { url: a.href }); }
});
addEventListener('keydown', e => {
  if (e.metaKey && e.key.toLowerCase() === 'd') { e.preventDefault(); openPalette(); }
  // ⌘F over a person or a favorite adds or removes the favorite.
  const over = e.metaKey && e.key.toLowerCase() === 'f' && document.querySelector('#list .row:hover, .fav:hover');
  if (over) { e.preventDefault(); toggleFav(state.byId.get(over.dataset.id)); }
  // ⌘F anywhere else finds a word in the open conversation.
  else if (e.metaKey && e.key.toLowerCase() === 'f' && state.cur && palette.hidden) { e.preventDefault(); openFind(); }
  // ⌘K: seen, nothing to say. Clears the badge of the person or group under the pointer, or of the open one.
  if (e.metaKey && e.key.toLowerCase() === 'k') {
    e.preventDefault();
    const item = state.byId.get(document.querySelector('#list .row:hover, .fav:hover')?.dataset.id) || state.cur;
    if (item?.unread) markRead(item);
  }
  // ⌘R replies to the message under the pointer, or to the last one they sent.
  if (e.metaKey && e.key.toLowerCase() === 'r' && state.cur) {
    e.preventDefault();
    const id = document.querySelector('#thread .msg:hover')?.dataset.id;
    setReply(state.msgs.find(m => m.id === id) || state.msgs.findLast(m => !m.isSender));
  }
  // ⌘M gives an alias to the person or group under the pointer, or the open one.
  if (e.metaKey && e.key.toLowerCase() === 'm') {
    e.preventDefault();
    const id = document.querySelector('#list .row:hover, .fav:hover')?.dataset.id;
    if (id && id !== state.cur?.id) select(id).then(rename); else rename();
  }
  // ⌘ + arrows move the favorite under the pointer, or the open one when no text is being edited.
  if (e.metaKey && e.key.startsWith('Arrow')) {
    const hover = document.querySelector('.fav:hover, #pinned .row:hover');
    const typing = /^(INPUT|TEXTAREA)$/.test(document.activeElement?.tagName) && document.activeElement.value;
    const item = hover ? state.byId.get(hover.dataset.id) : !typing && state.cur && isFav(state.cur) ? state.cur : null;
    if (item) { e.preventDefault(); moveFav(item, e.key); }
  }
});
/* ---------- Voice messages ---------- */

// Fetched whole into a blob: WebKit streams media from a custom scheme only with range requests, which beeper:// lacks.
// Each is loaded as it scrolls into view, so its length shows before it is played. Beeper does not say which ones I
// have heard: a voice message played to 90 % is kept here as heard, and until then it carries a blue dot.
const clock = t => (isFinite(t) ? `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, '0')}` : '');
const heard = new Set(JSON.parse(localStorage.heard || '[]'));
function voiceLoad(v) {
  return (v._load ||= (async () => {
    v.classList.add('loading');
    const blob = await fetch(v.dataset.src).then(r => (r.ok ? r.blob() : null)).catch(() => null);
    v.classList.remove('loading');
    if (!blob) { v.classList.add('failed'); v.title = 'Could not load this voice message'; return null; }
    const au = (v._audio = new Audio(URL.createObjectURL(new Blob([blob], { type: v.dataset.type || blob.type }))));
    au.preload = 'metadata';
    const show = () => {
      v.querySelector('.track i').style.width = `${(au.currentTime / au.duration) * 100 || 0}%`;
      v.querySelector('.time').textContent = clock(au.currentTime && !au.ended ? au.currentTime : au.duration);
      if (au.currentTime >= au.duration * 0.9 && !heard.has(v.dataset.id)) {
        heard.add(v.dataset.id);
        localStorage.heard = JSON.stringify([...heard].slice(-3000));
        v.classList.add('heard');
      }
    };
    au.ontimeupdate = au.onloadedmetadata = au.ondurationchange = show;
    au.onplay = () => { v.classList.add('playing'); v.querySelector('.toggle').innerHTML = PAUSE; };
    au.onpause = au.onended = () => { v.classList.remove('playing'); v.querySelector('.toggle').innerHTML = PLAY; show(); };
    return au;
  })());
}
const voiceIO = new IntersectionObserver(es => es.forEach(e => e.isIntersecting && (voiceIO.unobserve(e.target), voiceLoad(e.target))), { rootMargin: '400px' });
$('#thread').addEventListener('click', async e => {
  const v = e.target.closest('.bubble.voice');
  if (!v) return;
  const au = await voiceLoad(v);
  if (!au) return;
  if (e.target.closest('.track')) {
    const r = v.querySelector('.track').getBoundingClientRect();
    au.currentTime = ((e.clientX - r.left) / r.width) * au.duration;
    return;
  }
  document.querySelectorAll('.bubble.voice.playing').forEach(o => o !== v && o._audio.pause());
  if (au.paused) au.play().catch(() => v.classList.add('failed')); else au.pause();
});

/* ---------- Find in the conversation (⌘F) ---------- */

// Matches are painted with the CSS Custom Highlight API, so the bubbles' DOM is left alone. Lowercase and accents off,
// one character for one, so a match's offsets are the text node's.
const find = { box: $('#find'), input: $('#find input'), hits: [], at: -1 };
const norm = s => [...s].map(c => (c.length > 1 ? c : c.normalize('NFD')[0].toLowerCase()[0])).join('');
function findRun() {
  const q = norm(find.input.value.trim());
  find.hits = [];
  if (q) {
    const walk = document.createTreeWalker($('#thread'), NodeFilter.SHOW_TEXT, { acceptNode: n => (n.parentElement.closest('.bubble') ? 1 : 2) });
    for (let n; (n = walk.nextNode()); ) {
      const t = norm(n.data);
      for (let i = t.indexOf(q); i >= 0; i = t.indexOf(q, i + q.length)) {
        const r = new Range();
        r.setStart(n, i);
        r.setEnd(n, i + q.length);
        find.hits.push(r);
      }
    }
  }
  find.at = find.hits.length - 1;
  findShow();
}
function findShow() {
  CSS.highlights.set('find', new Highlight(...find.hits));
  CSS.highlights.set('find-cur', new Highlight(...(find.hits[find.at] ? [find.hits[find.at]] : [])));
  const n = find.hits.length;
  find.box.querySelector('.count').textContent = !find.input.value.trim() ? '' : n ? `${n - find.at} of ${n}` : 'No match';
  find.hits[find.at]?.startContainer.parentElement.closest('.msg').scrollIntoView({ block: 'center', behavior: RM.matches ? 'auto' : 'smooth' });
}
// Enter goes back in time; past the oldest loaded match, older messages are loaded to look further.
async function findStep(dir) {
  const n = find.hits.length;
  if (!n) return;
  if (dir < 0 && find.at === 0) {
    let more;
    do { more = await loadOlder(); findRun(); } while (more && find.hits.length === n);
    find.at = find.hits.length > n ? find.hits.length - n - 1 : n - 1;
    return findShow();
  }
  find.at = (find.at + dir + n) % n;
  findShow();
}
function openFind() {
  collapse(find.box, false, 200);
  find.input.focus();
  find.input.select();
  findRun();
}
function closeFind() {
  collapse(find.box, true, 200);
  find.input.value = '';
  findRun();
  input.focus();
}
find.input.addEventListener('input', findRun);
find.input.addEventListener('keydown', e => {
  if (e.key === 'Enter') { e.preventDefault(); findStep(e.shiftKey ? 1 : -1); }
  if (e.key === 'Escape') { e.preventDefault(); closeFind(); }
});

/* ---------- Conversation ---------- */

async function select(id) {
  const item = state.byId.get(id);
  if (!item || item === state.cur) return;
  state.cur = item;
  state.target = null;
  setReply(null);
  if (!find.box.hidden) closeFind();
  closeProfile();
  // The list keeps the open one even when hidden or old: redraw it so the one left goes back to its rule.
  showLists();
  document.querySelectorAll('.fav').forEach(f => f.classList.toggle('on', f.dataset.id === id));
  drawHeader();
  $('#empty').style.opacity = 0;
  $('footer').hidden = false;
  const seq = ++state.seq;
  const thread = $('#thread');
  // exit-fade template: the old conversation fades where it stands while the new one loads.
  const fade = thread.childElementCount ? anim(thread, { opacity: [1, 0] }, 100, 'ease-out') : null;
  if (fade) fade.effect.updateTiming({ fill: 'forwards' });
  const [msgs] = await Promise.all([loadMessages(item), fade?.finished]);
  if (seq !== state.seq) return;
  state.msgs = msgs;
  state.older = {};
  state.pool = [];
  drawThread(true);
  fillUp();
  fade?.cancel();
  pickTarget();
  $('#input').focus();
}

async function loadMessages(item) {
  const pages = await Promise.all(item.chats.map(c =>
    api('GET', `/v1/chats/${enc(c.id)}/messages`).then(r => (r.items || []).map(m => ({ ...m, net: netOf(c) }))).catch(() => [])));
  return pages.flat().filter(m => !m.isHidden).sort((a, b) => a.timestamp.localeCompare(b.timestamp) || a.sortKey.localeCompare(b.sortKey)).slice(-10);
}

function drawHeader() {
  const item = state.cur;
  $('.who').innerHTML = `${avatar(item)}<b>${esc(item.name || 'Unnamed')}</b>`;
  $('.who .av').title = item.kind === 'group' ? 'Group info and members' : 'Profile';
  $('.who .av').onclick = () => (profile.box.hidden || profile.closing ? openProfile(state.cur) : closeProfile());
  // Every network this person is on, as its logo; the one replies go to is highlighted, a click picks another.
  $('.chips').innerHTML = netsOf(item).map(k => `<button class="chip" data-net="${k}" title="Reply on ${NETS[k].label}${NETS[k].cmd ? ` (/${NETS[k].cmd})` : ''}">${netMark(k)}</button>`).join('');
  $('.chips').querySelectorAll('.chip').forEach(b => (b.onclick = () => { setTarget(chatFor(b.dataset.net), true); input.focus(); }));
  highlightTarget(false);
  $('.more').hidden = false;
}

function highlightTarget(animate) {
  const k = state.target && netOf(state.target.chat);
  for (const b of document.querySelectorAll('.chips .chip')) {
    const on = b.dataset.net === k;
    if (on && animate && !b.classList.contains('on')) anim(b, { scale: [0.85, 1] }, 220);
    b.classList.toggle('on', on);
  }
}

// Beeper hands Instagram shares over as HTML (<p><a href=…>…</a></p>): keep the text only.
const plain = s => (s && /<\/?[a-z][^>]*>/i.test(s) ? new DOMParser().parseFromString(s, 'text/html').body.textContent : s);
const SHARE = /https:\/\/www\.instagram\.com\/(?:reels?|p|stories)\/[\w-]+\/?\S*/;
const PLAY = '<svg class="play" viewBox="0 0 24 24"><path d="M8 5.5v13l10.5-6.5z"/></svg>';
const PAUSE = '<svg class="play" viewBox="0 0 24 24"><path d="M7 5h3.5v14H7zM13.5 5H17v14h-3.5z"/></svg>';
// Instagram view-once media reach Beeper as this sentence only: shown as Instagram's own grey "Photo" pill instead.
const once = s => { const k = s?.match(/^This (\w+) can only be (?:re)?played once/)?.[1]; return k && (/video/i.test(k) ? 'Video' : 'Photo'); };
const ONCE = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9" stroke-dasharray="3.2 2.4"/><path d="M10.5 9.5 12 8v8"/></svg>';

function bubbleHTML(m) {
  if (m.isDeleted) return `<div class="bubble note">Message deleted</div>`;
  const parts = [];
  const text = plain(m.text)?.trim();
  if (once(text)) return `<div class="bubble once">${ONCE}${once(text)}</div>`;
  const share =m.net === 'instagram' && text?.match(SHARE)?.[0];
  const thumb = share && (m.attachments || []).find(a => a.type === 'img' && a.srcURL);
  // A shared reel or post: its cover as a card that opens it, like Instagram's own, instead of the raw link.
  if (thumb) {
    const url = share.replace(/[?#].*$/, '');
    const rest = text.replace(share, '').trim();
    return `<a class="bubble reel" href="${esc(url)}" target="_blank" rel="noreferrer" title="${esc(url)}"><img src="${esc(asset(thumb.srcURL))}" loading="lazy">${/\/p\//.test(url) ? '' : PLAY}</a>`
      + (rest ? `<div class="bubble">${linkify(rest)}</div>` : '');
  }
  for (const a of m.attachments || []) {
    if (a.srcURL && (a.isVoiceNote || a.type === 'audio')) {
      const id = `${m.id}/${a.id || a.srcURL}`;
      parts.push(`<div class="bubble voice${m.isSender || heard.has(id) ? ' heard' : ''}" data-id="${esc(id)}" data-src="${esc(asset(a.srcURL))}" data-type="${esc(a.mimeType || '')}"><button class="toggle" title="Play">${PLAY}</button><div class="track"><i></i></div><span class="time"></span><b class="dot" title="Not played yet"></b></div>`);
      if (a.transcription) parts.push(`<div class="bubble note">${esc(a.transcription)}</div>`);
    } else if (a.isSticker && a.srcURL) parts.push(`<div class="bubble media sticker"><img src="${esc(asset(a.srcURL))}" loading="lazy" alt="Sticker"></div>`);
    else if (a.type === 'img' && a.srcURL && !a.isSticker) parts.push(`<div class="bubble media"><img src="${esc(asset(a.srcURL))}" loading="lazy"></div>`);
    else parts.push(`<div class="bubble note">${a.isVoiceNote ? 'Voice message' + (a.transcription ? `: ${esc(a.transcription)}` : '') : a.type === 'video' ? 'Video' : a.isSticker ? 'Sticker' : esc(a.fileName || 'Attachment')}</div>`);
  }
  if (text) parts.push(`<div class="bubble">${linkify(text)}</div>`);
  if (!parts.length) parts.push(`<div class="bubble note">${esc((m.type || 'event').toLowerCase())}</div>`);
  return parts.join('');
}

// A reply shows the message it answers above its bubble, behind a white line; in a group, with who wrote it.
function quoteHTML(m) {
  if (!m.linkedMessageID || m.type === 'REACTION') return '';
  const q = state.msgs.find(x => x.id === m.linkedMessageID) || state.pool.find(x => x.id === m.linkedMessageID);
  const who = q && state.cur.kind === 'group' ? `<b>${esc(q.isSender ? 'You' : q.senderName)}</b>` : '';
  return `<div class="quote">${who}<span>${q ? esc(once(plain(q.text)?.trim()) || plain(q.text)?.trim() || 'Attachment') : 'An earlier message'}</span></div>`;
}

function msgNodes(m, prev) {
  const nodes = [];
  const day = new Date(m.timestamp).toDateString();
  if (!prev || new Date(prev.timestamp).toDateString() !== day) {
    const d = document.createElement('div');
    d.className = 'day';
    const ago = Math.round((new Date(new Date().toDateString()) - new Date(day)) / 864e5);
    d.textContent = ago === 0 ? 'Today' : ago === 1 ? 'Yesterday' : when(m.timestamp, true);
    nodes.push(d);
  }
  const row = document.createElement('div');
  row.className = `msg${m.isSender ? ' me' : ''}`;
  row.dataset.id = m.id;
  row.dataset.net = m.net;
  row.title = new Date(m.timestamp).toLocaleString('fr-FR');
  const showFrom = state.cur.kind === 'group' && !m.isSender && (!prev || prev.senderID !== m.senderID || prev.isSender);
  row.innerHTML = `<div class="col">${showFrom ? `<div class="from">${esc(m.senderName)}</div>` : ''}${quoteHTML(m)}${bubbleHTML(m)}</div>`;
  row.querySelectorAll('.bubble.voice').forEach(v => voiceIO.observe(v));
  if (!String(m.id).startsWith('pending') && m.type !== 'REACTION') {
    row.querySelector('.col').insertAdjacentHTML('beforeend', reactsHTML(m));
    row.insertAdjacentHTML('beforeend', `<div class="quick">${topEmoji().map(e => `<button data-e="${e}">${e}</button>`).join('')}<button class="all" title="All emoji">${PLUS}</button></div>`);
  }
  nodes.push(row);
  return nodes;
}

// One scrollTo when a row starts opening at the end aims at the end before the row has grown: follow it every frame,
// easing in from wherever the thread was, until it is open and the end reached.
function followEnd(el) {
  const box = $('#msgs'), stop = performance.now() + 1500;
  const step = () => {
    const gap = box.scrollHeight - box.clientHeight - box.scrollTop;
    if (gap > 0) box.scrollTop += RM.matches || gap < 4 ? gap : Math.ceil(gap * 0.3);
    if ((el._anim || gap > 1) && performance.now() < stop) requestAnimationFrame(step);
  };
  step();
}

// The text leaves the field as a bubble: from the field's box to the bubble's place, which it tracks every frame while
// the row opens, the thread scrolls and the field shrinks. Its text keeps the bubble's width, so it never rewraps.
function fly(bubble, from) {
  if (!bubble || !from || RM.matches) return;
  const w = bubble.getBoundingClientRect().width, ghost = bubble.cloneNode(true);
  ghost.className = 'bubble flying';
  ghost.innerHTML = `<div style="width:${w - 24}px">${bubble.innerHTML}</div>`;
  document.body.append(ghost);
  bubble.style.visibility = 'hidden';
  const t0 = performance.now(), ms = 380;
  const step = now => {
    const p = Math.min(1, (now - t0) / ms), e = 1 - (1 - p) ** 4, to = bubble.getBoundingClientRect();
    const mix = (a, b) => a + (b - a) * e;
    Object.assign(ghost.style, {
      left: `${mix(from.left, to.left)}px`, top: `${mix(from.top, to.top)}px`, width: `${mix(from.width, to.width)}px`, height: `${mix(from.height, to.height)}px`,
      background: `rgb(${mix(38, 55)} ${mix(38, 151)} ${mix(38, 240)})`, opacity: mix(1, 0.55),
    });
    if (p < 1) return requestAnimationFrame(step);
    bubble.style.visibility = '';
    ghost.remove();
  };
  step(t0);
}

// At the end, the thread stays at its end as it grows or its box shrinks: pictures loading after it is drawn, the window
// laid out after launch, the field growing.
let atEnd = true;
$('#msgs').addEventListener('scroll', () => { const b = $('#msgs'); atEnd = b.scrollHeight - b.clientHeight - b.scrollTop < 2; }, { passive: true });
const endKeeper = new ResizeObserver(() => { if (atEnd) $('#msgs').scrollTop = $('#msgs').scrollHeight; });
endKeeper.observe($('#msgs'));
endKeeper.observe($('#thread'));

function drawThread(enter, keep) {
  const box = $('#msgs');
  const fromEnd = box.scrollHeight - box.scrollTop;
  const thread = $('#thread');
  thread.classList.remove('in');
  thread.replaceChildren(...state.msgs.flatMap((m, i) => msgNodes(m, state.msgs[i - 1])));
  if (enter) {
    // staggered-entrance template, on the last screenful only, newest last.
    const rows = [...thread.children].slice(-16);
    rows.forEach((r, i) => r.style.setProperty('--i', i));
    void thread.offsetWidth;
    thread.classList.add('in');
  }
  drawSeen();
  box.scrollTop = keep ? box.scrollHeight - fromEnd : box.scrollHeight;
  if (!keep) atEnd = true;
}

/* ---------- Read markers and reactions ---------- */

const selfIn = chatID => new Set(state.msgs.filter(m => m.isSender && m.chatID === chatID).map(m => m.senderID));
// Under my last message, when nobody wrote after it: Seen (at what time; in a group, by how many) once the other side's
// read marker (Beeper's `seen`, on that message or a later one) reaches it, else Sent.
function drawSeen() {
  // While a message is on its way, its row holds the receipt's place; moving it now would shift the thread.
  if (document.querySelector('#thread .msg.pending')) return;
  document.querySelectorAll('#thread .receipt').forEach(r => r.remove());
  const last = state.msgs.at(-1);
  if (!last?.isSender) return;
  const self = selfIn(last.chatID), by = new Map();
  for (const m of state.msgs.filter(m => m.chatID === last.chatID && m.timestamp >= last.timestamp)) {
    const v = m.seen;
    if (v === true || typeof v === 'string') by.set('', typeof v === 'string' ? v : m.timestamp);
    else if (v && typeof v === 'object') for (const [k, t] of Object.entries(v)) if (t && !self.has(k)) by.set(k, typeof t === 'string' ? t : m.timestamp);
  }
  const at = [...by.values()].sort().at(-1);
  const day = at && new Date(at).toDateString() === new Date().toDateString();
  const text = !by.size ? 'Sent' : state.cur.kind === 'group' ? `Seen by ${by.size}` : `Seen ${day ? new Date(at).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' }) : when(at)}`;
  document.querySelector(`#thread .msg[data-id="${CSS.escape(last.id)}"] .col`)?.insertAdjacentHTML('beforeend', `<div class="receipt">${text}</div>`);
}
function reactsHTML(m) {
  if (!m.reactions?.length) return '';
  const self = selfIn(m.chatID), keys = new Map();
  for (const r of m.reactions) {
    const k = keys.get(r.reactionKey) || { n: 0, me: false, img: r.imgURL };
    k.n++;
    k.me ||= self.has(r.participantID) || r.participantID === 'me';
    keys.set(r.reactionKey, k);
  }
  return `<div class="reacts">${[...keys].map(([key, k]) => `<button class="r${k.me ? ' me' : ''}" data-e="${esc(key)}" title="${k.me ? 'Remove your reaction' : 'React the same'}">${k.img && !/\p{Extended_Pictographic}/u.test(key) ? `<img src="${esc(asset(k.img))}" alt="">` : esc(key)}${k.n > 1 ? `<i>${k.n}</i>` : ''}</button>`).join('')}</div>`;
}
function redrawMsg(m) {
  const old = document.querySelector(`#thread .msg[data-id="${CSS.escape(m.id)}"]`);
  if (!old) return;
  const i = state.msgs.findIndex(x => x.id === m.id);
  old.replaceWith(msgNodes(m, state.msgs[i - 1]).at(-1));
}
// The five reactions I use most: counted once over my recent chats, then each one I send from here.
const reactCount = JSON.parse(localStorage.reactCount || '{}');
const topEmoji = () => [...new Set([...Object.entries(reactCount).sort((a, b) => b[1] - a[1]).map(([k]) => k), '❤️', '😂', '👍', '😮', '😢'])].slice(0, 5);
async function seedReactions() {
  if (localStorage.reactCount) return;
  const chats = state.all.flatMap(i => i.chats).sort((a, b) => (b.last || '').localeCompare(a.last || '')).slice(0, 40);
  for (const c of chats) {
    const r = await api('GET', `/v1/chats/${enc(c.id)}/messages`).catch(() => null);
    const self = new Set((r?.items || []).filter(m => m.isSender).map(m => m.senderID));
    for (const m of r?.items || []) for (const x of m.reactions || []) if (self.has(x.participantID)) reactCount[x.reactionKey] = (reactCount[x.reactionKey] || 0) + 1;
  }
  localStorage.reactCount = JSON.stringify(reactCount);
}
// A reaction answers the conversation like a reply does; my own reaction clicked again is taken back.
function react(m, key) {
  const self = selfIn(m.chatID);
  const path = `/v1/chats/${enc(m.chatID)}/messages/${enc(m.id)}/reactions`;
  const had = (m.reactions || []).find(r => r.reactionKey === key && (self.has(r.participantID) || r.participantID === 'me'));
  if (had) {
    m.reactions = m.reactions.filter(r => r !== had);
    api('DELETE', `${path}/${enc(key)}`).catch(e => toast(`Not removed: ${e}`));
  } else {
    m.reactions = [...(m.reactions || []), { participantID: [...self][0] || 'me', reactionKey: key }];
    reactCount[key] = (reactCount[key] || 0) + 1;
    localStorage.reactCount = JSON.stringify(reactCount);
    api('POST', path, { reactionKey: key }).catch(e => toast(`Reaction not sent: ${e}`));
    markRead(state.cur);
  }
  redrawMsg(m);
}
// The hover bar shows once the pointer reaches the fifth of the bubble on the bar's side (or past it),
// stays until it leaves the row, and sits level with the middle of the bubbles (name and reactions left out).
let hotRow = null;
const unhot = () => { hotRow?.classList.remove('hot'); hotRow = null; };
$('#thread').addEventListener('pointermove', e => {
  const row = e.target.closest('.msg');
  if (row === hotRow) return;
  unhot();
  const q = row?.querySelector('.quick');
  if (!q) return;
  const bs = [...row.querySelectorAll('.bubble')].map(b => b.getBoundingClientRect());
  const left = Math.min(...bs.map(b => b.left)), right = Math.max(...bs.map(b => b.right)), fifth = (right - left) * .2;
  if (row.classList.contains('me') ? e.clientX > left + fifth : e.clientX < right - fifth) return;
  const top = bs[0].top, bottom = bs.at(-1).bottom;
  const rowTop = row.getBoundingClientRect().top + parseFloat(getComputedStyle(row).paddingTop);
  q.style.marginTop = `${Math.max(0, (top + bottom) / 2 - rowTop - q.offsetHeight / 2)}px`;
  row.classList.add('hot');
  hotRow = row;
});
$('#thread').addEventListener('pointerleave', unhot);
$('#msgs').addEventListener('scroll', unhot, { passive: true });
$('#thread').addEventListener('click', e => {
  if (e.target.closest('.quick .all')) return openPicker(e.target.closest('.msg'));
  const b = e.target.closest('.quick button, .reacts button');
  const m = b && state.msgs.find(x => x.id === b.closest('.msg').dataset.id);
  if (m) react(m, b.dataset.e);
});

// The + at the end of the hover bar opens every emoji: the most used first, a field to search them by name.
const PLUS = '<svg viewBox="0 0 16 16" width="14" height="14"><path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>';
const picker = $('#picker');
async function openPicker(row) {
  const m = state.msgs.find(x => x.id === row.dataset.id);
  if (!m) return;
  picker._msg = m;
  const field = picker.querySelector('input'), grid = picker.querySelector('.grid');
  const draw = async () => {
    const q = field.value.trim();
    const list = q ? (await emojiFind(q)).map(([e]) => e) : [...new Set([...topEmoji(), ...Object.keys(reactCount), ...(EMOJI ||= await fetch('emoji.json').then(r => r.json())).map(([e]) => e)])];
    grid.innerHTML = list.map(e => `<button data-e="${e}">${e}</button>`).join('') || '<div class="none">No emoji by that name</div>';
    grid.scrollTop = 0;
  };
  field.value = '';
  await draw();
  field.oninput = draw;
  const r = (row.querySelector('.quick') || row.querySelector('.bubble')).getBoundingClientRect();
  picker.hidden = false;
  const h = picker.offsetHeight, w = picker.offsetWidth;
  picker.style.left = `${Math.max(8, Math.min(innerWidth - w - 8, r.left))}px`;
  picker.style.top = `${r.top - h - 6 > 8 ? r.top - h - 6 : r.bottom + 6}px`;
  anim(picker, { opacity: [0, 1], transform: ['scale(.96)', 'none'] }, 160);
  field.focus();
}
function closePicker() {
  if (picker.hidden) return;
  anim(picker, { opacity: [1, 0] }, 120).finished.then(() => (picker.hidden = true)).catch(() => {});
  input.focus();
}
picker.addEventListener('click', e => {
  const b = e.target.closest('.grid button');
  if (b) { react(picker._msg, b.dataset.e); closePicker(); }
});
picker.querySelector('input').addEventListener('keydown', e => {
  if (e.key === 'Enter') { e.preventDefault(); picker.querySelector('.grid button')?.click(); }
  if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closePicker(); }
});
addEventListener('pointerdown', e => { if (!picker.hidden && !picker.contains(e.target)) closePicker(); });

// Scrolling up loads older messages, a page per app. One app's page reaches further back than another's, so only what is
// newer than every app's oldest loaded message is shown; the rest waits in state.pool.
async function loadOlder() {
  const item = state.cur, seq = state.seq;
  if (state.olderBusy || !item) return false;
  const left = item.chats.filter(c => state.older[c.id]?.more !== false);
  if (!left.length && !state.pool.length) return false;
  state.olderBusy = true;
  try {
    await Promise.all(left.map(async c => {
      const o = state.older[c.id];
      const cursor = o?.cursor || state.msgs.find(m => m.chatID === c.id)?.sortKey;
      const r = await api('GET', `/v1/chats/${enc(c.id)}/messages` + (cursor ? `?cursor=${enc(cursor)}&direction=before` : ''));
      const items = (r.items || []).map(m => ({ ...m, net: netOf(c) }));
      state.older[c.id] = { cursor: r.oldestCursor || items.at(-1)?.sortKey, more: !!r.hasMore && items.length > 0, oldest: items.reduce((t, m) => (m.timestamp < t ? m.timestamp : t), o?.oldest || '9') };
      state.pool.push(...items);
    }));
  } catch {
    return false;
  } finally {
    state.olderBusy = false;
  }
  if (seq !== state.seq) return false;
  const cut = item.chats.map(c => state.older[c.id]).filter(o => o?.more).map(o => o.oldest).sort().at(-1) || '';
  const known = new Set(state.msgs.map(m => m.id));
  const add = [...new Map(state.pool.filter(m => !known.has(m.id) && !m.isHidden && m.timestamp >= cut).map(m => [m.id, m])).values()];
  state.pool = state.pool.filter(m => !known.has(m.id) && m.timestamp < cut);
  if (add.length) {
    state.msgs = [...add, ...state.msgs].sort((a, b) => a.timestamp.localeCompare(b.timestamp) || a.sortKey.localeCompare(b.sortKey));
    drawThread(false, true);
  }
  return true;
}
// Until the thread fills the window, or reaches above the top, nothing can be scrolled: load until it does.
async function fillUp() {
  const box = $('#msgs');
  while (box.scrollTop < 300 && (await loadOlder()));
}
$('#msgs').addEventListener('scroll', () => { if ($('#msgs').scrollTop < 300) fillUp(); }, { passive: true });

async function pollThread() {
  const item = state.cur;
  if (!item || document.hidden) return;
  const seq = state.seq;
  const msgs = await loadMessages(item);
  if (seq !== state.seq || !msgs.length) return;
  // A message still flying or opening is left alone: the next poll swaps it once it stands still.
  if (document.querySelector('.bubble.flying') || [...document.querySelectorAll('#thread .msg.pending')].some(p => p._anim)) return;
  const known = new Set(state.msgs.map(m => m.id));
  // A reaction or a read marker changes a message already shown: that one is redrawn in place.
  const look = m => JSON.stringify([m.reactions || [], m.seen || null]);
  for (const m of msgs) {
    const i = state.msgs.findIndex(x => x.id === m.id);
    if (i >= 0 && look(state.msgs[i]) !== look(m)) { state.msgs[i] = m; redrawMsg(m); }
  }
  drawSeen();
  const fresh = msgs.filter(m => !known.has(m.id));
  if (!fresh.length) return;
  const box = $('#msgs');
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 80;
  const lastKnown = state.msgs[state.msgs.length - 1]?.timestamp || '';
  if (fresh.some(m => m.timestamp < lastKnown)) {
    const fresh = new Set(msgs.map(m => m.id));
    state.msgs = [...state.msgs.filter(m => !fresh.has(m.id)), ...msgs].sort((a, b) => a.timestamp.localeCompare(b.timestamp) || a.sortKey.localeCompare(b.sortKey));
    drawThread(false, true);
    return;
  }
  let last;
  for (const m of fresh) {
    // The app can rewrite what was sent (Instagram drops a leading "- "): the oldest pending row on that chat is this one.
    const pending = !m.isSender ? null : [...document.querySelectorAll('#thread .msg.pending')].find(p => p._chat === m.chatID);
    const nodes = msgNodes(m, state.msgs[state.msgs.length - 1]);
    state.msgs.push(m);
    // The sent row takes the pending one's place as it stands, only its fade lifted: nothing moves.
    if (pending && !pending._anim) {
      const row = nodes.pop();
      row.querySelector('.col').insertAdjacentHTML('beforeend', '<div class="receipt">&nbsp;</div>');
      pending.replaceWith(...nodes.splice(0), row);
      row.querySelectorAll('.bubble').forEach(b => anim(b, { opacity: [0.55, 1] }, 250));
    } else pending?.remove();
    for (const n of nodes) {
      $('#thread').append(n);
      if (!n.hidden) { n.hidden = true; collapse(n, false, 280); last = n; }
    }
  }
  drawSeen();
  if (atBottom) followEnd(last || box);
  if (fresh.some(m => !m.isSender)) pickTarget(true);
  // A message of mine, sent from here or from another device, answers what came before it.
  if (fresh.some(m => m.isSender)) markRead(item);
}

// A badge stays until I answer (a message of mine, here or elsewhere; a reaction elsewhere clears Beeper's count) or
// press ⌘K for "seen, nothing to say"; opening a chat sends no read receipt, those two do.
const seen = JSON.parse(localStorage.seen || '{}');
// What I marked seen tells Beeper too, so the sender gets the read receipt; a chat still unread there is sent again.
const sendRead = c => api('POST', `/v1/chats/${enc(c.id)}/read`, {}).catch(() => {});
function applySeen(item) {
  for (const c of item.chats) if (c.unread && Date.parse(seen[c.id]) >= Date.parse(c.last)) { c.unread = 0; sendRead(c); }
  item.unread = item.chats.reduce((s, c) => s + c.unread, 0);
}
function markRead(item) {
  for (const c of item.chats) {
    const newest = state.msgs.filter(m => m.chatID === c.id && !m.isSender).at(-1)?.timestamp;
    seen[c.id] = [seen[c.id], c.last, newest].filter(Boolean).sort((a, b) => Date.parse(b) - Date.parse(a))[0];
    if (c.unread) sendRead(c);
    c.unread = 0;
  }
  localStorage.seen = JSON.stringify(seen);
  item.unread = 0;
  document.querySelector(`.fav[data-id="${CSS.escape(item.id)}"]`)?.classList.remove('unread');
  const n = document.querySelector(`#list .row[data-id="${CSS.escape(item.id)}"]`);
  const badge = n?.querySelector('.badge');
  if (badge) anim(badge, { scale: [1, 0.4], opacity: [1, 0] }, 180).finished.then(() => fill(n, item)).catch(() => {});
}

/* ---------- Composer ---------- */

// Default target: the network of their last message; a choice made by hand holds until another person is opened.
function pickTarget(onlyIfAuto) {
  const item = state.cur;
  if (onlyIfAuto && state.target?.manual) return;
  const last = [...state.msgs].reverse().find(m => !m.isSender);
  const chat = (last && item.chats.find(c => c.id === last.chatID)) || item.chats[0];
  setTarget(chat, false);
}

function setTarget(chat, manual) {
  if (state.target?.chat.id === chat.id) { state.target.manual ||= manual; return; }
  state.target = { chat, manual };
  input.placeholder = `Message on ${NETS[netOf(chat)].label}`;
  highlightTarget(true);
}

function chatFor(netKey) {
  return state.cur.chats.filter(c => netOf(c) === netKey).sort((a, b) => (b.last || '').localeCompare(a.last || ''))[0];
}

const input = $('#input');
function autosize() {
  const h0 = input.offsetHeight;
  input.style.height = 'auto';
  const h1 = Math.min(input.scrollHeight, 160);
  input.style.height = h0 + 'px';
  void input.offsetHeight;
  input.style.height = h1 + 'px';
  $('#send').disabled = !input.value.trim();
}
// "/ws " (or "/ws" then Enter) switches the reply's network; the command itself is never sent.
function command(atEnd) {
  const m = input.value.match(atEnd ? /^\/([a-z]{2})\s*$/i : /^\/([a-z]{2})\s/i);
  const key = m && state.cur && Object.keys(NETS).find(k => NETS[k].cmd === m[1].toLowerCase());
  if (!key) return false;
  const chat = chatFor(key);
  if (chat) setTarget(chat, true);
  else toast(`No ${NETS[key].label} chat with ${state.cur.name}`);
  input.value = input.value.slice(m[0].length);
  autosize();
  return true;
}
input.addEventListener('input', () => { command(false) || autosize(); emojiSearch(); });
input.addEventListener('keydown', e => {
  if (emojiKey(e)) return;
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); command(true) || send(); }
  if (e.key === 'Escape') { input.value = ''; autosize(); setReply(null); }
});

// ":" then a few letters lists matching emoji by their Unicode name (unicode-emoji-json), name left, emoji right.
let EMOJI = null;
const emo = { list: [], at: 0, from: 0 };
async function emojiSearch() {
  const pos = input.selectionStart;
  const q = input.value.slice(0, pos).match(/(?:^|\s):([\p{L}_]{2,})$/u)?.[1]?.toLowerCase();
  if (!q) return showEmoji([]);
  emo.from = pos - q.length - 1;
  showEmoji((await emojiFind(q)).slice(0, 8));
}
// A whole word first (":joy" → 😂 before 🕹️), then a name starting with it, a word starting with it, anywhere.
async function emojiFind(q) {
  EMOJI ||= await fetch('emoji.json').then(r => r.json());
  q = q.toLowerCase().replace(/[^\p{L}_ ]/gu, '').replace(/ /g, '_');
  const key = q.replace(/_/g, '');
  const rank = ([, slug]) => (slug.split('_').includes(q) ? 0 : slug.startsWith(q) ? 1 : new RegExp(`(^|_)${q}`).test(slug) ? 2 : slug.replace(/_/g, '').includes(key) ? 3 : 9);
  return EMOJI.map(e => [e, rank(e)]).filter(([, r]) => r < 9).sort((a, b) => a[1] - b[1]).map(([e]) => e);
}
function showEmoji(list) {
  const box = $('#emoji');
  emo.list = list;
  emo.at = 0;
  if (!list.length) {
    if (!box.hidden && !box._out) box._out = anim(box, { opacity: [1, 0], transform: ['none', 'translateY(4px)'] }, 140).finished.then(() => { box.hidden = !emo.list.length; box._out = null; }).catch(() => {});
    return;
  }
  box.innerHTML = list.map(([e, slug], i) => `<div class="item${i ? '' : ' hot'}" data-i="${i}"><span>${esc(slug.replace(/_/g, ' '))}</span><b>${e}</b></div>`).join('');
  box.style.bottom = $('footer').offsetHeight + 'px';
  if (box.hidden || box._out) { box._out = null; box.hidden = false; anim(box, { opacity: [0, 1], transform: ['translateY(4px)', 'none'] }, 160); }
}
function pickEmoji(i) {
  const [e] = emo.list[i];
  const end = input.selectionStart;
  input.value = input.value.slice(0, emo.from) + e + input.value.slice(end);
  input.selectionStart = input.selectionEnd = emo.from + e.length;
  showEmoji([]);
  autosize();
  input.focus();
}
function emojiKey(e) {
  if (!emo.list.length) return false;
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    emo.at = (emo.at + (e.key === 'ArrowDown' ? 1 : emo.list.length - 1)) % emo.list.length;
    $('#emoji').querySelectorAll('.item').forEach((n, i) => n.classList.toggle('hot', i === emo.at));
  } else if ((e.key === 'Enter' || e.key === 'Tab') && !e.isComposing) pickEmoji(emo.at);
  else if (e.key === 'Escape') showEmoji([]);
  else return false;
  e.preventDefault();
  return true;
}
$('#emoji').addEventListener('pointerdown', e => {
  const n = e.target.closest('.item');
  if (n) { e.preventDefault(); pickEmoji(+n.dataset.i); }
});
input.addEventListener('blur', () => showEmoji([]));

// The bar above the field: the message a reply answers, or the one being edited (its text then fills the field).
function setReply(m, edit = false) {
  if (state.edit && !(edit && m)) { input.value = ''; autosize(); }
  state.reply = m && !edit ? m : null;
  state.edit = m && edit ? m : null;
  const bar = $('#reply');
  if (m) {
    const chat = state.cur.chats.find(c => c.id === m.chatID);
    if (chat) setTarget(chat, true);
    bar.innerHTML = `<b>${edit ? 'Editing' : esc(m.isSender ? 'You' : m.senderName || state.cur.name)}</b><span>${esc(plain(m.text) || 'Attachment')}</span>`;
    if (edit) { input.value = plain(m.text) || ''; autosize(); }
    input.focus();
  }
  collapse(bar, !m, 220);
}


$('#send').onclick = send;
$('#send').disabled = true;

async function send() {
  const text = input.value.trim();
  if (state.edit && text) {
    const m = state.edit;
    setReply(null);
    if (text !== plain(m.text)) editMsg(m, text);
    return;
  }
  if (!text || !state.target) return;
  const from = input.getBoundingClientRect();
  input.value = '';
  autosize();
  post({ text }, undefined, from);
}

// Shows the message at once, faded, then sends it to the chosen app; `upload` (a voice message) goes to Beeper first.
async function post(m, upload, from) {
  const chat = state.target.chat;
  const reply = state.reply?.chatID === chat.id ? state.reply.id : undefined;
  setReply(null);
  Object.assign(m, { id: 'pending-' + Date.now(), linkedMessageID: reply, isSender: true, net: netOf(chat), chatID: chat.id, timestamp: new Date().toISOString(), sortKey: '' });
  const [row] = msgNodes(m, state.msgs[state.msgs.length - 1]).slice(-1);
  row.classList.add('pending');
  row._chat = chat.id;
  // "Sent" will stand under this one: its place is kept now, the old one folds away.
  document.querySelectorAll('#thread .receipt').forEach(r => collapse(r, true, 260));
  row.querySelector('.col').insertAdjacentHTML('beforeend', '<div class="receipt">&nbsp;</div>');
  $('#thread').append(row);
  row.hidden = true;
  collapse(row, false, 300);
  fly(row.querySelector('.bubble'), from);
  followEnd(row);
  try {
    const attachment = upload && (await upload());
    await api('POST', `/v1/chats/${enc(chat.id)}/messages`, { text: m.text, attachment, replyToMessageID: reply });
    markRead(state.cur);
    setTimeout(pollThread, 600);
  } catch (e) {
    row.classList.remove('pending');
    row.classList.add('failed');
    row.title = `Not sent: ${e}`;
  }
}

/* ---------- Voice messages out: click the mic, click again to send, esc to drop ---------- */

const rec = { mr: null, chunks: [], t0: 0, timer: 0 };
async function toggleRecord() {
  if (rec.mr) return stopRecord(true);
  if (!state.target) return;
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  } catch (e) {
    return toast(`No microphone: ${e.message || e}`);
  }
  const type = ['audio/mp4', 'audio/webm;codecs=opus'].find(t => MediaRecorder.isTypeSupported(t));
  rec.mr = new MediaRecorder(stream, type ? { mimeType: type } : {});
  rec.chunks = [];
  rec.mr.ondataavailable = e => e.data.size && rec.chunks.push(e.data);
  rec.mr.start();
  rec.t0 = Date.now();
  $('#mic').classList.add('recording');
  const tick = () => (input.placeholder = `Recording ${clock((Date.now() - rec.t0) / 1000)}: click the mic to send, esc to drop`);
  tick();
  rec.timer = setInterval(tick, 500);
}
function stopRecord(keep) {
  const mr = rec.mr;
  if (!mr) return;
  rec.mr = null;
  clearInterval(rec.timer);
  $('#mic').classList.remove('recording');
  input.placeholder = `Message on ${NETS[netOf(state.target.chat)].label}`;
  const secs = (Date.now() - rec.t0) / 1000;
  mr.onstop = () => {
    mr.stream.getTracks().forEach(t => t.stop());
    if (keep && rec.chunks.length) sendVoice(new Blob(rec.chunks, { type: mr.mimeType.split(';')[0] || 'audio/mp4' }), secs);
  };
  mr.stop();
}
function sendVoice(blob, secs) {
  post({ attachments: [{ type: 'audio', isVoiceNote: true, srcURL: URL.createObjectURL(blob), mimeType: blob.type }] }, async () => {
    const content = await new Promise(r => { const f = new FileReader(); f.onload = () => r(f.result.split(',')[1]); f.readAsDataURL(blob); });
    const up = await api('POST', '/v1/assets/upload/base64', { content, mimeType: blob.type, fileName: `voice.${blob.type.includes('webm') ? 'webm' : 'm4a'}` });
    if (!up.uploadID) throw up.error || 'upload failed';
    return { uploadID: up.uploadID, type: 'voice-note', duration: up.duration || secs };
  });
}
$('#mic').onclick = toggleRecord;
addEventListener('keydown', e => { if (e.key === 'Escape' && rec.mr) { e.preventDefault(); stopRecord(false); } }, true);

/* ---------- Right-click on a message: reply, react, copy, edit, delete ---------- */

$('#thread').addEventListener('contextmenu', e => {
  const row = e.target.closest('.msg');
  const m = row && state.msgs.find(x => x.id === row.dataset.id);
  if (!m || row.classList.contains('pending')) return;
  e.preventDefault();
  const anchor = row.querySelector('.bubble') || row;
  const text = plain(m.text)?.trim();
  menu(anchor, mm => {
    mm.append(item('Reply', { hint: '⌘R', action: () => { closeMenu(); setReply(m); } }));
    mm.append(item('React…', { action: () => { closeMenu(); openPicker(row); } }));
    if (text) mm.append(item('Copy', { action: () => { closeMenu(); copyText(text); } }));
    if (m.isSender && text) mm.append(item('Edit', { action: () => { closeMenu(); setReply(m, true); } }));
    if (m.isSender) {
      const del = item('Delete', { action: () => {
        // A second click, so a stray one deletes nothing: the message goes for everyone in the chat.
        if (!del.classList.contains('sure')) { del.classList.add('sure'); del.querySelector('span').textContent = 'Delete for everyone'; return; }
        closeMenu();
        deleteMsg(m);
      } });
      mm.append(Object.assign(document.createElement('div'), { className: 'sep' }), del);
    }
  }, { up: anchor.getBoundingClientRect().top > innerHeight / 2 });
});
function copyText(text) {
  navigator.clipboard.writeText(text).then(() => toast('Copied'), () => {
    const t = Object.assign(document.createElement('textarea'), { value: text });
    document.body.append(t);
    t.select();
    document.execCommand('copy');
    t.remove();
    toast('Copied');
  });
}
function editMsg(m, text) {
  const was = m.text;
  m.text = text;
  redrawMsg(m);
  api('PUT', `/v1/chats/${enc(m.chatID)}/messages/${enc(m.id)}`, { text }).catch(e => { m.text = was; redrawMsg(m); toast(`Not edited: ${e}`); });
}
function deleteMsg(m) {
  const row = document.querySelector(`#thread .msg[data-id="${CSS.escape(m.id)}"]`);
  state.msgs = state.msgs.filter(x => x !== m);
  if (row) collapse(row, true, 240).then(() => row.remove());
  drawSeen();
  api('DELETE', `/v1/chats/${enc(m.chatID)}/messages/${enc(m.id)}`).catch(e => { toast(`Not deleted: ${e}`); pollThread(); });
}

/* ---------- Menus ---------- */

let openMenu = null;
function closeMenu() {
  const m = openMenu;
  if (!m) return;
  openMenu = null;
  m._anchor?.classList.remove('open');
  anim(m, { opacity: [1, 0], transform: ['none', `translateY(${m._up ? 6 : -6}px) scale(.98)`] }, 160).finished.then(() => m.remove()).catch(() => m.remove());
}
// menu-drop template: the panel fades in and settles 6 px from where it hangs.
function menu(anchor, build, { up = false, right = false } = {}) {
  closeMenu();
  const m = document.createElement('div');
  m.className = 'menu';
  m._anchor = anchor;
  build(m);
  document.body.append(m);
  const r = anchor.getBoundingClientRect(), below = innerHeight - r.bottom - 14, above = r.top - 14;
  // It opens on the side it fits, else on the roomier one, scrolling past what the window cannot hold.
  if (m.offsetHeight > (up ? above : below)) up = (up ? above : below) < (up ? below : above) ? !up : up;
  m._up = up;
  m.style.maxHeight = (up ? above : below) + 'px';
  m.style.overflowY = 'auto';
  if (up) m.style.bottom = innerHeight - r.top + 6 + 'px'; else m.style.top = r.bottom + 6 + 'px';
  if (right) m.style.right = Math.max(8, innerWidth - r.right) + 'px';
  else m.style.left = Math.min(r.left, innerWidth - m.offsetWidth - 8) + 'px';
  m.style.transformOrigin = up ? 'bottom' : 'top';
  anchor.classList.add('open');
  anim(m, { opacity: [0, 1], transform: [`translateY(${up ? 6 : -6}px) scale(.98)`, 'none'] }, 200);
  openMenu = m;
  return m;
}
// popup-morph: the menu's box eases from its old size to the new one when its content changes.
function morph(m, build) {
  const h0 = m.offsetHeight, w0 = m.offsetWidth;
  m.replaceChildren();
  build(m);
  const h1 = m.offsetHeight, w1 = m.offsetWidth;
  anim(m, { height: [h0 + 'px', h1 + 'px'], width: [w0 + 'px', w1 + 'px'] }, 240);
}
addEventListener('pointerdown', e => { if (openMenu && !openMenu.contains(e.target) && !openMenu._anchor.contains(e.target)) closeMenu(); });
addEventListener('keydown', e => { if (e.key === 'Escape') closeMenu(); });

function item(label, { hint = '', icon = '', action }) {
  const b = document.createElement('button');
  b.className = 'item';
  b.innerHTML = `${icon}<span>${esc(label)}</span>${hint ? `<span class="hint">${esc(hint)}</span>` : ''}`;
  b.onclick = action;
  return b;
}

$('.more').onclick = () => openMore($('.more'));
function openMore(anchor) {
  if (openMenu?._anchor === anchor) return closeMenu();
  const person = state.cur;
  if (!person) return;
  const sep = () => Object.assign(document.createElement('div'), { className: 'sep' });
  // One section per kind of setting, a thin white line between them.
  const m = menu(anchor, m => {
    const tab = state.tabs.find(t => inTab(person, t));
    m.append(item(isFav(person) ? 'Remove from favorites' : 'Add to favorites', { hint: '⌘F', action: () => { closeMenu(); toggleFav(person); } }));
    if (person.kind === 'person') {
      if (tab) m.append(item(`Remove from ${tab.name}`, { action: () => { closeMenu(); addToTab(person, tab.name, false); } }));
      m.append(item(tab ? 'Move to another group…' : 'Add to a group…', { action: () => morph(m, mm => {
        for (const t of state.tabs.filter(t => t !== tab)) mm.append(item(t.name, { action: () => { closeMenu(); addToTab(person, t.name); } }));
        mm.append(item('New group…', { action: () => { closeMenu(); newTab($('#tabbox .newgroup'), person); } }));
      }) }));
    }
    m.append(sep(), item('Alias…', { hint: '⌘M', action: () => { closeMenu(); rename(); } }));
    m.append(item('Change picture…', { action: () => { closeMenu(); pickPicture(person); } }));
    if (person.chats.some(c => state.pictures?.[c.id])) m.append(item('Remove the picture set', { action: () => { closeMenu(); setPicture(person, null); } }));
    const muted = person.chats.every(c => c.muted);
    m.append(sep(), item(muted ? 'Unmute' : 'Mute', { hint: muted ? '' : 'no badge, no count', action: () => { closeMenu(); mute(person, !muted); } }));
    if (person.kind !== 'person') m.append(item(person.hidden ? 'Show in the list' : 'Hide from the list', { hint: person.hidden ? '' : '⌘D still finds it', action: () => { closeMenu(); hide(person, !person.hidden); } }));
    m.append(sep(), item('Merge with…', { action: () => morph(m, mm => mergePicker(mm, person)) }));
    for (const c of person.chats.length > 1 ? person.chats : []) {
      const k = netOf(c);
      m.append(item(`Split ${NETS[k].label} off`, { hint: c.title !== person.name ? c.title : '', action: () => { closeMenu(); (person.kind === 'person' ? split : splitGroup)(person, c); } }));
    }
  }, { right: anchor.classList.contains('more') });
  return m;
}

function mergePicker(m, person) {
  const field = document.createElement('input');
  field.placeholder = `Merge ${person.name} with…`;
  const kind = person.kind === 'person' ? 'person' : 'group';
  const found = document.createElement('div');
  found.className = 'found';
  const draw = () => {
    const q = field.value.trim().toLowerCase();
    const others = [...state.byId.values()].filter(i => (i.kind === 'person' ? 'person' : 'group') === kind && i.id !== person.id && (!q || fold(i.name).includes(fold(q)) || fold(i.original).includes(fold(q)))).slice(0, 30);
    found.replaceChildren(...others.map(o => item(o.name || 'Unnamed', { icon: avatar(o), hint: netsOf(o).map(k => NETS[k].label).join(', '), action: () => { closeMenu(); (kind === 'person' ? merge : mergeGroups)(person, o); } })));
    if (!others.length) found.innerHTML = `<div class="none">${kind === 'person' ? 'Nobody' : 'No group'} by that name</div>`;
  };
  field.oninput = draw;
  field.onkeydown = e => { if (e.key === 'Enter') found.querySelector('.item')?.click(); };
  m.append(field, found);
  draw();
  setTimeout(() => field.focus(), 0);
}

// A picture of one's own for a person or a group: any image file, cut to a 256 px square, kept in overrides.json.
function pickPicture(item) {
  const field = Object.assign(document.createElement('input'), { type: 'file', accept: 'image/*' });
  field.onchange = async () => {
    const file = field.files[0];
    if (!file) return;
    const img = await createImageBitmap(file);
    const side = Math.min(img.width, img.height), canvas = Object.assign(document.createElement('canvas'), { width: 256, height: 256 });
    canvas.getContext('2d').drawImage(img, (img.width - side) / 2, (img.height - side) / 2, side, side, 0, 0, 256, 256);
    setPicture(item, canvas.toDataURL('image/jpeg', 0.85));
  };
  field.click();
}
function setPicture(item, url) {
  editOverrides(ov => {
    ov.pictures ||= {};
    for (const c of item.chats) delete ov.pictures[c.id];
    if (url) ov.pictures[item.chats[0].id] = url;
  }, url ? `New picture for ${item.name}` : `Picture of ${item.name} removed`);
}
// An alias for the open person or group: their name becomes a field in the header; Enter keeps it (empty: back
// to the apps' name), esc drops it. The apps' name stays searchable.
function rename() {
  const cur = state.cur, b = $('.who b');
  if (!cur || !b) return;
  const original = cur.original || cur.name;
  const field = Object.assign(document.createElement('input'), { value: cur.name || '', placeholder: original || 'Alias', spellcheck: false });
  b.replaceWith(field);
  field.focus();
  field.select();
  let over = false;
  const end = keep => {
    if (over) return;
    over = true;
    const name = field.value.trim();
    field.replaceWith(b);
    if (!keep || name === cur.name) return;
    const alias = name && name !== original;
    editOverrides(ov => {
      ov.names ||= {};
      for (const c of cur.chats) delete ov.names[c.id];
      if (alias) ov.names[cur.chats[0].id] = name;
    }, alias ? `${original} is now ${name}` : `${cur.name} back to ${original}`).then(() => $('.who input') || drawHeader());
  };
  // ⌘M on another row while typing keeps this alias and goes on to that one.
  field.onkeydown = e => {
    if (e.metaKey && e.key.toLowerCase() === 'm') return end(true);
    e.stopPropagation();
    if (e.key === 'Enter') end(true);
    if (e.key === 'Escape') end(false);
  };
  field.onblur = () => end(true);
}
function hide(group, on) {
  editOverrides(ov => {
    ov.hidden = ov.hidden.filter(id => id !== group.id);
    if (on) ov.hidden.push(group.id);
  }, on ? `${group.name} hidden from the list` : `${group.name} back in the list`);
}
async function editOverrides(change, message) {
  const old = await invoke('overrides');
  const next = structuredClone(old);
  next.merges ||= [];
  next.splits ||= [];
  next.hidden ||= [];
  change(next);
  await invoke('set_overrides', { value: next });
  state.pictures = next.pictures;
  await refreshList();
  toast(message, async () => { await invoke('set_overrides', { value: old }); await refreshList(); });
}
function merge(a, b) {
  const ids = [...a.chats, ...b.chats].map(c => c.id);
  editOverrides(ov => {
    ov.splits = ov.splits.filter(id => !ids.includes(id));
    ov.merges.push([a.chats[0].id, b.chats[0].id]);
  }, `Merged ${a.name} and ${b.name}`);
}
// The same group on two apps, one conversation: kept in overrides.groupMerges, the first keeps its name and picture.
function mergeGroups(a, b) {
  editOverrides(ov => { (ov.groupMerges ||= []).push([a.chats[0].id, b.chats[0].id]); }, `Merged ${a.name} and ${b.name}`);
}
function splitGroup(g, chat) {
  editOverrides(ov => { ov.groupMerges = (ov.groupMerges || []).filter(pair => !pair.includes(chat.id)); }, `Split ${NETS[netOf(chat)].label} off ${g.name}`);
}
// Muting goes to the apps through Beeper, so it holds on the phone too.
async function mute(item, on) {
  await Promise.all(item.chats.map(c => api('PATCH', `/v1/chats/${enc(c.id)}`, { isMuted: on }).then(() => (c.muted = on)).catch(e => toast(`${NETS[netOf(c)].label}: ${e}`))));
  toast(`${item.name} ${on ? 'muted' : 'unmuted'}`);
  refreshList();
}
function split(person, chat) {
  editOverrides(ov => {
    ov.merges = ov.merges.filter(pair => !pair.includes(chat.id));
    if (!ov.splits.includes(chat.id)) ov.splits.push(chat.id);
  }, `Split ${NETS[netOf(chat)].label} off ${person.name}`);
}

// toast template: a dark pill rises 24 px with Undo; the next one takes its place.
function toast(text, undo) {
  const old = document.querySelector('.toast');
  old?.animate({ opacity: [1, 0] }, { duration: 100, fill: 'forwards' }).finished.then(() => old.remove());
  const el = document.createElement('div');
  el.className = undo ? 'toast' : 'toast plain';
  el.role = 'status';
  el.innerHTML = `<span></span>${undo ? '<button>Undo</button>' : ''}`;
  el.firstChild.textContent = text;
  const gone = async () => {
    if (!el.isConnected) return;
    await anim(el, { translate: ['0 0', '0 24px'], opacity: [1, 0] }, 200, 'ease-out').finished.catch(() => {});
    el.remove();
  };
  if (undo) el.lastChild.onclick = async () => { await undo(); gone(); };
  document.body.append(el);
  anim(el, { translate: ['0 24px', '0 0'], opacity: [0, 1] }, 200, 'ease-out');
  setTimeout(gone, undo ? 8000 : 2500);
}

/* ---------- Profiles: a click on the header's picture or group bubble ---------- */

// side-panel template: the sheet slides in from the right over the conversation, its content fading in after it.
// A person shows what each app knows of them; a group, its description and members, each opening their own profile.
const profile = { box: $('#profile'), sheet: $('#profile .sheet'), body: $('#profile .body'), stack: [], seq: 0, cache: {}, members: [] };
const DETAILS = p => [['Name', p.fullName], ['Username', p.username && '@' + p.username.replace(/^@/, '')], ['Phone', p.phoneNumber], ['Email', p.email]].filter(([, v]) => v);
const personOf = pid => pid && [...state.byId.values()].find(i => i.kind === 'person' && i.chats.some(c => c.pid === pid));
const appHead = (c, extra = '') => `<h3>${netMark(netOf(c))}<span>${NETS[netOf(c)].label}</span>${extra}</h3>`;
const line = ([label, value]) => `<div class="line"><span>${label}</span><b>${esc(value)}</b></div>`;

function openProfile(item) {
  if (!item) return;
  const opening = profile.box.hidden || profile.closing;
  profile.closing = false;
  profile.stack = [];
  profile.cache = {};
  profile.box.hidden = false;
  if (opening) {
    [profile.box, profile.sheet].forEach(el => el.getAnimations().forEach(a => a.cancel()));
    anim(profile.box, { opacity: [0, 1] }, 200);
    anim(profile.sheet, { transform: ['translateX(100%)', 'none'] }, 220, 'cubic-bezier(.2, .8, .2, 1)');
  }
  showProfile(item, opening ? 120 : 0);
}
function closeProfile() {
  if (profile.box.hidden || profile.closing) return;
  profile.closing = true;
  const done = () => { if (profile.closing) { profile.box.hidden = true; profile.closing = false; } };
  anim(profile.sheet, { transform: ['none', 'translateX(100%)'] }, 180, 'ease-in').effect.updateTiming({ fill: 'forwards' });
  const a = anim(profile.box, { opacity: [1, 0] }, 180);
  a.effect.updateTiming({ fill: 'forwards' });
  a.finished.then(done, done);
}

// The head shows at once; what the apps know comes after one call per chat, its box growing into place.
async function showProfile(view, delay = 0) {
  const seq = ++profile.seq;
  profile.view = view;
  const member = view.kind === 'member';
  const who = member ? { name: view.p.fullName || view.p.username || 'Unknown', imgs: view.p.imgURL ? [view.p.imgURL] : [] } : view;
  profile.body.innerHTML = (profile.stack.length ? '<button class="back">‹ Back</button>' : '')
    + `<div class="head">${avatar(who)}<h2>${esc(who.name || 'Unnamed')}</h2>${member ? `<p>On ${NETS[netOf(view.chat)].label}</p>` : view.original ? `<p>${esc(view.original)}</p>` : ''}</div>`
    + (member ? '' : `<div class="actions">${view.kind === 'person' && view.id !== state.cur?.id ? '<button class="open">Open conversation</button>' : ''}<button class="merge">Merge with…</button></div>`)
    + '<div class="details" hidden></div>';
  profile.body.scrollTop = 0;
  anim(profile.body, { opacity: [0, 1], transform: ['translateY(6px)', 'none'] }, 200).effect.updateTiming({ delay, fill: 'backwards' });
  const html = await detailsHTML(view);
  if (seq !== profile.seq) return;
  const box = profile.body.querySelector('.details');
  box.innerHTML = html;
  collapse(box, false, 260);
}

async function detailsHTML(view) {
  if (view.kind === 'member') return `<section>${appHead(view.chat)}${DETAILS(view.p).map(line).join('')}</section>`;
  const full = await Promise.all(view.chats.map(c => (profile.cache[c.id] ||= api('GET', `/v1/chats/${enc(c.id)}`).catch(() => null))));
  if (view.kind === 'person') {
    return view.chats.map((c, i) => {
      const p = full[i]?.participants?.items?.find(p => !p.isSelf) || { fullName: c.title };
      return `<section>${appHead(c)}${DETAILS(p).map(line).join('')}</section>`;
    }).join('');
  }
  profile.members = [];
  return view.chats.map((c, i) => {
    const all = full[i]?.participants?.items || [];
    const ps = all.filter(p => !p.isSelf && !p.isNetworkBot).sort((a, b) => b.isAdmin - a.isAdmin || fold(a.fullName).localeCompare(fold(b.fullName)));
    const total = full[i]?.participants?.total ?? all.length;
    const rows = ps.map(p => {
      const known = personOf(p.id);
      profile.members.push({ kind: 'member', p, chat: c });
      return `<button class="member" data-i="${profile.members.length - 1}">${avatar(known || { name: p.fullName, imgs: p.imgURL ? [p.imgURL] : [] })}<span><b>${esc(known?.name || p.fullName || p.username || 'Unknown')}</b><small>${esc(p.username ? '@' + p.username.replace(/^@/, '') : p.phoneNumber || '')}</small></span>${p.isAdmin ? '<i>Admin</i>' : ''}</button>`;
    });
    return `<section>${appHead(c, `<small>${total} members</small>`)}${full[i]?.description ? `<p class="desc">${linkify(full[i].description)}</p>` : ''}<div class="members">${rows.join('')}</div>`
      + (total > all.length ? `<p class="more-members">and ${total - all.length} more</p>` : '') + '</section>';
  }).join('');
}

profile.box.addEventListener('click', e => {
  if (e.target === profile.box || e.target.closest('.close')) return closeProfile();
  const m = e.target.closest('.member');
  if (m) {
    const v = profile.members[+m.dataset.i];
    profile.stack.push(profile.view);
    return showProfile(personOf(v.p.id) || v);
  }
  if (e.target.closest('.back')) return showProfile(profile.stack.pop());
  const merging = e.target.closest('.merge');
  if (merging) return openMenu?._anchor === merging ? closeMenu() : menu(merging, m => mergePicker(m, profile.view));
  if (e.target.closest('.open')) select(profile.view.id);
});
addEventListener('keydown', e => { if (e.key === 'Escape' && !profile.box.hidden && !profile.closing && !openMenu) { e.preventDefault(); e.stopPropagation(); closeProfile(); } }, true);

/* ---------- Start ---------- */

// Holding the sidebar's right edge and dragging resizes it; the width is kept.
{
  const aside = $('aside'), grip = $('.resize');
  if (localStorage.asideWidth) aside.style.width = localStorage.asideWidth + 'px';
  grip.addEventListener('pointerdown', e => {
    e.preventDefault();
    grip.setPointerCapture(e.pointerId);
    grip.classList.add('held');
    const x0 = e.clientX, w0 = aside.offsetWidth;
    const move = ev => { aside.style.width = Math.round(Math.max(260, Math.min(innerWidth * 0.6, w0 + ev.clientX - x0))) + 'px'; movePill(0); };
    grip.addEventListener('pointermove', move);
    grip.addEventListener('pointerup', () => {
      grip.removeEventListener('pointermove', move);
      grip.classList.remove('held');
      localStorage.asideWidth = aside.offsetWidth;
      if (!state.more) showLists();
    }, { once: true });
  });
}
addEventListener('resize', () => { if (!state.more) showLists(); movePill(0); });
// ponytail: polling every 3 s / 10 s; switch to the /v1/ws event stream if it ever feels late or heavy.
setInterval(pollThread, 3000);
setInterval(refreshList, 10000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) { refreshList(); pollThread(); } });
invoke('overrides').then(o => {
  state.pictures = o.pictures;
  state.openAtLaunch = o.openAtLaunch;
  refreshList();
});

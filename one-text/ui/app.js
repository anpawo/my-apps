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
  matrix: { label: 'Matrix', color: '#1d1d1f', cmd: 'mx', logo: svg('M.632.55v22.9H2.28V24H0V0h2.28v.55zm7.043 7.26v1.157h.033c.309-.443.683-.784 1.117-1.024.433-.245.936-.365 1.5-.365.54 0 1.033.107 1.481.314.448.208.785.582 1.02 1.108.254-.374.6-.706 1.034-.992.434-.287.95-.43 1.546-.43.453 0 .872.056 1.26.167.388.11.716.286.993.53.276.245.489.559.646.951.152.392.23.863.23 1.417v5.728h-2.349V11.52c0-.286-.01-.559-.032-.812a1.755 1.755 0 0 0-.18-.66 1.106 1.106 0 0 0-.438-.448c-.194-.11-.457-.166-.785-.166-.332 0-.6.064-.803.189a1.38 1.38 0 0 0-.48.499 1.946 1.946 0 0 0-.231.696 5.560 5.560 0 0 0-.06.785v4.768h-2.35v-4.8c0-.254-.004-.503-.018-.752a2.074 2.074 0 0 0-.143-.688 1.052 1.052 0 0 0-.415-.503c-.194-.125-.476-.19-.854-.19-.111 0-.259.024-.439.074-.18.051-.36.143-.53.282-.171.138-.319.337-.439.595-.12.259-.18.6-.18 1.020v4.966H5.46V7.81zm15.693 15.64V.55H21.72V0H24v24h-2.28v-.55z') },
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
  const open = { height: h + 'px', opacity: 1, paddingTop: cs.paddingTop, paddingBottom: cs.paddingBottom };
  const shut = { height: '0px', opacity: 0, paddingTop: '0px', paddingBottom: '0px' };
  el.style.overflow = 'hidden';
  const a = (el._anim = anim(el, Object.fromEntries(Object.keys(open).map(k => [k, hide ? [open[k], shut[k]] : [shut[k], open[k]]])), ms));
  return a.finished
    .then(() => { el._anim = null; el.style.overflow = ''; el.hidden = hide; })
    .catch(() => {});
}

const esc = s => String(s ?? '').replace(/[&<>"']/g, c => `&#${c.charCodeAt(0)};`);
const linkify = s => esc(s).replace(/https?:\/\/[^\s<]+/g, u => `<a href="${u}" target="_blank" rel="noreferrer">${u}</a>`);
const asset = url => url.startsWith('data:') ? url : `beeper://localhost/asset?url=${enc(url)}`;
const netMark = key => { const n = NETS[key]; return `<span class="net" style="background:${n.color}" title="${n.label}">${n.logo}</span>`; };
function hue(s) { let h = 0; for (const c of s) h = (h * 31 + c.charCodeAt(0)) % 360; return h; }
// Each picture in turn (Instagram's default comes back 404), the initials only once none loads.
function avatar(item) {
  const initials = (item.name || '?').split(/\s+/).filter(Boolean).slice(0, 2).map(w => [...w][0]).join('').toUpperCase();
  const color = `hsl(${hue(item.name || '')} 55% 62%)`;
  const faces = item.imgs?.length ? [] : item.faces || [];
  // A small group with no picture: its members' pictures side by side.
  if (faces.length > 1) return `<div class="av faces">${faces.map(f => `<img src="${esc(asset(f))}" onerror="this.onerror=null;this.src='data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22/%3E'">`).join('')}</div>`;
  const [first, ...rest] = faces.length ? faces : item.imgs || [];
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

const state = { byId: new Map(), cur: null, seq: 0, msgs: [], target: null, favs: new Set(JSON.parse(localStorage.favs || '[]')) };

/* ---------- Sidebar ---------- */

function fill(n, item) {
  const sig = JSON.stringify([item.name, item.imgs, item.faces, item.unread, item.last]);
  if (n._sig === sig) return;
  const wasUnread = n._unread || 0;
  n._sig = sig;
  n._unread = item.unread;
  n.classList.toggle('unread', item.unread > 0);
  n.innerHTML = `${avatar(item)}<div class="body"><div class="top"><span class="name">${esc(item.name || 'Unnamed')}</span><span class="time">${when(item.last)}</span></div>
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
      n.onclick = () => select(n.dataset.id);
      n.oncontextmenu = e => { e.preventDefault(); select(n.dataset.id); openMore(n); };
    }
    fill(n, item);
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
  state.more = Math.max(state.more || 0, fits()) * 2;
  showLists();
}, { passive: true });
// A favorite is kept by its chats' ids, so it stays one after a merge or a split changes the person's id.
const isFav = item => item.chats.some(c => state.favs.has(c.id));
function toggleFav(item) {
  const on = !isFav(item);
  for (const c of item.chats) on ? state.favs.add(c.id) : state.favs.delete(c.id);
  localStorage.favs = JSON.stringify([...state.favs]);
  showLists();
}
// Favorites keep the order he gives them (⌘ + arrows), new ones last.
const favRank = item => Math.min(...item.chats.map(c => [...state.favs].indexOf(c.id)).filter(n => n >= 0));
function moveFav(item, key) {
  const favs = (state.all || []).filter(isFav).sort((a, b) => favRank(a) - favRank(b));
  const same = favs.filter(i => (i.kind === 'group') === (item.kind === 'group'));
  const step = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: item.kind === 'group' ? -1 : -5, ArrowDown: item.kind === 'group' ? 1 : 5 }[key];
  const from = same.indexOf(item), to = Math.max(0, Math.min(same.length - 1, from + step));
  if (from < 0 || to === from) return;
  same.splice(to, 0, ...same.splice(from, 1));
  const order = [...same, ...favs.filter(i => !same.includes(i))].flatMap(i => i.chats.map(c => c.id)).filter(id => state.favs.has(id));
  state.favs = new Set([...order, ...state.favs]);
  localStorage.favs = JSON.stringify([...state.favs]);
  showLists();
}
function showLists() {
  const all = state.all || [];
  // Pinned groups keep their row (name and members), under the favorites' pictures.
  const favs = all.filter(isFav).sort((a, b) => favRank(a) - favRank(b));
  drawFavs(favs.filter(i => i.kind !== 'group'));
  renderList($('#pinned'), favs.filter(i => i.kind === 'group'));
  $('#pinned').classList.toggle('some', favs.some(i => i.kind === 'group'));
  renderList($('#people'), shown(all));
  movePill();
}
// Favorites: their pictures in a strip above the list, in his order; a dot when unread.
function drawFavs(items) {
  const box = $('#favs');
  const was = new Map([...box.children].map(b => [b.dataset.id, b.getBoundingClientRect()]));
  const had = new Set(was.keys());
  box.hidden = !items.length;
  box.innerHTML = items.map(i => `<button class="fav${i.id === state.cur?.id ? ' on' : ''}${i.unread ? ' unread' : ''}" data-id="${esc(i.id)}" title="${esc(i.name || 'Unnamed')}">${avatar(i)}</button>`).join('');
  box.querySelectorAll('.fav').forEach(b => {
    b.onclick = () => select(b.dataset.id);
    b.oncontextmenu = e => { e.preventDefault(); select(b.dataset.id); openMore(b); };
    if (had.size && !had.has(b.dataset.id)) anim(b, { scale: [0.5, 1], opacity: [0, 1] }, 260);
    const old = was.get(b.dataset.id), now = b.getBoundingClientRect();
    if (old && (old.left !== now.left || old.top !== now.top)) anim(b, { translate: [`${old.left - now.left}px ${old.top - now.top}px`, '0 0'] }, 260);
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
  const items = (q ? all.filter(i => (i.name || '').toLowerCase().includes(q)) : all).slice(0, q || net ? 30 : 8);
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
    if (state.cur) {
      // A merge or a split gives the person a new id: follow the chat we had open.
      const first = state.cur.chats[0].id;
      const now = state.byId.get(state.cur.id) || [...state.byId.values()].find(i => i.chats.some(c => c.id === first));
      if (now) { const changed = now.id !== state.cur.id || now.chats.length !== state.cur.chats.length; state.cur = now; if (changed) drawHeader(); }
    }
    requestAnimationFrame(() => movePill(300));
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
  // ⌘ + arrows move the favorite under the pointer, or the open one when no text is being edited.
  if (e.metaKey && e.key.startsWith('Arrow')) {
    const hover = document.querySelector('.fav:hover, #pinned .row:hover');
    const typing = /^(INPUT|TEXTAREA)$/.test(document.activeElement?.tagName) && document.activeElement.value;
    const item = hover ? state.byId.get(hover.dataset.id) : !typing && state.cur && isFav(state.cur) ? state.cur : null;
    if (item) { e.preventDefault(); moveFav(item, e.key); }
  }
});
/* ---------- Conversation ---------- */

async function select(id) {
  const item = state.byId.get(id);
  if (!item || item === state.cur) return;
  state.cur = item;
  state.target = null;
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
  drawThread(true);
  fade?.cancel();
  pickTarget();
  markRead(item);
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
const SHARE = /https:\/\/www\.instagram\.com\/(?:reels?|p)\/[\w-]+\/?\S*/;
const PLAY = '<svg class="play" viewBox="0 0 24 24"><path d="M8 5.5v13l10.5-6.5z"/></svg>';

function bubbleHTML(m) {
  if (m.isDeleted) return `<div class="bubble note">Message deleted</div>`;
  const parts = [];
  const text = plain(m.text);
  const share = m.net === 'instagram' && text?.match(SHARE)?.[0];
  const thumb = share && (m.attachments || []).find(a => a.type === 'img' && a.srcURL);
  // A shared reel or post: its cover as a card that opens it, like Instagram's own, instead of the raw link.
  if (thumb) {
    const url = share.replace(/[?#].*$/, '');
    const rest = text.replace(share, '').trim();
    return `<a class="bubble reel" href="${esc(url)}" target="_blank" rel="noreferrer" title="${esc(url)}"><img src="${esc(asset(thumb.srcURL))}" loading="lazy">${/\/p\//.test(url) ? '' : PLAY}</a>`
      + (rest ? `<div class="bubble">${linkify(rest)}</div>` : '');
  }
  for (const a of m.attachments || []) {
    if (a.type === 'img' && a.srcURL && !a.isSticker) parts.push(`<div class="bubble media"><img src="${esc(asset(a.srcURL))}" loading="lazy"></div>`);
    else parts.push(`<div class="bubble note">${a.isVoiceNote ? 'Voice message' + (a.transcription ? `: ${esc(a.transcription)}` : '') : a.type === 'video' ? 'Video' : a.isSticker ? 'Sticker' : esc(a.fileName || 'Attachment')}</div>`);
  }
  if (text) parts.push(`<div class="bubble">${linkify(text)}</div>`);
  if (!parts.length) parts.push(`<div class="bubble note">${esc((m.type || 'event').toLowerCase())}</div>`);
  return parts.join('');
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
  row.innerHTML = `<div class="col">${showFrom ? `<div class="from">${esc(m.senderName)}</div>` : ''}${bubbleHTML(m)}</div>`;
  nodes.push(row);
  return nodes;
}

function drawThread(enter) {
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
  const box = $('#msgs');
  box.scrollTop = box.scrollHeight;
}

async function pollThread() {
  const item = state.cur;
  if (!item || document.hidden) return;
  const seq = state.seq;
  const msgs = await loadMessages(item);
  if (seq !== state.seq || !msgs.length) return;
  const known = new Set(state.msgs.map(m => m.id));
  const fresh = msgs.filter(m => !known.has(m.id));
  if (!fresh.length) return;
  const box = $('#msgs');
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 80;
  const lastKnown = state.msgs[state.msgs.length - 1]?.timestamp || '';
  if (fresh.some(m => m.timestamp < lastKnown)) {
    state.msgs = msgs;
    drawThread(false);
    return;
  }
  for (const m of fresh) {
    const pending = [...document.querySelectorAll('#thread .msg.pending')].find(p => m.isSender && p._text === m.text);
    pending?.remove();
    const nodes = msgNodes(m, state.msgs[state.msgs.length - 1]);
    state.msgs.push(m);
    for (const n of nodes) {
      $('#thread').append(n);
      if (!n.hidden) { n.hidden = true; collapse(n, false, 280); }
    }
  }
  if (atBottom) box.scrollTo({ top: box.scrollHeight, behavior: RM.matches ? 'auto' : 'smooth' });
  if (fresh.some(m => !m.isSender)) { pickTarget(true); markRead(item); }
}

// Opening a chat clears its badge here only: nothing goes to Beeper, so the sender gets no read receipt.
const seen = JSON.parse(localStorage.seen || '{}');
function applySeen(item) {
  for (const c of item.chats) if (c.unread && Date.parse(seen[c.id]) >= Date.parse(c.last)) c.unread = 0;
  item.unread = item.chats.reduce((s, c) => s + c.unread, 0);
}
function markRead(item) {
  for (const c of item.chats) {
    const newest = state.msgs.filter(m => m.chatID === c.id && !m.isSender).at(-1)?.timestamp;
    seen[c.id] = [seen[c.id], c.last, newest].filter(Boolean).sort((a, b) => Date.parse(b) - Date.parse(a))[0];
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
input.addEventListener('input', () => { command(false) || autosize(); });
input.addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); command(true) || send(); }
  if (e.key === 'Escape') { input.value = ''; autosize(); }
});
$('#send').onclick = send;
$('#send').disabled = true;

async function send() {
  const text = input.value.trim();
  if (!text || !state.target) return;
  const chat = state.target.chat;
  input.value = '';
  autosize();
  const m = { id: 'pending-' + Date.now(), text, isSender: true, net: netOf(chat), chatID: chat.id, timestamp: new Date().toISOString(), sortKey: '' };
  const [row] = msgNodes(m, state.msgs[state.msgs.length - 1]).slice(-1);
  row.classList.add('pending');
  row._text = text;
  $('#thread').append(row);
  row.hidden = true;
  collapse(row, false, 260);
  const box = $('#msgs');
  box.scrollTo({ top: box.scrollHeight, behavior: RM.matches ? 'auto' : 'smooth' });
  try {
    await api('POST', `/v1/chats/${enc(chat.id)}/messages`, { text });
    setTimeout(pollThread, 600);
  } catch (e) {
    row.classList.remove('pending');
    row.classList.add('failed');
    row.title = `Not sent: ${e}`;
  }
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
  m._up = up;
  build(m);
  document.body.append(m);
  const r = anchor.getBoundingClientRect();
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
  const m = menu(anchor, m => {
    m.append(item(isFav(person) ? 'Remove from favorites' : 'Add to favorites', { hint: '⌘F', action: () => { closeMenu(); toggleFav(person); } }));
    m.append(item('Change picture…', { action: () => { closeMenu(); pickPicture(person); } }));
    if (person.chats.some(c => state.pictures?.[c.id])) m.append(item('Remove the picture set', { action: () => { closeMenu(); setPicture(person, null); } }));
    if (person.kind !== 'person') {
      m.append(item(person.hidden ? 'Show in the list' : 'Hide from the list', { hint: person.hidden ? '' : '⌘D still finds it', action: () => { closeMenu(); hide(person, !person.hidden); } }));
      return;
    }
    m.append(sep(), item('Merge with…', { action: () => morph(m, mm => mergePicker(mm, person)) }));
    if (person.chats.length > 1) {
      m.append(sep());
      for (const c of person.chats) {
        const k = netOf(c);
        m.append(item(`Split ${NETS[k].label} off`, { hint: c.title !== person.name ? c.title : '', action: () => { closeMenu(); split(person, c); } }));
      }
    }
  }, { right: anchor.classList.contains('more') });
  return m;
}

function mergePicker(m, person) {
  const field = document.createElement('input');
  field.placeholder = `Merge ${person.name} with…`;
  const found = document.createElement('div');
  found.className = 'found';
  const draw = () => {
    const q = field.value.trim().toLowerCase();
    const others = [...state.byId.values()].filter(i => i.kind === 'person' && i.id !== person.id && (!q || (i.name || '').toLowerCase().includes(q))).slice(0, 30);
    found.replaceChildren(...others.map(o => item(o.name || 'Unnamed', { icon: avatar(o), hint: netsOf(o).map(k => NETS[k].label).join(', '), action: () => { closeMenu(); merge(person, o); } })));
    if (!others.length) found.innerHTML = '<div class="none">Nobody by that name</div>';
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

/* ---------- Start ---------- */

addEventListener('resize', () => { if (!state.more) showLists(); movePill(0); });
// ponytail: polling every 3 s / 10 s; switch to the /v1/ws event stream if it ever feels late or heavy.
setInterval(pollThread, 3000);
setInterval(refreshList, 10000);
invoke('overrides').then(o => (state.pictures = o.pictures));
document.addEventListener('visibilitychange', () => { if (!document.hidden) { refreshList(); pollThread(); } });
refreshList();

import Foundation

/// The editors' browser app: one small page served by the mini itself, with no outside
/// libraries and nothing to install. It only ever builds the page with `textContent`, never
/// as HTML, because clip names, notes and dialogue are data from the library, not trusted markup.
public enum WebApp {
    public struct Asset: Sendable {
        public var path: String
        public var contentType: String
        public var body: String
    }

    /// Everything a signed-out visitor can fetch: the app itself, which holds no library data.
    public static let assets: [String: Asset] = [
        "/": Asset(path: "/", contentType: "text/html; charset=utf-8", body: html),
        "/join": Asset(path: "/join", contentType: "text/html; charset=utf-8", body: html),
        "/app.css": Asset(path: "/app.css", contentType: "text/css; charset=utf-8", body: css),
        "/app.js": Asset(path: "/app.js", contentType: "text/javascript; charset=utf-8", body: js),
    ]

    /// Only this origin's own files, no framing, no referrer: a stolen page cannot load anything else.
    public static let securityHeaders: [(String, String)] = [
        ("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"),
        ("X-Frame-Options", "DENY"),
        ("Referrer-Policy", "no-referrer"),
        ("X-Content-Type-Options", "nosniff"),
        ("Cache-Control", "no-cache"),
    ]

    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>StradaXR A.I. MAM</title>
<link rel="stylesheet" href="/app.css">
</head>
<body>
<div id="app"></div>
<script src="/app.js"></script>
</body>
</html>
"""#

    static let css = #"""
:root { color-scheme: dark; --bg:#1c1c1e; --panel:#262628; --line:#3a3a3d; --text:#f2f2f4; --dim:#9a9aa1; --accent:#0a84ff; --bad:#ff6b6b; --ok:#5fd38d; }
* { box-sizing: border-box; }
html, body { margin:0; height:100%; background:var(--bg); color:var(--text); font:14px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
button, input, select { font:inherit; color:inherit; }
button { background:#3a3a3d; border:0; border-radius:6px; padding:6px 12px; cursor:pointer; }
button:hover { background:#48484c; }
button.primary { background:var(--accent); }
button:disabled { opacity:.5; cursor:default; }
input, select { background:#2f2f32; border:1px solid var(--line); border-radius:6px; padding:6px 8px; }
.layout { display:grid; grid-template-columns:220px minmax(320px,1fr) minmax(360px,44%); grid-template-rows:auto 1fr; height:100vh; }
.top { grid-column:1/-1; display:flex; gap:12px; align-items:center; padding:10px 14px; border-bottom:1px solid var(--line); background:var(--panel); }
.top .title { font-weight:600; margin-right:8px; }
.top .grow { flex:1; }
.top input[type=search] { width:min(380px,40vw); }
.who { color:var(--dim); }
.side { border-right:1px solid var(--line); overflow:auto; padding:10px 6px; }
.side h3 { margin:6px 10px; font-size:11px; letter-spacing:.06em; text-transform:uppercase; color:var(--dim); }
.side .item { display:flex; justify-content:space-between; padding:6px 10px; border-radius:6px; cursor:pointer; }
.side .item:hover { background:#2f2f32; }
.side .item.on { background:var(--accent); }
.side .count { color:var(--dim); } .side .item.on .count { color:#d6e8ff; }
.main { overflow:auto; }
table { width:100%; border-collapse:collapse; }
th, td { text-align:left; padding:7px 10px; border-bottom:1px solid var(--line); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; max-width:260px; }
th { position:sticky; top:0; background:var(--bg); color:var(--dim); font-weight:500; font-size:12px; }
tbody tr { cursor:pointer; } tbody tr:hover { background:#242426; } tbody tr.on { background:#17304f; }
.dim { color:var(--dim); } .bad { color:var(--bad); } .ok { color:var(--ok); }
.empty { padding:40px; text-align:center; color:var(--dim); }
.detail { border-left:1px solid var(--line); overflow:auto; padding:14px; }
.detail h2 { margin:0 0 4px; font-size:16px; }
video { width:100%; background:#000; border-radius:8px; max-height:50vh; }
.tc { font:600 22px ui-monospace, Menlo, monospace; margin:8px 0 2px; }
.row { display:flex; gap:8px; align-items:center; flex-wrap:wrap; margin:8px 0; }
.status { margin:8px 0; color:var(--dim); }
dl { display:grid; grid-template-columns:110px 1fr; gap:4px 10px; margin:12px 0; } dt { color:var(--dim); } dd { margin:0; overflow-wrap:anywhere; }
.seg { display:flex; gap:10px; padding:4px 6px; border-radius:5px; cursor:pointer; } .seg:hover { background:#2f2f32; }
.seg .t { color:var(--accent); font-family:ui-monospace, Menlo, monospace; flex:none; }
.seg mark { background:#665500; color:inherit; border-radius:2px; }
.chip { display:inline-block; background:#303034; border-radius:10px; padding:2px 8px; margin:2px 4px 2px 0; font-size:12px; }
.modal { position:fixed; inset:0; background:rgba(0,0,0,.6); display:flex; align-items:center; justify-content:center; }
.card { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:22px; width:min(440px,92vw); }
.card h2 { margin-top:0; }
.signin { max-width:460px; margin:18vh auto; padding:0 20px; text-align:center; }
@media (max-width:1100px) {
  html, body { height:auto; }
  .layout { align-content:start; grid-template-columns:180px 1fr; grid-template-rows:auto minmax(220px,42vh) auto; height:auto; min-height:100vh; }
  .top { flex-wrap:wrap; }
  .side { grid-row:2; } .main { grid-row:2; grid-column:2; }
  .detail { grid-column:1/-1; border-left:0; border-top:1px solid var(--line); }
}
@media (max-width:640px) { .layout { grid-template-columns:1fr; grid-template-rows:auto auto minmax(220px,40vh) auto; } .side { grid-row:2; max-height:150px; border-right:0; border-bottom:1px solid var(--line); } .main { grid-row:3; grid-column:1; } }
"""#

    static let js = #"""
(() => {
'use strict';
const app = document.getElementById('app');

// ---- small helpers -------------------------------------------------------
function h(tag, props, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (k === 'class') e.className = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (v !== false && v != null) e.setAttribute(k, v);
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) e.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  return e;
}
const pad = n => String(n).padStart(2, '0');
const sleep = ms => new Promise(r => setTimeout(r, ms));
function bytes(n) { const u = ['B','KB','MB','GB','TB']; let i = 0; while (n >= 1000 && i < 4) { n /= 1000; i++; } return (i ? n.toFixed(n < 10 ? 1 : 0) : n) + ' ' + u[i]; }
function clock(s) { s = Math.max(0, s); return pad(Math.floor(s / 3600)) + ':' + pad(Math.floor(s / 60) % 60) + ':' + pad(Math.floor(s) % 60); }
class AuthError extends Error {}

// Frame count to SMPTE timecode, with drop-frame for 29.97 / 59.94 (the same arithmetic the app uses).
function timecode(frames, num, den, drop) {
  const fps = Math.round(num / den);
  let n = Math.max(0, Math.round(frames));
  if (drop && (fps === 30 || fps === 60)) {
    const d = fps === 30 ? 2 : 4, per10 = fps * 600 - d * 9, perMin = fps * 60 - d;
    const tens = Math.floor(n / per10), rest = n % per10;
    n += 9 * d * tens + (rest > d ? d * Math.floor((rest - d) / perMin) : 0);
  }
  const f = n % fps, s = Math.floor(n / fps) % 60, m = Math.floor(n / fps / 60) % 60, hr = Math.floor(n / fps / 3600) % 24;
  return pad(hr) + ':' + pad(m) + ':' + pad(s) + (drop ? ';' : ':') + pad(f);
}
window.__stradaxrTimecode = timecode;

async function api(path, options = {}) {
  const res = await fetch(path, { credentials: 'same-origin', ...options, headers: { 'X-StradaXR': '1', ...(options.headers || {}) } });
  if (res.status === 401) throw new AuthError();
  return res;
}
async function json(path, options) {
  const res = await api(path, options);
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || ('Error ' + res.status));
  return res.json();
}

// ---- state ---------------------------------------------------------------
const state = { me: null, bins: [], binId: '', day: '', q: '', page: null, selected: null, detail: null, sortDown: false };

// ---- sign in -------------------------------------------------------------
async function start() {
  const token = location.hash.length > 1 ? decodeURIComponent(location.hash.slice(1)) : '';
  if (token) {
    // The invite's token travels in the part of the address that is never sent to the server.
    // Swap it for a cookie the page cannot read, and take it out of the address bar.
    try {
      const res = await fetch('/v1/session', { method: 'POST', headers: { Authorization: 'Bearer ' + token, 'X-StradaXR': '1' }, credentials: 'same-origin' });
      history.replaceState(null, '', '/');
      if (!res.ok) return signedOut(res.status === 401 ? 'This invite is not valid any more. Ask for a new one.' : 'Could not sign in.');
    } catch (e) { return signedOut('Could not reach the server.'); }
  }
  try { state.me = await json('/v1/me'); } catch (e) { return signedOut(); }
  if (!state.me.initials) await askInitials();
  await loadBins();
  buildLayout();
  await loadClips();
}

function signedOut(message) {
  app.replaceChildren(h('div', { class: 'signin' },
    h('h2', {}, 'StradaXR A.I. MAM'),
    h('p', { class: 'dim' }, message || 'Open the invite link you were sent to sign in.')));
}

function askInitials() {
  return new Promise(resolve => {
    const input = h('input', { maxlength: '4', placeholder: 'e.g. MR', autocomplete: 'off', style: 'text-transform:uppercase;width:120px' });
    const error = h('div', { class: 'bad' });
    const go = h('button', { class: 'primary', onclick: async () => {
      try {
        state.me = await json('/v1/me/initials?value=' + encodeURIComponent(input.value), { method: 'POST' });
        modal.remove(); resolve();
      } catch (e) { error.textContent = e.message; }
    } }, 'Lock in initials');
    const modal = h('div', { class: 'modal' }, h('div', { class: 'card' },
      h('h2', {}, 'Choose your initials'),
      h('p', { class: 'dim' }, 'Two to four letters. They are locked to you now and name you in the activity log. Only the owner can change them.'),
      h('div', { class: 'row' }, input, go), error));
    input.addEventListener('keydown', e => { if (e.key === 'Enter') go.click(); });
    document.body.append(modal); input.focus();
  });
}

// ---- layout --------------------------------------------------------------
let searchTimer;
function buildLayout() {
  const search = h('input', { type: 'search', placeholder: 'Search names, dialogue, tags, people…', oninput: e => {
    clearTimeout(searchTimer); searchTimer = setTimeout(() => { state.q = e.target.value.trim(); loadClips(); }, 250);
  } });
  const day = h('input', { type: 'date', title: 'Shoot day', onchange: e => { state.day = e.target.value; loadClips(); } });
  app.replaceChildren(h('div', { class: 'layout' },
    h('div', { class: 'top' }, h('span', { class: 'title' }, 'StradaXR A.I. MAM'), search, day, h('span', { class: 'grow' }),
      h('span', { class: 'who' }, state.me.name + (state.me.initials ? ' · ' + state.me.initials : '')),
      h('button', { onclick: signOut }, 'Sign out')),
    h('div', { class: 'side', id: 'side' }),
    h('div', { class: 'main', id: 'main' }),
    h('div', { class: 'detail', id: 'detail' }, h('div', { class: 'empty' }, 'Choose a clip.'))));
  drawBins();
}

async function signOut() {
  await fetch('/v1/session/end', { method: 'POST', headers: { 'X-StradaXR': '1' }, credentials: 'same-origin' });
  state.me = null; signedOut('You are signed out.');
}

// ---- bins ----------------------------------------------------------------
async function loadBins() { try { state.bins = await json('/v1/bins'); } catch (e) { state.bins = []; } }
function drawBins() {
  const side = document.getElementById('side');
  const children = id => state.bins.filter(b => (b.parentID || '') === id);
  const rows = [];
  const item = (label, id, count, depth) => h('div', { class: 'item' + (state.binId === id ? ' on' : ''), style: 'padding-left:' + (10 + depth * 14) + 'px', onclick: () => { state.binId = id; drawBins(); loadClips(); } },
    h('span', {}, label), count == null ? '' : h('span', { class: 'count' }, count));
  rows.push(h('h3', {}, 'Library'), item('All clips', '', null, 0), h('h3', {}, 'Bins'));
  const walk = (parent, depth) => children(parent).forEach(b => { rows.push(item((b.isSmart ? '◎ ' : '') + b.name, b.id, b.count, depth)); walk(b.id, depth + 1); });
  walk('', 0);
  side.replaceChildren(...rows);
}

// ---- clip table ----------------------------------------------------------
async function loadClips() {
  const main = document.getElementById('main');
  const params = new URLSearchParams({ limit: '500' });
  if (state.q) params.set('q', state.q);
  if (state.binId) params.set('bin', state.binId);
  if (state.day) { params.set('day', state.day); params.set('utcOffset', String(-new Date().getTimezoneOffset())); }
  try { state.page = await json('/v1/assets?' + params); }
  catch (e) { if (e instanceof AuthError) return signedOut('Your session ended. Open your invite link again.'); main.replaceChildren(h('div', { class: 'empty bad' }, e.message)); return; }
  drawClips();
}

function drawClips() {
  const main = document.getElementById('main');
  const page = state.page;
  if (!page.items.length) { main.replaceChildren(h('div', { class: 'empty' }, state.q || state.day || state.binId ? 'No clips match.' : 'No clips yet.')); return; }
  const head = ['Name', 'Reel', 'Picture', 'Duration', 'Start timecode', 'Proxy', 'Notes'];
  const rows = page.items.map(a => h('tr', { class: state.selected === a.id ? 'on' : '', onclick: () => openClip(a.id) },
    h('td', { title: a.fileName }, a.fileName), h('td', {}, a.reelName || '—'),
    h('td', {}, a.width + '×' + a.height + ' ' + fps(a)), h('td', {}, clock(a.durationSeconds)), h('td', {}, a.startTimecode),
    h('td', { class: a.proxy ? 'ok' : 'dim' }, a.proxy ? bytes(a.proxy.bytes) : 'none yet'), h('td', { class: 'dim', title: a.notes }, a.notes)));
  main.replaceChildren(h('table', {}, h('thead', {}, h('tr', {}, head.map(t => h('th', {}, t)))), h('tbody', {}, rows)),
    page.total > page.items.length ? h('div', { class: 'empty' }, 'Showing ' + page.items.length + ' of ' + page.total + '. Narrow the search to see the rest.') : '');
}
const fps = a => { const v = a.frameRateNum / a.frameRateDen; return (Math.abs(v - Math.round(v)) < 0.001 ? Math.round(v) : v.toFixed(3)) + 'p'; };

// ---- clip detail and player ----------------------------------------------
async function openClip(id) {
  state.selected = id; drawClips();
  const box = document.getElementById('detail');
  box.replaceChildren(h('div', { class: 'empty' }, 'Loading…'));
  let d;
  try { d = await json('/v1/assets/' + encodeURIComponent(id)); } catch (e) { box.replaceChildren(h('div', { class: 'empty bad' }, e.message)); return; }
  state.detail = d;
  const a = d.asset;
  const video = h('video', { controls: '', preload: 'metadata', playsinline: '' });
  const tc = h('div', { class: 'tc' }, a.startTimecode);
  const status = h('div', { class: 'status' });
  const update = () => { tc.textContent = timecode(a.startTimecodeFrames + Math.round(video.currentTime * a.frameRateNum / a.frameRateDen), a.frameRateNum, a.frameRateDen, a.dropFrame); };
  video.addEventListener('timeupdate', update); video.addEventListener('seeked', update);
  const seek = t => { video.currentTime = t; video.play().catch(() => {}); };
  const query = state.q.toLowerCase();

  const hit = s => query && s.text.toLowerCase().includes(query);
  const transcript = d.transcript.map(s => h('div', { class: 'seg', onclick: () => seek(s.startSeconds) },
    h('span', { class: 't' }, clock(s.startSeconds)), h('span', {}, highlight(s.text, query))));
  const markers = d.markers.map(m => h('div', { class: 'seg', onclick: () => seek(m.inFrame * a.frameRateDen / a.frameRateNum) },
    h('span', { class: 't' }, timecode(a.startTimecodeFrames + m.inFrame, a.frameRateNum, a.frameRateDen, a.dropFrame)), h('span', {}, [m.name, m.note].filter(Boolean).join(' — '))));
  const tags = d.tags.filter(t => t.kind !== 'shot').reduce((m, t) => m.set(t.label, t), new Map());

  const dl = h('button', { disabled: !a.proxy, onclick: async () => {
    status.textContent = 'Preparing your copy…';
    if (await ready(a.proxy.id, status)) { const link = h('a', { href: '/v1/proxies/' + a.proxy.id, download: a.proxy.fileName }); document.body.append(link); link.click(); link.remove(); status.textContent = 'Downloading ' + a.proxy.fileName; }
  } }, a.proxy ? 'Download proxy (' + bytes(a.proxy.bytes) + ')' : 'No proxy yet');

  box.replaceChildren(...[h('h2', {}, a.fileName), h('div', { class: 'dim' }, a.formatName + ' · ' + a.width + '×' + a.height + ' ' + fps(a) + ' · ' + clock(a.durationSeconds)),
    video, tc, status, h('div', { class: 'row' }, dl),
    h('dl', {}, dt('Reel', a.reelName || '—'), dt('Start timecode', a.startTimecode + (a.dropFrame ? ' DF' : '')), dt('Audio', a.audioChannels + ' channels'),
      dt('Original', bytes(a.originalBytes)), a.proxy ? dt('Proxy', a.proxy.megabitsPerSecond ? a.proxy.megabitsPerSecond.toFixed(1) + ' Mbps' : '') : ''),
    a.notes ? h('p', {}, a.notes) : null, tags.size ? h('div', {}, [...tags.keys()].slice(0, 60).map(l => h('span', { class: 'chip' }, l))) : null,
    markers.length ? h('h3', {}, 'Markers') : null, markers, transcript.length ? h('h3', {}, 'Dialogue') : null, transcript].flat().filter(Boolean));

  if (a.proxy) {
    keys.video = video; keys.asset = a;
    status.textContent = 'Preparing your copy…';
    if (await ready(a.proxy.id, status)) {
      video.src = '/v1/proxies/' + a.proxy.id; status.textContent = '';
      const first = d.transcript.find(hit); if (first) video.addEventListener('loadedmetadata', () => { video.currentTime = first.startSeconds; }, { once: true });
    }
  } else status.textContent = 'This clip has no proxy yet.';
}
const dt = (k, v) => [h('dt', {}, k), h('dd', {}, v)];
function highlight(text, q) {
  if (!q) return text;
  const i = text.toLowerCase().indexOf(q); if (i < 0) return text;
  return [text.slice(0, i), h('mark', {}, text.slice(i, i + q.length)), text.slice(i + q.length)];
}

// The mini makes each editor's marked copy the first time it is asked for; wait until it is ready.
async function ready(proxyId, status) {
  for (let tries = 0; tries < 360; tries++) {
    let res;
    try { res = await api('/v1/proxies/' + proxyId, { method: 'HEAD' }); } catch (e) { status.textContent = 'Your session ended. Open your invite link again.'; return false; }
    if (res.status === 200) return true;
    if (res.status === 202) { status.textContent = 'Preparing your copy… this takes a moment the first time.'; await sleep(5000); continue; }
    if (res.status === 428) { await askInitials(); continue; }
    status.textContent = res.status === 503 ? 'Could not prepare this copy. Try again in a minute.' : 'This proxy is not available (' + res.status + ').';
    return false;
  }
  status.textContent = 'Still preparing. Check back shortly.'; return false;
}

// ---- keys: space, J K L, frame step ----------------------------------------
const keys = { video: null, asset: null, rate: 1 };
document.addEventListener('keydown', e => {
  const v = keys.video, a = keys.asset;
  if (!v || !a || e.target.matches('input, textarea, select') || e.metaKey || e.ctrlKey || e.altKey) return;
  const frame = a.frameRateDen / a.frameRateNum;
  if (e.key === ' ' || e.key === 'k') { e.preventDefault(); if (e.key === ' ' && v.paused) v.play(); else v.pause(); keys.rate = 1; v.playbackRate = 1; }
  else if (e.key === 'l') { keys.rate = v.paused ? 1 : Math.min(keys.rate * 2, 8); v.playbackRate = keys.rate; v.play(); }
  else if (e.key === 'j') { v.pause(); v.currentTime = Math.max(0, v.currentTime - frame * 10); }
  else if (e.key === 'ArrowRight') { e.preventDefault(); v.pause(); v.currentTime += frame * (e.shiftKey ? 10 : 1); }
  else if (e.key === 'ArrowLeft') { e.preventDefault(); v.pause(); v.currentTime = Math.max(0, v.currentTime - frame * (e.shiftKey ? 10 : 1)); }
});

start();
})();
"""#
}

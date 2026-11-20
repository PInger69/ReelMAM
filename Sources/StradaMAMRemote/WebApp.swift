// Apple platforms only: this code is built on CryptoKit, Network and Security.
#if canImport(CryptoKit) && canImport(Network)
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
/* Laid out like a Mac window: sidebar, toolbar, list, inspector. System type and colours, light and dark. */
:root {
  color-scheme: light;
  --window:#ffffff; --sidebar:#f1f0ef; --toolbar:#fbfbfb; --inspector:#f7f7f7; --stripe:#f5f5f5;
  --text:#1d1d1f; --secondary:#6e6e73; --tertiary:#a1a1a6; --separator:#dcdcdc;
  --accent:#007aff; --on-accent:#ffffff; --hover:rgba(0,0,0,.05); --sidebar-on:rgba(0,0,0,.09);
  --control:#ffffff; --control-edge:rgba(0,0,0,.16); --field:rgba(0,0,0,.06);
  --bad:#d70015; --ok:#248a3d; --mark:#ffe58a; --focus:rgba(0,122,255,.45);
  --sheet-shade:rgba(0,0,0,.25); --shadow:0 18px 50px rgba(0,0,0,.28);
}
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
  color-scheme: dark;
  --window:#1e1e1e; --sidebar:#2a2a2c; --toolbar:#262626; --inspector:#242424; --stripe:#242424;
  --text:#e8e8ea; --secondary:#98989d; --tertiary:#636366; --separator:#3a3a3c;
  --accent:#0a84ff; --on-accent:#ffffff; --hover:rgba(255,255,255,.06); --sidebar-on:rgba(255,255,255,.12);
  --control:#636366; --control-edge:rgba(255,255,255,.08); --field:rgba(255,255,255,.08);
  --bad:#ff6961; --ok:#30d158; --mark:#6b5a00; --focus:rgba(10,132,255,.55);
  --sheet-shade:rgba(0,0,0,.5); --shadow:0 18px 50px rgba(0,0,0,.6);
} }
:root[data-theme="dark"] {
  color-scheme: dark;
  --window:#1e1e1e; --sidebar:#2a2a2c; --toolbar:#262626; --inspector:#242424; --stripe:#242424;
  --text:#e8e8ea; --secondary:#98989d; --tertiary:#636366; --separator:#3a3a3c;
  --accent:#0a84ff; --on-accent:#ffffff; --hover:rgba(255,255,255,.06); --sidebar-on:rgba(255,255,255,.12);
  --control:#636366; --control-edge:rgba(255,255,255,.08); --field:rgba(255,255,255,.08);
  --bad:#ff6961; --ok:#30d158; --mark:#6b5a00; --focus:rgba(10,132,255,.55);
  --sheet-shade:rgba(0,0,0,.5); --shadow:0 18px 50px rgba(0,0,0,.6);
}
* { box-sizing:border-box; }
html, body { margin:0; height:100%; background:var(--window); color:var(--text);
  font:13px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif;
  -webkit-font-smoothing:antialiased; }
h1, h2, h3, p { margin:0; }
button, input { font:inherit; color:inherit; }
:focus-visible { outline:3px solid var(--focus); outline-offset:1px; }

/* Push buttons and fields */
button { height:24px; padding:0 11px; border-radius:6px; border:0; background:var(--control); cursor:default;
  box-shadow:0 0 0 .5px var(--control-edge), 0 1px 1.5px rgba(0,0,0,.14); white-space:nowrap; }
button:active { filter:brightness(.93); }
button.primary { background:var(--accent); color:var(--on-accent); font-weight:500; }
button:disabled { opacity:.45; }
button.large { height:30px; padding:0 14px; }
input { height:28px; border:0; border-radius:7px; background:var(--field); padding:0 8px; min-width:0; }
input::placeholder { color:var(--secondary); }
input.initials { width:120px; text-transform:uppercase; }
.search { position:relative; flex:0 1 260px; min-width:120px; }
.search input { width:100%; padding-left:27px; }
.search::before { content:""; position:absolute; left:8px; top:7px; width:14px; height:14px; background:var(--secondary);
  -webkit-mask:var(--i-search) center/contain no-repeat; mask:var(--i-search) center/contain no-repeat; }

/* Icons: drawn as masks so they take the text colour */
:root {
  --i-search:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16' fill='none' stroke='black' stroke-width='1.6' stroke-linecap='round'%3E%3Ccircle cx='7' cy='7' r='4.5'/%3E%3Cpath d='M10.5 10.5 14 14'/%3E%3C/svg%3E");
  --i-film:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16' fill='none' stroke='black' stroke-width='1.3'%3E%3Crect x='1.5' y='2.5' width='13' height='11' rx='2'/%3E%3Cpath d='M4.5 2.5v11M11.5 2.5v11M1.5 6h3M1.5 10h3M11.5 6h3M11.5 10h3'/%3E%3C/svg%3E");
  --i-folder:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16' fill='none' stroke='black' stroke-width='1.3' stroke-linejoin='round'%3E%3Cpath d='M1.5 4.5a1.5 1.5 0 0 1 1.5-1.5h3l1.5 1.5H13a1.5 1.5 0 0 1 1.5 1.5v5.5A1.5 1.5 0 0 1 13 13H3a1.5 1.5 0 0 1-1.5-1.5z'/%3E%3C/svg%3E");
  --i-smart:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16' fill='none' stroke='black' stroke-width='1.3' stroke-linecap='round'%3E%3Ccircle cx='8' cy='8' r='2.2'/%3E%3Cpath d='M8 1.8v2M8 12.2v2M1.8 8h2M12.2 8h2M3.6 3.6l1.4 1.4M11 11l1.4 1.4M3.6 12.4 5 11M11 5l1.4-1.4'/%3E%3C/svg%3E");
}
.icon { flex:none; width:16px; height:16px; background:currentColor; }
.icon.film { -webkit-mask:var(--i-film) center/contain no-repeat; mask:var(--i-film) center/contain no-repeat; }
.icon.folder { -webkit-mask:var(--i-folder) center/contain no-repeat; mask:var(--i-folder) center/contain no-repeat; }
.icon.smart { -webkit-mask:var(--i-smart) center/contain no-repeat; mask:var(--i-smart) center/contain no-repeat; }

/* Window */
.window { display:grid; grid-template-columns:230px minmax(0,1fr) minmax(330px,400px); height:100vh; }

/* Sidebar */
.sidebar { display:flex; flex-direction:column; min-height:0; background:var(--sidebar); border-right:1px solid var(--separator); }
.brand { padding:16px 16px 6px; font-size:13px; font-weight:700; letter-spacing:-.01em; }
.sidebar nav { flex:1; overflow:auto; padding:4px 10px 10px; }
.sidebar h3 { margin:12px 8px 4px; font-size:11px; font-weight:600; color:var(--secondary); }
.item { display:flex; align-items:center; gap:7px; height:28px; padding:0 8px; border-radius:6px; cursor:default; }
.item .icon { color:var(--accent); }
.item .name { flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.item .count { color:var(--secondary); font-variant-numeric:tabular-nums; font-size:12px; }
.item.on { background:var(--sidebar-on); }
.item.d1 { padding-left:24px; } .item.d2 { padding-left:40px; } .item.d3 { padding-left:56px; } .item.d4 { padding-left:72px; }
.account { display:flex; align-items:center; gap:8px; padding:10px 12px; border-top:1px solid var(--separator); }
.avatar { flex:none; width:26px; height:26px; border-radius:50%; background:var(--tertiary); color:#fff;
  display:flex; align-items:center; justify-content:center; font-size:10.5px; font-weight:600; }
.account .who { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }

/* Content: toolbar over the clip list */
.content { display:flex; flex-direction:column; min-width:0; min-height:0; }
.toolbar { display:flex; align-items:center; gap:10px; height:52px; padding:0 14px 0 18px; background:var(--toolbar); border-bottom:1px solid var(--separator); }
.toolbar .titles { flex:1; min-width:0; }
.toolbar h1 { font-size:15px; font-weight:700; letter-spacing:-.01em; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.toolbar .sub { font-size:11px; color:var(--secondary); }
.toolbar input[type=date] { flex:none; }
.list { flex:1; overflow:auto; }
table { width:100%; border-collapse:separate; border-spacing:0; font-variant-numeric:tabular-nums; }
th, td { text-align:left; padding:0 10px; height:26px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; max-width:320px; }
th { position:sticky; top:0; z-index:1; height:27px; background:var(--window); color:var(--secondary); font-size:11px; font-weight:500;
  border-bottom:1px solid var(--separator); }
th + th { box-shadow:inset 1px 0 0 var(--separator); }
td:first-child, th:first-child { padding-left:18px; }
td.name { display:flex; align-items:center; gap:7px; max-width:none; }
td.name .icon { color:var(--secondary); width:14px; height:14px; }
td.name span:last-child { overflow:hidden; text-overflow:ellipsis; }
tbody tr { cursor:default; }
tbody tr:nth-child(even) { background:var(--stripe); }
tbody tr.on { background:var(--accent); color:var(--on-accent); }
tbody tr.on td, tbody tr.on .icon { color:var(--on-accent); }
td.num { color:var(--secondary); }
.dim { color:var(--secondary); } .bad { color:var(--bad); } .ok { color:var(--ok); }
.empty { display:flex; flex-direction:column; align-items:center; justify-content:center; gap:8px; min-height:220px; height:100%;
  padding:32px; text-align:center; color:var(--secondary); }
.empty .icon { width:40px; height:40px; color:var(--tertiary); }
.empty strong { font-size:15px; color:var(--text); }
.more { padding:10px 18px; color:var(--secondary); font-size:12px; }

/* Inspector */
.inspector { min-height:0; overflow:auto; background:var(--inspector); border-left:1px solid var(--separator); }
.viewer { background:#000; }
video { display:block; width:100%; max-height:46vh; background:#000; }
.transport { display:flex; align-items:baseline; gap:10px; padding:10px 16px 0; }
.tc { font:600 19px ui-monospace, "SF Mono", Menlo, monospace; letter-spacing:.02em; }
.hint { color:var(--secondary); font-size:11px; }
.head { padding:10px 16px 12px; border-bottom:1px solid var(--separator); }
.head h2 { font-size:13px; font-weight:600; overflow-wrap:anywhere; }
.head .dim { font-size:12px; margin-top:1px; }
.status { color:var(--secondary); font-size:12px; margin-top:6px; }
.status:empty { display:none; }
.row { display:flex; gap:8px; align-items:center; flex-wrap:wrap; margin-top:10px; }
.group { padding:12px 16px; border-bottom:1px solid var(--separator); }
.group:last-child { border-bottom:0; }
.group h3 { font-size:12px; font-weight:600; margin-bottom:7px; }
dl { display:grid; grid-template-columns:104px minmax(0,1fr); gap:4px 10px; margin:0; font-size:12px; }
dt { color:var(--secondary); text-align:right; } dd { margin:0; overflow-wrap:anywhere; }
.seg { display:flex; gap:10px; padding:4px 6px; margin:0 -6px; border-radius:5px; cursor:default; font-size:12.5px; }
.seg:hover { background:var(--hover); }
.seg .t { flex:none; color:var(--accent); font:12px ui-monospace, "SF Mono", Menlo, monospace; padding-top:1px; }
.seg mark { background:var(--mark); color:inherit; border-radius:2px; }
.chip { display:inline-block; background:var(--field); border-radius:5px; padding:2px 7px; margin:0 4px 4px 0; font-size:12px; }

/* Sheet and sign-in */
.modal { position:fixed; inset:0; z-index:10; background:var(--sheet-shade); display:flex; align-items:flex-start; justify-content:center; padding-top:14vh; }
.card { background:var(--window); border-radius:12px; padding:20px; width:min(420px,92vw); box-shadow:var(--shadow), 0 0 0 .5px var(--control-edge); }
.card h2 { font-size:13px; font-weight:700; margin-bottom:6px; }
.card p { font-size:12px; }
.card .row { justify-content:flex-end; margin-top:14px; }
.card .row input { margin-right:auto; }
.signin { display:flex; flex-direction:column; align-items:center; gap:8px; max-width:420px; margin:0 auto; padding:22vh 20px 0; text-align:center; }
.signin .icon { width:56px; height:56px; color:var(--accent); }
.signin h2 { font-size:20px; font-weight:700; letter-spacing:-.01em; }

@media (max-width:1100px) {
  html, body { height:auto; }
  .window { grid-template-columns:200px minmax(0,1fr); grid-template-rows:minmax(260px,46vh) auto; height:auto; min-height:100vh; }
  .inspector { grid-column:1/-1; border-left:0; border-top:1px solid var(--separator); }
  video { max-height:60vh; }
}
@media (max-width:640px) {
  .window { grid-template-columns:minmax(0,1fr); grid-template-rows:auto minmax(240px,44vh) auto; }
  .sidebar { border-right:0; border-bottom:1px solid var(--separator); }
  .sidebar nav { max-height:150px; }
  .toolbar { height:auto; flex-wrap:wrap; padding:8px 12px; }
  .search { flex-basis:100%; }
}
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
  for (const kid of kids.flat(Infinity)) if (kid != null && kid !== false) e.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  return e;
}
const icon = name => h('span', { class: 'icon ' + name, 'aria-hidden': 'true' });
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
  app.replaceChildren(h('div', { class: 'signin' }, icon('film'),
    h('h2', {}, 'StradaXR A.I. MAM'),
    h('p', { class: 'dim' }, message || 'Open the invite link you were sent to sign in.')));
}

function askInitials() {
  return new Promise(resolve => {
    const input = h('input', { maxlength: '4', placeholder: 'e.g. MR', autocomplete: 'off', class: 'initials', 'aria-label': 'Initials' });
    const error = h('div', { class: 'bad' });
    const go = h('button', { class: 'primary', onclick: async () => {
      try {
        state.me = await json('/v1/me/initials?value=' + encodeURIComponent(input.value), { method: 'POST' });
        modal.remove(); resolve();
      } catch (e) { error.textContent = e.message; }
    } }, 'Lock In Initials');
    const modal = h('div', { class: 'modal' }, h('div', { class: 'card' },
      h('h2', {}, 'Choose your initials'),
      h('p', { class: 'dim' }, 'Two to four letters. They are locked to you now and name you in the activity log. Only the owner can change them.'),
      error, h('div', { class: 'row' }, input, go)));
    input.addEventListener('keydown', e => { if (e.key === 'Enter') go.click(); });
    document.body.append(modal); input.focus();
  });
}

// ---- layout --------------------------------------------------------------
let searchTimer;
const nothingChosen = () => h('div', { class: 'empty' }, icon('film'), h('strong', {}, 'No Clip Selected'), 'Choose a clip to play its proxy.');
function buildLayout() {
  const search = h('input', { type: 'search', placeholder: 'Search', 'aria-label': 'Search names, dialogue, tags and people', oninput: e => {
    clearTimeout(searchTimer); searchTimer = setTimeout(() => { state.q = e.target.value.trim(); loadClips(); }, 250);
  } });
  const day = h('input', { type: 'date', title: 'Shoot day', 'aria-label': 'Shoot day', onchange: e => { state.day = e.target.value; loadClips(); } });
  const me = state.me;
  app.replaceChildren(h('div', { class: 'window' },
    h('aside', { class: 'sidebar' },
      h('div', { class: 'brand' }, 'StradaXR A.I. MAM'),
      h('nav', { id: 'side', 'aria-label': 'Library' }),
      h('div', { class: 'account' },
        h('span', { class: 'avatar', 'aria-hidden': 'true' }, me.initials || me.name.slice(0, 1).toUpperCase()),
        h('span', { class: 'who', title: me.name }, me.name),
        h('button', { onclick: signOut }, 'Sign Out'))),
    h('section', { class: 'content' },
      h('header', { class: 'toolbar' },
        h('div', { class: 'titles' }, h('h1', { id: 'title' }, 'All Clips'), h('div', { class: 'sub', id: 'subtitle' }, '')),
        day, h('div', { class: 'search' }, search)),
      h('div', { class: 'list', id: 'main' })),
    h('aside', { class: 'inspector', id: 'detail', 'aria-label': 'Clip' }, nothingChosen())));
  drawBins();
}

async function signOut() {
  await fetch('/v1/session/end', { method: 'POST', headers: { 'X-StradaXR': '1' }, credentials: 'same-origin' });
  state.me = null; keys.video = null; signedOut('You are signed out.');
}

// ---- bins ----------------------------------------------------------------
async function loadBins() { try { state.bins = await json('/v1/bins'); } catch (e) { state.bins = []; } }
function drawBins() {
  const side = document.getElementById('side');
  const children = id => state.bins.filter(b => (b.parentID || '') === id);
  const rows = [];
  const item = (label, kind, id, count, depth) => h('div', { class: 'item d' + Math.min(depth, 4) + (state.binId === id ? ' on' : ''), role: 'button', tabindex: '0',
    onclick: () => { state.binId = id; drawBins(); loadClips(); }, onkeydown: e => { if (e.key === 'Enter') e.currentTarget.click(); } },
    icon(kind), h('span', { class: 'name' }, label), count == null ? '' : h('span', { class: 'count' }, count));
  rows.push(h('h3', {}, 'Library'), item('All Clips', 'film', '', null, 0));
  if (state.bins.length) rows.push(h('h3', {}, 'Bins'));
  const walk = (parent, depth) => children(parent).forEach(b => { rows.push(item(b.name, b.isSmart ? 'smart' : 'folder', b.id, b.count, depth)); walk(b.id, depth + 1); });
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
  const bin = state.bins.find(b => b.id === state.binId);
  document.getElementById('title').textContent = bin ? bin.name : 'All Clips';
  document.getElementById('subtitle').textContent = page.total === 1 ? '1 clip' : page.total + ' clips';
  if (!page.items.length) {
    const filtered = state.q || state.day || state.binId;
    main.replaceChildren(h('div', { class: 'empty' }, icon('film'), h('strong', {}, filtered ? 'No Results' : 'No Clips Yet'),
      filtered ? 'Nothing matches this search, day or bin.' : 'Clips appear here once they have a proxy for remote viewing.'));
    return;
  }
  const head = ['Name', 'Reel', 'Picture', 'Duration', 'Start', 'Proxy'];
  const rows = page.items.map(a => h('tr', { class: state.selected === a.id ? 'on' : '', onclick: () => openClip(a.id) },
    h('td', { class: 'name', title: a.notes ? a.fileName + ' — ' + a.notes : a.fileName }, icon('film'), h('span', {}, a.fileName)), h('td', {}, a.reelName || '—'),
    h('td', {}, a.width + '×' + a.height + ' · ' + fps(a)), h('td', { class: 'num' }, clock(a.durationSeconds)), h('td', { class: 'num' }, a.startTimecode),
    h('td', { class: 'num' }, a.proxy ? bytes(a.proxy.bytes) : 'None yet')));
  main.replaceChildren(h('table', {}, h('thead', {}, h('tr', {}, head.map(t => h('th', {}, t)))), h('tbody', {}, rows)),
    page.total > page.items.length ? h('div', { class: 'more' }, 'Showing ' + page.items.length + ' of ' + page.total + '. Narrow the search to see the rest.') : '');
}
const fps = a => { const v = a.frameRateNum / a.frameRateDen; return (Math.abs(v - Math.round(v)) < 0.001 ? Math.round(v) : v.toFixed(3)) + 'p'; };

// ---- clip detail and player ----------------------------------------------
async function openClip(id) {
  state.selected = id; drawClips();
  const box = document.getElementById('detail');
  box.replaceChildren(h('div', { class: 'empty' }, 'Loading…'));
  box.scrollTop = 0;
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
  } }, a.proxy ? 'Download Proxy (' + bytes(a.proxy.bytes) + ')' : 'No Proxy Yet');

  const group = (title, ...kids) => h('div', { class: 'group' }, title ? h('h3', {}, title) : null, kids);
  box.replaceChildren(...[
    h('div', { class: 'viewer' }, video),
    h('div', { class: 'transport' }, tc, h('span', { class: 'hint' }, 'Space plays · J K L · ← → step a frame')),
    h('div', { class: 'head' }, h('h2', {}, a.fileName),
      h('div', { class: 'dim' }, a.formatName + ' · ' + a.width + '×' + a.height + ' · ' + fps(a) + ' · ' + clock(a.durationSeconds)),
      status, h('div', { class: 'row' }, dl)),
    group('Information', h('dl', {}, dt('Reel', a.reelName || '—'), dt('Start timecode', a.startTimecode + (a.dropFrame ? ' DF' : '')), dt('Audio', a.audioChannels + ' channels'),
      dt('Original', bytes(a.originalBytes)), a.proxy && a.proxy.megabitsPerSecond ? dt('Proxy', a.proxy.megabitsPerSecond.toFixed(1) + ' Mbps') : '')),
    a.notes ? group('Notes', h('p', {}, a.notes)) : null,
    tags.size ? group('Tags', h('div', {}, [...tags.keys()].slice(0, 60).map(l => h('span', { class: 'chip' }, l)))) : null,
    markers.length ? group('Markers', markers) : null,
    transcript.length ? group('Dialogue', transcript) : null].filter(Boolean));

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
#endif

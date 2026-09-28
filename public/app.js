/* global L */
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const SOURCE_LABEL = { db: 'DB', transitous: 'Transitous', flix: 'Flix', oebb: 'ÖBB' };
const cssVar = (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const modeColor = (m) => cssVar(`--m-${m}`) || cssVar('--m-other');

const fmtTime = (iso) => new Date(iso).toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Berlin' });
const fmtDur = (min) => (min >= 60 ? `${Math.floor(min / 60)} h ${String(min % 60).padStart(2, '0')}` : `${min} min`);
const fmtEur = (n) => n.toLocaleString('de-DE', { style: 'currency', currency: 'EUR' });
const dayDiff = (a, b) => Math.round((new Date(new Date(b).toDateString()) - new Date(new Date(a).toDateString())) / 864e5);

const state = { from: null, to: null, data: null, sort: 'best', selected: null };

/* ---------- persisted options ---------- */
const form = $('#search');
const OPT_KEYS = ['dticket', 'dticketOnly', 'coach', 'class', 'bahncard'];
function loadOpts() {
  try {
    const o = JSON.parse(localStorage.getItem('anschluss-opts') || '{}');
    for (const k of OPT_KEYS) if (k in o) { const el = form.elements[k]; if (el.type === 'checkbox') el.checked = o[k]; else el.value = o[k]; }
    if (o.src) $$('input[name=src]').forEach((c) => { c.checked = o.src.includes(c.value); });
    if (o.from) { state.from = o.from; form.elements.from.value = o.from.name; }
    if (o.to) { state.to = o.to; form.elements.to.value = o.to.name; }
  } catch { /* storage unavailable */ }
}
function saveOpts() {
  const o = {};
  for (const k of OPT_KEYS) { const el = form.elements[k]; o[k] = el.type === 'checkbox' ? el.checked : el.value; }
  o.src = $$('input[name=src]:checked').map((c) => c.value);
  o.from = state.from; o.to = state.to;
  try { localStorage.setItem('anschluss-opts', JSON.stringify(o)); } catch { /* ignore */ }
}

function setWhen(d) {
  const local = new Date(d.getTime() - d.getTimezoneOffset() * 60000);
  form.elements.when.value = local.toISOString().slice(0, 16);
}

/* ---------- autocomplete ---------- */
function autocomplete(input, key) {
  const list = input.parentElement.querySelector('.suggest');
  let items = [], active = -1, timer, reqId = 0;
  const close = () => { list.hidden = true; active = -1; };
  const choose = (i) => {
    const it = items[i]; if (!it) return;
    state[key] = it; input.value = it.name; close(); saveOpts();
  };
  const render = () => {
    list.innerHTML = items.map((it, i) =>
      `<li role="option" data-i="${i}" aria-selected="${i === active}">${esc(it.name)}${it.area ? `<small>${esc(it.area)}</small>` : ''}</li>`).join('');
    list.hidden = !items.length;
  };
  input.addEventListener('input', () => {
    state[key] = null;
    clearTimeout(timer);
    const q = input.value.trim();
    if (q.length < 2) { items = []; render(); return; }
    timer = setTimeout(async () => {
      const id = ++reqId;
      try {
        const res = await fetch(`/api/locations?q=${encodeURIComponent(q)}`).then((r) => r.json());
        if (id !== reqId) return;
        items = Array.isArray(res) ? res : []; active = items.length ? 0 : -1; render();
      } catch { /* offline */ }
    }, 220);
  });
  input.addEventListener('keydown', (e) => {
    if (list.hidden) return;
    if (e.key === 'ArrowDown') { active = Math.min(items.length - 1, active + 1); render(); e.preventDefault(); }
    if (e.key === 'ArrowUp') { active = Math.max(0, active - 1); render(); e.preventDefault(); }
    if (e.key === 'Enter' && active >= 0) { choose(active); e.preventDefault(); }
    if (e.key === 'Escape') close();
  });
  list.addEventListener('mousedown', (e) => { const li = e.target.closest('li'); if (li) { e.preventDefault(); choose(+li.dataset.i); } });
  input.addEventListener('blur', () => setTimeout(close, 120));
  return { pickFirst: () => items[0] && choose(0), hasItems: () => items.length > 0 };
}
const acFrom = autocomplete(form.elements.from, 'from');
const acTo = autocomplete(form.elements.to, 'to');

$('#swap').addEventListener('click', () => {
  [state.from, state.to] = [state.to, state.from];
  [form.elements.from.value, form.elements.to.value] = [form.elements.to.value, form.elements.from.value];
  saveOpts();
});

/* ---------- search ---------- */
async function ensurePlace(key, ac) {
  if (state[key]) return state[key];
  const q = form.elements[key].value.trim();
  if (!q) return null;
  if (ac.hasItems()) { ac.pickFirst(); return state[key]; }
  const res = await fetch(`/api/locations?q=${encodeURIComponent(q)}`).then((r) => r.json()).catch(() => []);
  if (res[0]) { state[key] = res[0]; form.elements[key].value = res[0].name; }
  return state[key] || { name: q };
}

async function search() {
  const from = await ensurePlace('from', acFrom);
  const to = await ensurePlace('to', acTo);
  if (!from || !to) return;
  saveOpts();
  const f = form.elements;
  const when = f.when.value ? new Date(f.when.value) : new Date();
  const p = new URLSearchParams({
    from: JSON.stringify(from), to: JSON.stringify(to), when: when.toISOString(),
    arriveBy: form.querySelector('input[name=arriveBy]:checked').value,
    dticket: f.dticket.checked ? '1' : '0', dticketOnly: f.dticketOnly.checked ? '1' : '0',
    coach: f.coach.checked ? '1' : '0', class: f.class.checked ? '1' : '0', bahncard: f.bahncard.value,
    sources: $$('input[name=src]:checked').map((c) => c.value).join(','),
  });
  const btn = $('.go');
  btn.disabled = true; btn.textContent = 'Searching all operators…';
  $('#results').innerHTML = '<div class="loading"><div class="bar"></div>Asking DB, Transitous, Flix and ÖBB at the same time.</div>';
  document.body.classList.remove('searching-empty');
  try {
    const res = await fetch(`/api/journeys?${p}`);
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || `Server error ${res.status}`);
    state.data = data; state.selected = null;
    renderResults(); renderStatus();
  } catch (e) {
    $('#results').innerHTML = `<div class="empty"><p>Search failed: ${esc(e.message)}. Check that the server is still running, then search again.</p></div>`;
  } finally {
    btn.disabled = false; btn.textContent = 'Find connections';
  }
}
form.addEventListener('submit', (e) => { e.preventDefault(); search(); });

function shiftAndSearch(minutes) {
  const base = form.elements.when.value ? new Date(form.elements.when.value) : new Date();
  setWhen(new Date(base.getTime() + minutes * 60000));
  search();
}
$('#earlier').addEventListener('click', () => shiftAndSearch(-60));
$('#later').addEventListener('click', () => {
  const js = state.data?.journeys || [];
  if (js.length && form.querySelector('input[name=arriveBy]:checked').value === '0') {
    const lastDep = Math.max(...js.map((j) => new Date(j.departure)));
    setWhen(new Date(lastDep + 60000)); search();
  } else shiftAndSearch(60);
});

$$('.sorts button').forEach((b) => b.addEventListener('click', () => {
  state.sort = b.dataset.sort;
  $$('.sorts button').forEach((x) => x.classList.toggle('on', x === b));
  renderResults();
}));

/* ---------- results ---------- */
const SORTERS = {
  best: (a, b) => a.score - b.score,
  fast: (a, b) => a.duration - b.duration || a.transfers - b.transfers,
  cheap: (a, b) => (a.effectivePrice ?? Infinity) - (b.effectivePrice ?? Infinity) || a.duration - b.duration,
  early: (a, b) => new Date(a.arrival) - new Date(b.arrival),
  transfers: (a, b) => a.transfers - b.transfers || a.duration - b.duration,
};

function highlights(js) {
  const ok = js.filter((j) => !j.cancelled && !j.soldOut);
  const pick = (fn) => ok.slice().sort(fn)[0]?.id;
  return {
    [pick(SORTERS.fast)]: 'Fastest',
    [pick(SORTERS.cheap)]: ok.some((j) => j.effectivePrice != null) ? 'Cheapest' : undefined,
    [pick(SORTERS.best)]: 'Best overall',
  };
}

function strip(j) {
  const total = Math.max(1, j.duration);
  let html = '', prevArr = null;
  for (const l of j.legs) {
    if (prevArr) {
      const wait = (new Date(l.dep) - new Date(prevArr)) / 60000;
      if (wait > 2) html += `<span class="seg-wait" style="flex:${wait / total}"></span>`;
    }
    const mins = Math.max(1, (new Date(l.arr) - new Date(l.dep)) / 60000);
    const label = l.mode === 'walk' ? '' : esc(l.line.replace(/\s*\(.*\)/, ''));
    html += `<span class="seg-leg ${l.mode === 'walk' ? 'walk' : ''}" style="flex:${mins / total};background:${modeColor(l.mode)}" title="${esc(l.line)} ${fmtTime(l.dep)}–${fmtTime(l.arr)}">${label}</span>`;
    prevArr = l.arr;
  }
  return `<div class="strip" aria-hidden="true">${html}</div>`;
}

function delayHtml(min) {
  if (min == null) return '';
  return min > 0 ? `<span class="delay">+${min}</span>` : '<span class="delay ontime">on time</span>';
}

function priceHtml(j, f) {
  if (f.dticket.checked && j.dticket) return '<div class="price">0 €<small>with Deutschlandticket</small></div>';
  const p = j.bestPrice;
  if (!p) return '<div class="price none">no price</div>';
  const more = j.prices.length > 1 ? ` · ${j.prices.length} offers` : '';
  return `<div class="price">${p.partial ? 'from ' : ''}${fmtEur(p.amount)}<small>${SOURCE_LABEL[p.source]}${more}</small></div>`;
}

function legHtml(l) {
  const c = modeColor(l.mode);
  if (l.mode === 'walk') {
    const mins = Math.round((new Date(l.arr) - new Date(l.dep)) / 60000);
    return `<div class="leg walk" style="--c:${c}"><div class="t"></div><div class="rail"></div>
      <div class="body"><span class="line">Walk ${mins} min${l.walkDistance ? `, ${Math.round(l.walkDistance)} m` : ''}</span></div></div>`;
  }
  const stops = l.stops.filter((s) => s.name && s.name !== l.from.name && s.name !== l.to.name);
  return `<div class="leg" style="--c:${c}">
    <div class="t"><span>${fmtTime(l.dep)}${delayHtml(l.depDelay)}</span><span>${fmtTime(l.arr)}${delayHtml(l.arrDelay)}</span></div>
    <div class="rail"><span class="dot a"></span><span class="dot b"></span></div>
    <div class="body">
      <span class="station">${esc(l.from.name)} ${l.depPlatform ? `<span class="plat">Pl. ${esc(l.depPlatform)}</span>` : ''}</span>
      <span class="line"><b>${esc(l.line)}</b>${l.direction ? ` towards ${esc(l.direction)}` : ''}${l.operator ? `, ${esc(l.operator)}` : ''}</span>
      ${l.cancelled ? '<span class="warn">Cancelled</span>' : ''}
      ${l.remarks.map((r) => `<span class="warn">${esc(r)}</span>`).join('')}
      ${stops.length ? `<details><summary>${stops.length} stops in between</summary><ol>${stops.map((s) => `<li>${esc(s.name)}${s.arr ? ` ${fmtTime(s.arr)}` : ''}</li>`).join('')}</ol></details>` : ''}
      <span class="station">${esc(l.to.name)} ${l.arrPlatform ? `<span class="plat">Pl. ${esc(l.arrPlatform)}</span>` : ''}</span>
    </div></div>`;
}

function bookHtml(j) {
  const links = [];
  const flixUrl = j.prices.find((p) => p.source === 'flix')?.url || j.bookingUrls?.flix;
  const dbUrl = j.bookingUrls?.db;
  if (flixUrl) links.push(`<a class="primary" href="${esc(flixUrl)}" target="_blank" rel="noopener">Book at Flix</a>`);
  if (dbUrl) links.push(`<a class="${flixUrl ? '' : 'primary'}" href="${esc(dbUrl)}" target="_blank" rel="noopener">Open on bahn.de</a>`);
  if (j.bookingUrls?.oebb && !dbUrl) links.push(`<a href="${esc(j.bookingUrls.oebb)}" target="_blank" rel="noopener">ÖBB tickets</a>`);
  return links.length ? `<div class="book">${links.join('')}</div>` : '';
}

function renderResults() {
  const f = form.elements;
  const js = (state.data?.journeys || []).slice().sort(SORTERS[state.sort]);
  $('.sorts').hidden = !js.length; $('.paging').hidden = !state.data;
  if (!js.length) {
    const errs = Object.values(state.data?.status || {}).filter((s) => !s.ok).length;
    $('#results').innerHTML = `<div class="empty"><p>No connection found${errs ? ' – some sources did not answer, see below' : ''}. Try another time, turn on long-distance buses, or pick stations from the suggestions.</p></div>`;
    drawMap(null); return;
  }
  const hi = highlights(js);
  const firstDay = js[0].departure;
  $('#results').innerHTML = js.map((j) => {
    const dep = j.legs.find((l) => l.mode !== 'walk') || j.legs[0];
    const dd = dayDiff(j.departure, j.arrival);
    const nextDay = dayDiff(firstDay, j.departure);
    const tags = [
      hi[j.id] ? `<span class="tag hi">${hi[j.id]}</span>` : '',
      j.dticket ? '<span class="tag dt">Deutschlandticket</span>' : '',
      j.cancelled ? '<span class="tag bad">Cancelled</span>' : '',
      j.soldOut ? '<span class="tag bad">Sold out</span>' : '',
      j.dominated && state.sort === 'best' ? '<span class="tag">Another option beats this</span>' : '',
      ...j.sources.map((s) => `<span class="tag src">${SOURCE_LABEL[s] || s}</span>`),
    ].join('');
    return `<article class="trip ${j.id === state.selected ? 'sel' : ''} ${j.dominated ? 'dim' : ''} ${j.cancelled ? 'cancel' : ''}" data-id="${esc(j.id)}" tabindex="0">
      <div class="row1">
        <div class="times">${fmtTime(j.departure)}${delayHtml(j.legs[0].depDelay && j.legs[0].depDelay > 0 ? j.legs[0].depDelay : null)} – ${fmtTime(j.arrival)}${dd ? `<sup>+${dd}</sup>` : ''}</div>
        ${priceHtml(j, f)}
      </div>
      <div class="meta"><span><b>${fmtDur(j.duration)}</b></span><span>${j.transfers ? `${j.transfers} change${j.transfers > 1 ? 's' : ''}` : 'Direct'}</span><span>${esc(dep.line)}${nextDay ? `, ${new Date(j.departure).toLocaleDateString('de-DE', { weekday: 'short', day: 'numeric', month: 'short' })}` : ''}</span></div>
      ${strip(j)}
      <div class="tags">${tags}</div>
      <div class="detail">${j.legs.map(legHtml).join('')}${bookHtml(j)}</div>
    </article>`;
  }).join('');
  $$('.trip').forEach((el) => {
    const pick = (e) => { if (e.target.closest('a, details')) return; select(el.dataset.id); };
    el.addEventListener('click', pick);
    el.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(e); } });
  });
  drawMap(js.find((j) => j.id === state.selected) || js[0], !state.selected);
}

function select(id) {
  state.selected = state.selected === id ? null : id;
  $$('.trip').forEach((el) => el.classList.toggle('sel', el.dataset.id === state.selected));
  const j = state.data.journeys.find((x) => x.id === (state.selected || id));
  drawMap(j);
}

function renderStatus() {
  const s = state.data?.status || {};
  $('#status').innerHTML = Object.entries(s).map(([k, v]) => v.ok
    ? `<span>${SOURCE_LABEL[k]}: ${v.count} found</span>`
    : `<span class="err" title="${esc(v.error)}">${SOURCE_LABEL[k]}: ${esc(v.error.slice(0, 60))}</span>`).join('');
}

/* ---------- map ---------- */
const hasMap = typeof L !== 'undefined';
let map, routeLayer;
if (hasMap) {
  map = L.map('map', { zoomControl: true }).setView([51.1, 10.4], 6);
  const base = L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19, className: 'base', attribution: '&copy; OpenStreetMap contributors',
  }).addTo(map);
  const rail = L.tileLayer('https://{s}.tiles.openrailwaymap.org/standard/{z}/{x}/{y}.png', {
    maxZoom: 19, opacity: 0.7, attribution: 'OpenRailwayMap',
  });
  L.control.layers({ Map: base }, { 'Railway network': rail }, { position: 'topright' }).addTo(map);
  routeLayer = L.layerGroup().addTo(map);
} else {
  $('#map').innerHTML = '<p style="padding:20px">The map library could not load. Check your internet connection.</p>';
}

function drawMap(j, fit = true) {
  if (!hasMap) return;
  map.invalidateSize();
  routeLayer.clearLayers();
  if (!j) return;
  const bounds = [];
  for (const l of j.legs) {
    if (!l.path?.length) continue;
    const walk = l.mode === 'walk';
    L.polyline(l.path, { color: '#fff', weight: walk ? 5 : 9, opacity: 0.9 }).addTo(routeLayer);
    L.polyline(l.path, {
      color: modeColor(l.mode), weight: walk ? 3 : 5, opacity: 1, dashArray: walk ? '4 6' : l.pathExact ? null : '10 6',
    }).bindTooltip(`${esc(l.line)} · ${fmtTime(l.dep)}–${fmtTime(l.arr)}`, { sticky: true }).addTo(routeLayer);
    bounds.push(...l.path);
  }
  const points = [];
  j.legs.forEach((l, i) => {
    if (l.from.lat != null && (i === 0 || l.mode !== 'walk')) points.push({ ...l.from, t: l.dep, p: l.depPlatform });
    if (i === j.legs.length - 1 && l.to.lat != null) points.push({ ...l.to, t: l.arr, p: l.arrPlatform });
  });
  for (const p of points) {
    L.circleMarker([p.lat, p.lon], { radius: 6, color: cssVar('--ink'), weight: 3, fillColor: cssVar('--panel'), fillOpacity: 1 })
      .bindTooltip(`${esc(p.name)} ${fmtTime(p.t)}${p.p ? `, Pl. ${esc(p.p)}` : ''}`).addTo(routeLayer);
  }
  if (fit && bounds.length) map.fitBounds(bounds, { padding: [30, 30] });
}

/* ---------- init ---------- */
loadOpts();
setWhen(new Date());
if (!state.data) document.body.classList.add('searching-empty');

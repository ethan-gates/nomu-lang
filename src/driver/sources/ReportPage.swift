import Foundation

// The build's report page (task 193): `build/_perf/index.html`, a view of `report.json`, which it embeds (a page
// opened from disk cannot fetch a neighbouring file). Self-contained: inline styles and script, no network. One
// page: the wall time and summary, the modules (sortable; a click opens a module's breakdown in a side panel), the
// archive and link steps (a link with its binary's size), the stage totals over the build (each phase's stages
// collapsed under it), and the critical path. `report.json` calls modules,
// archives and links alike units; the page names each by its kind.
enum ReportPage {
    static let fileName = "index.html"

    // The page with `json` (the report's encoding) embedded and, when `history` is given, a link to the build
    // history's list page at that relative path. The build writes it as `index.html` and keeps a copy in the
    // build history, each with the path from its own directory.
    static func render(json: Data, history: String?) -> Data {
        // `</` would end the script element that holds the data.
        let embedded = String(decoding: json, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
        let link = history.map { #"<a class="nav" href="\#($0)">← all builds</a>"# } ?? ""
        return Data(template.replacingOccurrences(of: "__HISTORY_LINK__", with: link)
            .replacingOccurrences(of: "__REPORT_JSON__", with: embedded).utf8)
    }

    static let template = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>nomu build report</title>
<style>
:root {
  --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --line: #e3e3e8; --row: #f6f6f8; --sel: #e8f0fe;
  --bar: #4f7cff; --bar2: #9db4ff; --crit: #d9480f; --ok: #2b8a3e; --cache: #5c7cfa; --fail: #c92a2a;
  --panel: #fbfbfd; --mono: ui-monospace, SFMono-Regular, Menlo, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #161618; --fg: #ececf0; --muted: #9a9aa3; --line: #2c2c31; --row: #1d1d21; --sel: #23304d;
    --bar: #6d8dff; --bar2: #3d4f8f; --crit: #ff8a4c; --ok: #69db7c; --cache: #91a7ff; --fail: #ff6b6b;
    --panel: #1b1b1f;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
main { padding: 24px 16px 64px; max-width: 1180px; }
body.panel-open main { margin-right: 440px; }
h1 { font-size: 20px; margin: 0 0 4px; }
h2 { font-size: 15px; margin: 32px 0 8px; }
.muted { color: var(--muted); }
a.nav { display: inline-block; margin-bottom: 8px; color: var(--bar); text-decoration: none; font-size: 13px; }
a.nav:hover { text-decoration: underline; }
.wall { margin: 12px 0 0; }
.wall b { font-size: 32px; font-variant-numeric: tabular-nums; }
.wall span { color: var(--muted); margin-left: 6px; }
.summary { margin: 4px 0; }
.stats { display: flex; flex-wrap: wrap; gap: 8px 24px; margin: 12px 0 0; }
.stat b { display: block; font-size: 18px; font-variant-numeric: tabular-nums; }
.stat span { color: var(--muted); font-size: 12px; }
table { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 5px 8px; border-bottom: 1px solid var(--line); white-space: nowrap; }
th { font-weight: 600; color: var(--muted); font-size: 12px; }
td.num, th.num { text-align: right; }
td.name { white-space: normal; word-break: break-all; font-family: var(--mono); font-size: 12.5px; }
tbody tr.unit { cursor: pointer; }
tbody tr.unit:hover { background: var(--row); }
tbody tr.unit.selected { background: var(--sel); }
.crit { color: var(--crit); font-weight: 600; }
.status-compiled { color: var(--ok); } .status-cached { color: var(--cache); } .status-failed { color: var(--fail); }
.sorts { float: right; font-size: 12px; }
.sorts button { font: inherit; background: none; border: 1px solid var(--line); color: var(--fg); border-radius: 4px; padding: 1px 8px; cursor: pointer; margin-left: 4px; }
.sorts button.on { background: var(--sel); }
.bar { height: 8px; background: var(--bar); border-radius: 2px; min-width: 1px; }
.barcell { width: 30%; }
tr.phase td { font-weight: 600; }
tr.stage td:first-child { padding-left: 24px; }
tr.stage td { color: var(--muted); }
#stages tr.stage { display: none; }
#stages tr.stage.shown { display: table-row; }
#stages tr.phase.toggle { cursor: pointer; }
#stages tr.phase.toggle:hover { background: var(--row); }
#stages .caret { display: inline-block; width: 14px; color: var(--muted); }
aside { position: fixed; top: 0; right: 0; bottom: 0; width: 440px; background: var(--panel); border-left: 1px solid var(--line);
        overflow-y: auto; padding: 20px 16px 48px; display: none; }
body.panel-open aside { display: block; }
aside h3 { margin: 0 32px 8px 0; font-family: var(--mono); font-size: 13px; word-break: break-all; }
aside .close { position: absolute; top: 14px; right: 12px; font: inherit; font-size: 18px; background: none; border: none; color: var(--muted); cursor: pointer; }
aside dl { display: grid; grid-template-columns: max-content 1fr; gap: 2px 12px; margin: 8px 0 16px; }
aside dt { color: var(--muted); } aside dd { margin: 0; word-break: break-word; }
aside ul { margin: 4px 0 0; padding-left: 18px; font-family: var(--mono); font-size: 12px; }
@media (max-width: 900px) {
  body.panel-open main { margin-right: 0; }
  aside { width: 100%; }
  .barcell { display: none; }
}
</style>
</head>
<body>
<main>
  __HISTORY_LINK__
  <h1 id="title"></h1>
  <div class="muted" id="started"></div>
  <div class="wall" id="wall"></div>
  <div class="summary" id="summary"></div>
  <div class="stats" id="stats"></div>

  <h2>Modules <span class="sorts" id="sorts"></span></h2>
  <table>
    <thead><tr><th>module</th><th>status</th><th class="num">time</th><th class="num">cost</th><th class="num">bytes</th></tr></thead>
    <tbody id="units"></tbody>
  </table>

  <h2>Archive and link</h2>
  <table>
    <thead><tr><th>step</th><th>status</th><th class="num">time</th><th class="num">cost</th><th class="num">binary</th></tr></thead>
    <tbody id="steps"></tbody>
  </table>

  <h2>Stages <span class="muted" style="font-weight:400">— summed over the build</span></h2>
  <table><tbody id="stages"></tbody></table>

  <h2>Planner</h2>
  <table><tbody id="planner"></tbody></table>

  <h2>Critical path <span class="muted" style="font-weight:400">— each module or link at its cost, cached or not</span></h2>
  <table><tbody id="critical"></tbody></table>
</main>
<aside id="panel" aria-live="polite">
  <button class="close" id="close" aria-label="Close">×</button>
  <div id="detail"></div>
</aside>
<script id="report" type="application/json">__REPORT_JSON__</script>
<script>
const R = JSON.parse(document.getElementById('report').textContent);
const $ = id => document.getElementById(id);
const esc = s => String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function fmt(us) {
  if (us == null) return '—';
  if (us >= 1e6) return (us / 1e6).toFixed(2) + ' s';
  if (us > 0 && us < 500) return '<1 ms';
  return Math.round(us / 1e3) + ' ms';
}
function bytes(n) {
  if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB';
  return n >= 1024 ? (n / 1024).toFixed(n >= 10240 ? 0 : 1) + ' KB' : (n ? n + ' B' : '');
}
// A link's binary size, matched by its workspace-relative path at the end of the binary's absolute path.
function binarySize(u) {
  const i = (R.binaries || []).findIndex(b => b.endsWith('/' + u.name));
  return i >= 0 && R.binaryBytes ? R.binaryBytes[i] : 0;
}
function bar(frac, color) {
  return `<div class="bar" style="width:${Math.max(0, Math.min(1, frac)) * 100}%${color ? ';background:' + color : ''}"></div>`;
}
const crit = new Set(R.criticalPath.units);

// Header.
$('title').textContent = 'nomu build · ' + (R.package || 'build');
$('started').textContent = new Date(R.started).toLocaleString() + (R.optimize ? ' · optimized' : '');
const m = R.modules, l = R.links;
$('wall').innerHTML = `<b>${esc(fmt(R.dur))}</b><span>wall time</span>`;
let line = `${R.status} · ${m.total} modules: ${m.compiled} compiled, ${m.cached} cached`;
if (m.failed) line += `, ${m.failed} failed`;
if (l.total) line += ` · ${l.total === 1 ? (l.cached ? 'link cached' : 'linked') : `${l.total} links: ${l.compiled} linked, ${l.cached} cached`}`;
$('summary').textContent = line;
const stats = [
  [fmt(R.criticalPath.dur), 'critical path, nothing cached'],
  [fmt(R.criticalPath.summed), 'summed cost'],
  [fmt(R.criticalPath.setup), 'setup before the first module'],
  [(R.bytes / 1024).toFixed(0) + ' KB · ' + R.tokens.toLocaleString(), 'source read · tokens'],
];
const sizes = (R.binaryBytes || []).filter(n => n > 0);
if (sizes.length) stats.splice(1, 0, [sizes.map(bytes).join(' · '), sizes.length === 1 ? 'binary size' : 'binary sizes']);
$('stats').innerHTML = stats.map(([v, k]) => `<div class="stat"><b>${esc(v)}</b><span>${esc(k)}</span></div>`).join('');

// Modules, and the archive and link steps; the build's own track shows only as the wall time.
const units = R.units.map((u, i) => Object.assign({ order: i }, u));
let sortKey = 'plan', selected = null;
const sorters = { plan: (a, b) => a.order - b.order, time: (a, b) => b.dur - a.dur, cost: (a, b) => (b.cost ?? b.dur) - (a.cost ?? a.dur) };
$('sorts').innerHTML = ['plan', 'time', 'cost'].map(k => `<button data-sort="${k}">${k}</button>`).join('');
$('sorts').addEventListener('click', e => { const k = e.target.dataset.sort; if (k) { sortKey = k; renderUnits(); } });
function renderUnits() {
  for (const b of $('sorts').children) b.classList.toggle('on', b.dataset.sort === sortKey);
  const row = u => `
    <tr class="unit${u.order === selected ? ' selected' : ''}" data-i="${u.order}" tabindex="0">
      <td class="name">${crit.has(u.name) ? '<span class="crit" title="on the critical path">● </span>' : ''}${esc(u.kind === 'module' ? u.name : u.kind + ' ' + u.name)}</td>
      <td class="status-${esc(u.outcome)}">${esc(u.outcome)}</td>
      <td class="num">${fmt(u.dur)}</td>
      <td class="num">${fmt(u.cost)}</td>
      <td class="num">${bytes(u.kind === 'link' ? binarySize(u) : u.bytes)}</td>
    </tr>`;
  $('units').innerHTML = units.filter(u => u.kind === 'module').sort(sorters[sortKey]).map(row).join('');
  $('steps').innerHTML = units.filter(u => u.kind === 'archive' || u.kind === 'link').map(row).join('');
}
for (const id of ['units', 'steps']) {
  $(id).addEventListener('click', e => { const tr = e.target.closest('tr.unit'); if (tr) open(+tr.dataset.i); });
  $(id).addEventListener('keydown', e => { const tr = e.target.closest('tr.unit'); if (tr && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); open(+tr.dataset.i); } });
}

// A phase → stage breakdown of spans, as the old timing table showed it, with bars against `scale`.
function breakdown(spans, scale) {
  const phases = new Map();
  for (const s of spans) {
    if (!phases.has(s.phase)) phases.set(s.phase, { dur: 0, stages: new Map() });
    const p = phases.get(s.phase); p.dur += s.dur;
    const st = p.stages.get(s.name) || { dur: 0, count: 0 }; st.dur += s.dur; st.count += 1; p.stages.set(s.name, st);
  }
  let rows = '';
  for (const [phase, p] of phases) {
    rows += `<tr class="phase"><td>${esc(phase)}</td><td class="num">${fmt(p.dur)}</td><td class="num"></td><td class="barcell">${bar(p.dur / scale)}</td></tr>`;
    if (p.stages.size > 1 || !p.stages.has(phase)) {
      for (const [name, st] of p.stages) {
        rows += `<tr class="stage"><td>${esc(name)}</td><td class="num">${fmt(st.dur)}</td><td class="num">${st.count > 1 ? '×' + st.count : ''}</td><td class="barcell">${bar(st.dur / scale, 'var(--bar2)')}</td></tr>`;
      }
    }
  }
  return `<table><thead><tr><th>phase / stage</th><th class="num">time</th><th class="num"></th><th></th></tr></thead><tbody>${rows}</tbody></table>`;
}

function open(i) {
  selected = i;
  const u = units[i];
  const facts = [
    ['kind', u.kind], ['status', u.outcome], ['time', fmt(u.dur)],
    ['cost', u.cost != null ? fmt(u.cost) : 'not recorded'],
    ['started', '+' + fmt(u.start)],
  ];
  if (u.bytes) facts.push(['source', bytes(u.bytes) + ' · ' + u.tokens.toLocaleString() + ' tokens']);
  if (crit.has(u.name)) facts.push(['critical path', 'on it']);
  if (u.reason) facts.push(['why', u.reason]);
  let html = `<h3>${esc(u.name)}</h3><dl>${facts.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('')}</dl>`;
  if (u.outcome === 'cached') {
    html += `<p class="muted">Served by the cache: no stages ran this build${u.cost != null ? '; building it costs ' + fmt(u.cost) : ''}.</p>`;
  }
  if (u.spans.length) html += breakdown(u.spans, u.dur || 1);
  if (u.dependencies.length) html += `<h2>Waits for</h2><ul>${u.dependencies.map(d => `<li>${esc(d)}</li>`).join('')}</ul>`;
  $('detail').innerHTML = html;
  document.body.classList.add('panel-open');
  renderUnits();
}
function close() { selected = null; document.body.classList.remove('panel-open'); renderUnits(); }
$('close').addEventListener('click', close);
document.addEventListener('keydown', e => { if (e.key === 'Escape') close(); });

// Stages summed over the build: one row per phase, its stages hidden until the phase's row is clicked.
(function () {
  const total = R.phases.reduce((a, p) => a + p.dur, 0) || 1;
  let rows = `<tr><th>phase / stage</th><th class="num">total</th><th class="num">count</th><th class="num">share</th><th></th></tr>`;
  R.phases.forEach((p, i) => {
    const stages = R.stages.filter(s => s.phase === p.phase).sort((a, b) => b.dur - a.dur);
    const inner = stages.length > 1 || (stages.length === 1 && stages[0].name !== p.phase);
    rows += `<tr class="phase${inner ? ' toggle' : ''}" data-p="${i}"${inner ? ' tabindex="0" aria-expanded="false"' : ''}><td><span class="caret">${inner ? '▸' : ''}</span>${esc(p.phase)}</td><td class="num">${fmt(p.dur)}</td><td></td><td class="num">${(p.dur / total * 100).toFixed(1)}%</td><td class="barcell">${bar(p.dur / total)}</td></tr>`;
    if (inner) for (const s of stages) {
      rows += `<tr class="stage" data-p="${i}"><td>${esc(s.name)}</td><td class="num">${fmt(s.dur)}</td><td class="num">${s.count}</td><td class="num">${(s.dur / total * 100).toFixed(1)}%</td><td class="barcell">${bar(s.dur / total, 'var(--bar2)')}</td></tr>`;
    }
  });
  $('stages').innerHTML = rows;
  const toggle = tr => {
    const open = tr.getAttribute('aria-expanded') !== 'true';
    tr.setAttribute('aria-expanded', open);
    tr.querySelector('.caret').textContent = open ? '▾' : '▸';
    for (const s of $('stages').querySelectorAll(`tr.stage[data-p="${tr.dataset.p}"]`)) s.classList.toggle('shown', open);
  };
  $('stages').addEventListener('click', e => { const tr = e.target.closest('tr.phase.toggle'); if (tr) toggle(tr); });
  $('stages').addEventListener('keydown', e => { const tr = e.target.closest('tr.phase.toggle'); if (tr && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); toggle(tr); } });
})();

// Planner.
(function () {
  const p = R.planner;
  if (!p) { $('planner').innerHTML = '<tr><td class="muted">no plan</td></tr>'; return; }
  const order = ['workspaces', 'registry', 'listings', 'scan', 'resolve', 'plan'];
  let rows = `<tr><th>step</th><th class="num">time</th></tr>`;
  for (const k of order) if (k in p.steps) rows += `<tr><td>${k}</td><td class="num">${fmt(p.steps[k])}</td></tr>`;
  rows += `<tr><td class="muted">directories listed · files scanned · modules</td><td class="num">${p.directoriesListed} · ${p.filesScanned} · ${p.modules}</td></tr>`;
  $('planner').innerHTML = rows;
})();

// Critical path.
(function () {
  const c = R.criticalPath, byName = new Map(units.map(u => [u.name, u]));
  let rows = `<tr><th>module or link</th><th class="num">cost</th><th></th></tr>`;
  for (const name of c.units) {
    const u = byName.get(name), w = u ? (u.cost ?? u.dur) : 0;
    rows += `<tr class="unit" data-i="${u ? u.order : ''}"><td class="name">${esc(name)}</td><td class="num">${fmt(w)}</td><td class="barcell">${bar(w / (c.dur || 1), 'var(--crit)')}</td></tr>`;
  }
  rows += `<tr><td class="muted">total</td><td class="num"><b>${fmt(c.dur)}</b></td><td></td></tr>`;
  if (c.unrecorded.length) rows += `<tr><td class="muted" colspan="3">weighed by this build's time (no recorded cost): ${esc(c.unrecorded.join(', '))}</td></tr>`;
  $('critical').innerHTML = rows;
  $('critical').addEventListener('click', e => { const tr = e.target.closest('tr.unit'); if (tr && tr.dataset.i !== '') open(+tr.dataset.i); });
})();

renderUnits();
</script>
</body>
</html>
"""#
}

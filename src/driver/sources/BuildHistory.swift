import Foundation

// The build history (task 233): one per user, across every workspace on the machine. Every build's report page
// and a list page over them. The build hands each finished report to `record`, which stands in for a backend: it
// stores what it is given, and the build never reads the history back.
//
//   index.html          the list page, fixed; it loads `history.js`
//   history.js          one line per build, oldest first: `H.push({id, entry, workspace, started, dur, status});`
//   builds/<id>.html    the build's report page, as `build/_perf/index.html` had it
//   lock                held while a build writes, since builds in other workspaces write at the same time
//
// A page opened from disk cannot fetch a neighbouring file but can load a script, so the list is a script of
// appended lines: a build adds one line, whatever the history's length. The open list page reloads the script
// every two seconds to show new builds. Builds older than `maxAge` or beyond the newest `maxBuilds` are pruned
// as each build is added.
enum BuildHistory {
    static let maxBuilds = 1000
    static let maxAge: TimeInterval = 30 * 24 * 3600

    // The history's directory: `NOMU_HISTORY_DIR` when set; else the platform's per-user application data
    // (`~/Library/Application Support/nomu/history` on macOS, which the system does not clear as it may a cache;
    // `$XDG_STATE_HOME/nomu/history`, falling back to `~/.local/state/nomu/history`, elsewhere).
    static func root(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let dir = env["NOMU_HISTORY_DIR"], !dir.isEmpty { return dir }
        let home = env["HOME"] ?? "/tmp"
        #if os(macOS)
        return home + "/Library/Application Support/nomu/history"
        #else
        if let xdg = env["XDG_STATE_HOME"], !xdg.isEmpty { return xdg + "/nomu/history" }
        return home + "/.local/state/nomu/history"
        #endif
    }

    // The list page's `file://` URL, which each build's report page links to.
    static var listURL: String { URL(fileURLWithPath: root() + "/index.html").absoluteString }

    // One build's line in `history.js`.
    struct Entry: Codable {
        var id: String
        var entry: String       // the entry module
        var workspace: String   // the workspace's root directory
        var started: String     // ISO 8601, UTC
        var dur: Int            // wall time, µs
        var status: String
    }

    // Add the build to the history and return the list page's path, or nil (with a message) when it cannot be
    // written. A failure here leaves the build's own result alone.
    @discardableResult
    static func record(_ report: PerfReport, page: Data, workspace: String) -> String? {
        let dir = root()
        do { try FileManager.default.createDirectory(atPath: dir + "/builds", withIntermediateDirectories: true) }
        catch { fputs("error: cannot create '\(dir)/builds'\n", stderr); return nil }
        let lockFD = open(dir + "/lock", O_WRONLY | O_CREAT, 0o644)
        guard lockFD >= 0, flock(lockFD, LOCK_EX) == 0 else {
            if lockFD >= 0 { close(lockFD) }
            fputs("error: cannot lock '\(dir)/lock'\n", stderr); return nil
        }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }
        var id = report.started.filter { $0.isNumber }   // `20261101021530123`: sorts as it was built
        while FileManager.default.fileExists(atPath: dir + "/builds/" + id + ".html") { id += "x" }
        let entry = Entry(id: id, entry: report.entry, workspace: workspace, started: report.started, dur: report.dur,
                          status: report.status)
        guard PerfReport.replace(dir + "/builds/" + id + ".html", with: page),
              let json = try? encoder.encode(entry),
              append(dir + "/history.js", Data(("H.push(" + String(decoding: json, as: UTF8.self) + ");\n").utf8))
        else { return nil }
        prune(dir)
        let index = dir + "/index.html"
        let html = Data(listPage.utf8)
        if FileManager.default.contents(atPath: index) != html, !PerfReport.replace(index, with: html) { return nil }
        return index
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static func append(_ path: String, _ data: Data) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { fputs("error: cannot write '\(path)'\n", stderr); return false }
        defer { close(fd) }
        let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard n == data.count else { fputs("error: cannot write '\(path)'\n", stderr); return false }
        return true
    }

    // Drop the builds older than `maxAge` and those beyond the newest `maxBuilds`: their lines leave
    // `history.js` and their pages are deleted. Lines it cannot read are dropped with them.
    private static func prune(_ dir: String) {
        let path = dir + "/history.js"
        guard let text = FileManager.default.contents(atPath: path).map({ String(decoding: $0, as: UTF8.self) })
        else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let cutoff = Date().addingTimeInterval(-maxAge)
        let decoder = JSONDecoder()
        var keep: [Substring] = [], drop: [String] = []
        for (i, line) in lines.enumerated() {
            let body = line.dropFirst("H.push(".count).dropLast(");".count)
            guard line.hasPrefix("H.push("), line.hasSuffix(");"),
                  let e = try? decoder.decode(Entry.self, from: Data(body.utf8)) else { drop.append(""); continue }
            let old = parseISO8601(e.started).map { $0 < cutoff } ?? true
            if old || lines.count - i > maxBuilds { drop.append(e.id) } else { keep.append(line) }
        }
        guard !drop.isEmpty else { return }
        for id in drop where !id.isEmpty { try? FileManager.default.removeItem(atPath: dir + "/builds/" + id + ".html") }
        _ = PerfReport.replace(path, with: Data((keep.joined(separator: "\n") + (keep.isEmpty ? "" : "\n")).utf8))
    }

    // `2026-10-28T18:21:51.448Z`, as `PerfReport` writes it.
    private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static let listPage = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>nomu build history</title>
<style>
:root { --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --line: #e3e3e8; --row: #f6f6f8; --link: #2f5bd8; --fail: #c92a2a;
        --mono: ui-monospace, SFMono-Regular, Menlo, monospace; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #161618; --fg: #ececf0; --muted: #9a9aa3; --line: #2c2c31; --row: #1d1d21; --link: #91a7ff; --fail: #ff6b6b; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
main { padding: 24px 16px 64px; max-width: 1180px; }
h1 { font-size: 20px; margin: 0 0 4px; }
.muted { color: var(--muted); }
table { border-collapse: collapse; width: 100%; margin-top: 16px; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 5px 8px; border-bottom: 1px solid var(--line); white-space: nowrap; }
th { font-weight: 600; color: var(--muted); font-size: 12px; }
td.num, th.num { text-align: right; }
td.name { white-space: normal; word-break: break-all; font-family: var(--mono); font-size: 12.5px; }
tbody tr:hover { background: var(--row); }
a { color: var(--link); }
.pager { display: flex; gap: 12px; align-items: center; margin-top: 12px; }
.pager button { font: inherit; background: none; border: 1px solid var(--line); color: var(--fg); border-radius: 4px;
                padding: 2px 10px; cursor: pointer; }
.pager button:disabled { color: var(--muted); cursor: default; }
</style>
</head>
<body>
<main>
  <h1>nomu build history</h1>
  <div class="muted" id="count"></div>
  <table>
    <thead><tr><th>entry module</th><th>started</th><th class="num">duration</th><th></th></tr></thead>
    <tbody id="builds"></tbody>
  </table>
  <div class="pager" id="pager"></div>
</main>
<script>
// `history.js` pushes each build onto `H`. The page loads it again every two seconds while visible, as a new
// script (a page opened from disk cannot fetch a file), and redraws when the builds changed. It shows `PER_PAGE`
// builds at a time, newest first; the page number is the URL's `#page=N`.
const PER_PAGE = 50;
let H = [];
const esc = s => String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function fmt(us) {
  if (us >= 1e6) return (us / 1e6).toFixed(2) + ' s';
  if (us > 0 && us < 500) return '&lt;1 ms';
  return Math.round(us / 1e3) + ' ms';
}
let shown = null;
function pageNumber() {
  const m = location.hash.match(/^#page=(\d+)$/);
  return m ? Math.max(1, +m[1]) : 1;
}
function render() {
  const pages = Math.max(1, Math.ceil(H.length / PER_PAGE));
  const page = Math.min(pageNumber(), pages);
  const key = H.length + ' ' + (H[0] || {}).id + ' ' + (H[H.length - 1] || {}).id + ' ' + page;
  if (key === shown) return;
  shown = key;
  document.getElementById('count').textContent = H.length === 1 ? '1 build' : H.length + ' builds';
  const end = H.length - (page - 1) * PER_PAGE;
  document.getElementById('builds').innerHTML = H.slice(Math.max(0, end - PER_PAGE), end).reverse().map(b => `
  <tr>
    <td class="name" title="${esc(b.workspace || '')}">${esc(b.entry)}</td>
    <td>${esc(new Date(b.started).toLocaleString())}</td>
    <td class="num">${fmt(b.dur)}</td>
    <td><a href="builds/${encodeURIComponent(b.id)}.html">report</a></td>
  </tr>`).join('');
  document.getElementById('pager').innerHTML = pages < 2 ? '' :
    `<button data-page="${page - 1}"${page === 1 ? ' disabled' : ''}>← newer</button>` +
    `<span class="muted">page ${page} of ${pages}</span>` +
    `<button data-page="${page + 1}"${page === pages ? ' disabled' : ''}>older →</button>`;
}
document.getElementById('pager').addEventListener('click', e => {
  const b = e.target.closest('button[data-page]');
  if (b && !b.disabled) { location.hash = +b.dataset.page === 1 ? '' : 'page=' + b.dataset.page; window.scrollTo(0, 0); }
});
window.addEventListener('hashchange', render);
let loading = false;
function load() {
  if (loading) return;
  loading = true;
  const previous = H;
  H = [];
  const s = document.createElement('script');
  s.src = 'history.js?' + Date.now();
  s.onload = () => { loading = false; s.remove(); render(); };
  s.onerror = () => { loading = false; s.remove(); H = previous; };
  document.body.appendChild(s);
}
load();
setInterval(() => { if (!document.hidden) load(); }, 2000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) load(); });
</script>
</body>
</html>
"""#
}

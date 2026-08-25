# `for … in` + iteration protocol + ranges

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** M ·
**Status:** needs-design · **Source:** deferred.md (frontend surface group)

## What

`for x in xs`, range syntax (`0..<n`), and the iterator / sequence interface they lower to.

- The **iteration protocol** is the one non-frontend piece (a stdlib interface + how iteration
  borrows/owns).
- The loop lowering is frontend (to the existing `while`).

## Perf contract (decided 2026-08-19)

`for … in` is the **bounds-check-free-by-construction** iteration path (safe-by-construction,
Rust-iterator style) — so array iteration needs no bounds-check-elimination pass. The M7 BCE
loop-bound case was descoped in favor of this (`ssair.md`, BCE; `../ssair-backlog.md` §4).

## Roadmap assessment (three-head)

**One-liner pointer** — core surface; the iterator interface is a small design contract; it carries
the above perf-envelope commitment.

## Dependencies & triggers

- **Depends on:** a stdlib iterator/sequence interface ([stdlib-core](120-stdlib-core.md)).
- **Feeds:** the BCE descope (`../ssair-backlog.md`).

## Refs

deferred.md "Frontend surface features"; `ssair.md` (BCE); `../ssair-backlog.md` §4.

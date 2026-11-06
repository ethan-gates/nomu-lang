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
loop-bound case was descoped in favor of this (`ssair.md`, BCE; `148-ssair-optimizer-tier.md` §148.4).

## Iterator design

Iteration is independent of concurrency. Compute loops must compile to the code of a hand-written loop,
which rules out running an iterator on its own fiber.

- **The protocol is pull:** a value with `next()`, as in Rust and Swift. It needs no suspension.
- **`yield`, if added, is push-style sugar:** the producer calls the loop body as a closure, as in Go's
  range-over-func, so `yield` is an ordinary call and needs no suspension either.
- **No coroutine-backed iterators and no use of the scheduler.** A coroutine costs a record, a stack and a
  switch per item. A pull adapter over a push iterator, if one is ever needed, is a separate question.
- **No async iterator split.** Functions are colorless, so `next()` may block on I/O like any other call.
- **Channels implement the protocol,** so `for x in ch` works. This is the only link to the concurrency
  surface ([channels](102-channels.md)).

## Roadmap assessment (three-head)

**One-liner pointer** — core surface; the iterator interface is a small design contract; it carries
the above perf-envelope commitment.

## Dependencies & triggers

- **Depends on:** a stdlib iterator/sequence interface ([stdlib-core](120-stdlib-core.md)).
- **Feeds:** the BCE descope (`148-ssair-optimizer-tier.md` §148.4).

## Refs

deferred.md "Frontend surface features"; `ssair.md` (BCE); `148-ssair-optimizer-tier.md` §148.4.

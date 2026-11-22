# Loop improvements: `for … in`, iteration, and loops that keep a bounds check

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · perf · needs-design` · **Size:** M–L ·
**Status:** needs-design · **Source:** deferred.md (frontend surface group); 117.2 from
[245](245-loop-strip-mining.md)

## Phases

- **117.1 `for … in`, ranges and the iteration protocol** (below). Syntax needs agreement.
- **117.2 Loops that keep a bounds check reload their arrays after strip mining.** A loop whose bounds check
  stays (a computed index, `a[i * n + k]`; a stride, `m += p`; an exit that depends on data) exits early to the
  trap, so its loads of an array's count and buffer pointer do not run on every path through an iteration.
  With loop polls strip-mined, the chunk loop reloads them every iteration; with no polls at all, LLVM keeps
  them in registers. On `tools/loopbench.py`: `matmul` 22%, `insertion` 20%, `sieve` 10% behind the no-poll
  build. The experiment that dropped the poll placeholder's `deopt` bundle to test LLVM's
  invariant-load peeling is void: its build ran with `--verify-cache`, which failed on the changed output and left
  the previous binary, so peeling is not ruled out (an experiment that changes codegen through the environment
  needs a fresh `NOMU_CACHE_DIR`). Leads: removing the check itself (range facts for a computed or strided index, in SSAIR or
  at the LLVM level; [148](148-ssair-optimizer-tier.md).4); marking an array object dereferenceable, so its
  count and buffer loads can be hoisted without running on every path; strip mining earlier in LLVM's
  pipeline, before the passes that keep those loads in registers. 117.1 removes the check from loops over a
  collection or range; computed indices and data-dependent exits keep it.
- **117.3 Re-measure once 117.1 lands.** Rewrite the kernel set's loops that fit `for … in`
  (`benchmarks/loop_kernels`) and run `tools/loopbench.py`: those loops should reach the no-poll speed.

## 117.1 · `for … in`

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

**Re-measure:** once this lands, re-run the dense-layout benchmark against Go (`practice/gen/dense/run.py`, `practice/go/dense`; [196](196-dense-value-layout.md) 196.9) for the array scans, without a bounds check per element.

## Refs

deferred.md "Frontend surface features"; `ssair.md` (BCE); `148-ssair-optimizer-tier.md` §148.4.

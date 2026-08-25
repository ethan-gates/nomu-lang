# Self-hosting the runtime: GC + scheduler in Nomu, bootstrapped in assembly

**Avenue:** Risk (author north-star) · **Type/Lifecycle:** `perf · refactor · needs-design` (runtime +
language subset + compiler + GC) · **Size:** XL · **Status:** design-early, build-late (decided
2026-08-18) · **Source:** deferred.md (2026-08-18)

## What

Rewrite the runtime — the GC and the M:N scheduler — in Nomu itself, compiled by the Nomu compiler,
with a small per-architecture assembly floor to bootstrap (context switch, entry / TLS / stack setup,
the pre-runtime moment). The model is Go's: a runtime in the language plus arch-specific asm stubs.
Replaces MMTk (Rust, ~26 MB link archive) and the C runtime (`runtime.c` / `core.c`).

## Three goals (author's framing)

1. **Remove Rust and C** — a pure Nomu + assembly runtime; no foreign-language dependency in produced
   binaries.
2. **Performance** — the runtime compiles through the same optimizing backend (SSAIR + LLVM), so
   runtime ops (alloc fast path, write barriers, scheduler hooks) inline into user code across the
   former runtime/user boundary, the way Go's in-language runtime does.
3. **Binary-size ceiling < 999 KB** — with GC/scheduler present and essential (no reliance on
   dead-stripping them out), the whole self-contained runtime still fits a tiny footprint. Removing
   the 26 MB MMTk archive is the enabler; monomorphization + DCE keep only the runtime paths a
   program uses.

## Why it's architecturally enormous

- **A runtime-Nomu subset.** GC/scheduler code must avoid recursively invoking the services it
  implements: no implicit GC alloc, no write barrier, no unplanned safepoint, controlled stack growth.
  Needs a mechanism analogous to Go's runtime pragmas (`//go:nosplit`, `//go:nowritebarrier`,
  `//go:noescape`) — new surface + new checking.
- **Bootstrap floor.** The irreducible per-arch assembly (context switch, thread/TLS/stack setup,
  entry sequence before collector + scheduler are live).
- **Collector replacement + [LXR](127-lxr-collector.md) overlap.** The collector in Nomu may be one effort
  with LXR — decide whether to fold.
- **Compiler support.** Emitting code that satisfies the runtime-subset constraints, the
  asm-interfacing calling convention, and the bootstrap linkage.

## Base prerequisites

- **[Unsafe raw pointers / raw-memory primitives](125-unsafe-raw-memory.md)** — a hard floor (the
  collector + allocator manipulate untyped memory).
- The runtime-subset mechanism and stdlib low-level primitives (byte buffers).

## Trigger / sequencing

Implementation is very late (needs a mature, performant Nomu — M7 optimizer, M9 backend — plus the
prerequisites). **Design early, build late (decided 2026-08-18):** settle the runtime-subset mechanism
and the unsafe raw-pointer surface ahead of time so later decisions don't foreclose this, even while
the build waits. Naturally paired with (or subsuming) the [LXR](127-lxr-collector.md) effort.

## Refs

deferred.md "Self-hosting the runtime"; `runtime.md` (scheduler, safepoints, mutator);
`memory-model.md` §3 (`VMBinding`); `backend.md`; [LXR](127-lxr-collector.md),
[unsafe raw memory](125-unsafe-raw-memory.md).

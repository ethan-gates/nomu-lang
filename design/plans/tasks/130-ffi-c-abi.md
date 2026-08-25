# First-class FFI to the C ABI

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` (runtime + GC + codegen)
· **Size:** L · **Status:** needs-design (substrate partly grounded) · **Source:** deferred.md
(2026-08-18) + roadmap ("Ongoing")

## What

Direct, low-overhead interop with the C ABI as a primary feature — call C functions, pass/return
C-compatible types, expose Nomu functions to C, hold C-side callbacks. "First-class" means cheap
calls, layout-compatible structs (`c-types.md`), and an ergonomic binding surface (over today's
hand-written shims).

## Why architecturally heavy (moving GC + colorless concurrency)

- **Pinning.** A managed pointer handed to C must stay put while C holds it — direct coupling to the
  moving Immix collector's relocation.
- **Foreign-thread attach.** A C thread calling into Nomu must attach: acquire a mutator context,
  register roots, participate in safepoints (`runtime.md` §5).
- **Safepoint transition.** A fiber inside a C call can't reach a safepoint, so the runtime marks
  in-C as parked/blocked (like syscall offload), with the leaf-call vs may-call-back distinction (a
  callback re-enters the runtime).
- **Marshalling + ownership.** C ABI type mapping (structs, `String`, pointers), who owns
  passed/returned memory (malloc heap vs GC heap), copy-vs-borrow at the boundary.

## Perf envelope

The pin/unpin + safepoint-transition cost per call decides hot-path usability. First-class means the
common leaf call approaches a raw C call; keep the boundary thin.

## Trigger / sequencing

Currently "Ongoing" on the roadmap. The substrate (attach + pinning) rides the runtime; the surface
benefits from [modules](100-modules.md) (binding organization) and matters once real C libraries are
wanted. Settle the pinning + safepoint-transition model before the surface is built. Note:
[stdlib I/O](120-stdlib-core.md) does **not** need this — the privileged C runtime exposes I/O builtins;
FFI enters only under [self-hosting](128-self-hosting-runtime.md) (pure-Nomu I/O calling libc) or for
user bindings.

## Roadmap assessment

**Yes — promote from "Ongoing" to a first-class design question.** All three heads; the moving
collector makes this harder than a non-moving runtime would.

## Refs

deferred.md "First-class FFI to the C ABI"; `c-types.md`; `runtime.md` §5 (attach + pinning), §6
(safepoints); `backend.md`.

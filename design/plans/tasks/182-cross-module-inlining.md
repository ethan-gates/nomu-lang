# Cross-module inlining & inlinable stdlib

**Avenue:** Risk (the "faster than Swift/Go" perf substrate) · **Type/Lifecycle:**
`perf · frontend · codegen · modules` · **Size:** L · **Status:** not started — write **after**
[100 modules](100-modules.md) lands (it extends the module-interface format); measurement-gated (no
String-ops gap today — see [121](121-string-utf8-model.md)) · **Source:** split from the String-performance
investigation ([121](121-string-utf8-model.md)) and the scattered inlining mentions in
[148](148-ssair-optimizer-tier.md) / [100](100-modules.md), which left the module-boundary inline story
unowned.

## What

Make a function **inlinable across the module boundary**, and in particular make the core stdlib/prelude ops
(the `String` byte layer, `Array`, …) inline into client code **without LTO** — the Swift
`@inlinable`/`@_transparent` and Rust `#[inline]`/generic-IR model. Three layers:

1. **Cross-module inline policy.** Decide which exported functions carry their body in the module interface
   for a consumer to inline — an `@inlinable`-equivalent (an annotation and/or a small-leaf heuristic), plus
   the recorded decision. The interface format ([100](100-modules.md)) already serializes NOIR bodies (`.bir`)
   for *generic* cross-module specialization; this extends that to non-generic inlinable functions.
2. **Consumer-side inlining of imported bodies.** The intra-module `Inline` pass
   ([148](148-ssair-optimizer-tier.md), built) runs over SSAIR. This decodes an imported inlinable callee's
   serialized body into the consumer's SSAIR before that pass, so a cross-module call to an inlinable function
   inlines exactly like a local one — and sidesteps the addrspace-across-calls wall for that callee (the
   *non-inlined* cross-module case is what [179](179-value-level-gc-classification.md) dissolves; inlining
   avoids it outright).
3. **Inlinable runtime / core primitives.** The runtime's hot leaf ops are C today, compiled into a separate
   `.a` and opaque to the optimizer (e.g. `String`'s `bytePointer`/`count`/`byte(at:)` → `__string_*`), so
   they are the one case that genuinely forces LTO. Give them a non-LTO path. Options to weigh:
   - **(a) Intrinsic lowering** — a *general* builtin-expansion facility where a core op declares its IR
     expansion and codegen emits it inline (Swift `@_transparent` builtins, Rust intrinsics, LLVM intrinsics).
     Not per-op hand-coding in the egress — a table/registry the egress consumes generically.
   - **(b) IR-visible runtime** — compile `runtime.c`/`core.c` to bitcode and link as IR so LLVM's inliner
     reaches the leaves (LTO). Generic across all runtime calls, but the C-shaped answer and the heaviest
     build change.
   - **(c) Stdlib-in-Nomu** — write the primitives in Nomu over word-access primitives, so layer 2 inlines
     them like any Nomu function.

   (a) and (c) match how Swift/Rust ship fast core types without LTO; (b) is the fallback C forces.

## Why

- A cross-module call to a small stdlib op is a call per op today. At the module boundary a core-type
  operation (string compare, byte read, array index) should cost what a local call does. Swift/Rust/Go reach
  that by making the stdlib **inliner-visible** (serialized bodies / intrinsics), not by LTO; C is the outlier
  that needs LTO, and Nomu resembles C only because its runtime is C. This task gives the non-LTO path.
- It is the **general mechanism** behind several per-feature perf notes
  ([121](121-string-utf8-model.md) String byte layer, [178.1](178-runtime-gc-performance.md)/178.2,
  [148 §148.1](148-ssair-optimizer-tier.md)'s post-inline EA). One facility makes core ops inline across the
  boundary rather than hand-inlining each op in the egress (which is the anti-pattern this task exists to
  avoid).

## Why after 100, and why measurement-gated

- The inlinable bodies live in the **module interface format**, which [100](100-modules.md) settles. Building
  the policy + serialization before that interface is fixed would be redesigned when it changes — so this
  lands after 100 (or interleaves with its interface-format work, not before it).
- Benchmarking in [121](121-string-utf8-model.md) shows **no String-ops gap today**: byte scan ~125M/s, `eq`
  ~1.4B byte-compares/s, all un-inlined, and `-O` (the O2 inliner) does not move them. So this is not urgent
  for `String`; it is the general capability for a fast cross-module stdlib and the home for "how do core ops
  inline without LTO." Build it when a cross-module hot path measures a real call-overhead gap.

## Dependencies & relationships

- **Builds on [148 SSAIR optimizer tier](148-ssair-optimizer-tier.md)** — the intra-module `Inline` pass
  (built) and [§148.3](148-ssair-optimizer-tier.md)'s cost model. 148 owns intra-module inlining and its
  refinements; **182 owns the cross-module policy + feeding imported bodies to that pass + stdlib/runtime
  inlinability.**
- **Extends [100 modules](100-modules.md)** — its interface format carries the inlinable bodies (the analog of
  Swift `.swiftmodule` `@inlinable` SIL / Rust rlib MIR). Sequenced after 100.
- **Relates to [179 value-level GC classification](179-value-level-gc-classification.md)** — the
  addrspace-across-calls wall that non-inlined cross-module calls hit. Inlining an inlinable callee sidesteps
  it; 179 dissolves it for the calls that stay non-inlined. Complementary.
- **Home for the cross-module/stdlib-inlining half of** [121](121-string-utf8-model.md) (String byte layer)
  and [178](178-runtime-gc-performance.md) 178.2.

## Refs

[121](121-string-utf8-model.md) (the String-perf investigation that surfaced the gap and the non-LTO
question); [148 §148.3](148-ssair-optimizer-tier.md) (intra-module inliner); [100](100-modules.md) (module
interface format); Swift `@inlinable`/`@_transparent`, Rust `#[inline]`/crate-metadata, Go cross-package
inliner (prior art).

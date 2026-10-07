# Shaped GC roots — value-conditional scanning + frame-root relocation

**Avenue:** Risk (the moving-collector precision substrate) · **Type/Lifecycle:**
`gc · codegen · midend` · **Size:** L · **Status:** designed — mechanism settled; ready to build ·
**Source:** split out of [121 String](121-string-utf8-model.md) (the GC capability the bit-stealing
`String` rests on) and [148 §148.1](148-ssair-optimizer-tier.md) (the addrspace-across-calls placement
route, formerly "route (c)"). **Design home:** [`../../internals/shaped-roots.md`](../../internals/shaped-roots.md).

## What

Make a managed pointer's **rooting** and **placement** a compiler-emitted *shape* the collector reads,
rather than a property fixed entirely by its LLVM `addrspace(1)` type. Three capabilities, layered:

1. **Value-conditional scanning.** A managed pointer that lives inside a value aggregate and is a
   reference only for some runtime discriminant. The collector reads the discriminant word, then traces
   the pointer word in exactly the cases that hold a reference. The motivating case is `String`'s
   bit-stealing word (`word1` is a heap buffer in `heap`, inline UTF-8 bytes in `small`, an immortal
   buffer in `immortal`); it generalizes to any tagged value that carries a reference in some cases
   (`Option<SomeClass>`, `Result<Buffer, E>`).

2. **Relocation takeover for shaped roots.** A value-conditional word cannot be typed `addrspace(1)` —
   that would relocate the inline-bytes case as if it were a pointer — so it cannot ride LLVM
   `gc.relocate`. For a shaped root whose target may move, the compiler pins the value to a stack slot
   across each safepoint (store-before / load-after), records the slot and its shape in the stack map,
   and the collector performs the conditional relocation itself: read the discriminant, relocate the
   pointer word in the reference cases, write the new address back into the slot. The post-call load
   observes the update, standing in for `gc.relocate`'s reload. The added mutator cost is a spill/reload
   around safepoints for a live shaped value — level with an ordinary root.

3. **Frame-root placement for escape-promoted values.** The same facility — a stack slot carrying a
   compiler-described field pointer-map the collector scans — is [148 §148.1](148-ssair-optimizer-tier.md)'s
   route (c). A value proven non-escaping is placed in a frame slot whose managed fields the collector
   scans in place, so a promoted object crosses a non-inlined call keeping its unmanaged placement
   instead of taking the `addrspace(1)` heap representation. This clears the addrspace-across-calls wall
   that blocks interprocedural stack promotion today.

Both collectors consume the shape descriptor identically: the MMTk-binding codegen type-maps
(`LLVMGenGCMaps`) and the self-hosted tracer (`rtWalkFrom` + the flat offset loops in
`src/stdlib/runtime.nomu`) must agree on it.

## Why

A moving collector rewrites a managed pointer wherever it finds one, so it needs each pointer's location
exactly. Today that precision comes entirely from LLVM statepoints keyed on `addrspace(1)`
(`internals/backend.md`, "GC backend substrate"), where a single type encodes three decisions at once:
that a value is a managed reference, that the collector roots and relocates it at every safepoint, and
that it travels as a heap pointer. Inference wants to vary the second and third without touching the
first. Two independent features hit the same wall:

- **Bit-stealing `String` ([121](121-string-utf8-model.md)).** A 16-byte representation packs inline
  bytes into the same word that holds the heap-buffer pointer in other cases, so that word's
  managed-ness is per-value and dynamic — unreachable by a type-driven root set.
- **Interprocedural stack promotion ([148 §148.1](148-ssair-optimizer-tier.md)).** A value proven not to
  escape a non-inlined callee should be placed on the stack, but the callee's reference parameter is
  `addrspace(1)` and no `addrspacecast` survives a safepoint, so the promotion cannot land.

Both are the same shortcoming: rooting and placement are welded to `addrspace(1)`. This task decouples
them with a shape-aware root path, so a managed value can be tag-discriminated or stack-placed while the
collector still finds and fixes up exactly the references that are live.

## Keep the fast path

- Ordinary heap roots stay on stock LLVM statepoints. Only shaped roots take the side path, so
  non-shaped code is unchanged and un-regressed.
- Keep the return-address-keyed stack map — the property `backend.md` chose statepoints for over a
  shadow stack (no per-call tax). Shaped roots extend the record; they do not add cost to code that has
  none.
- The reclaimed responsibility is **root interpretation** (is this word a reference now, and does it
  move) plus a narrow slice of **placement** (pin-to-slot for shaped values). LLVM keeps doing liveness,
  spilling, and stack-map emission. This is the piggyback/parallel end of the gradient, not a wholesale
  replacement of `RewriteStatepointsForGC`.

## Phases

- **176.1 — value-conditional *tracing* descriptor** (read-only). The collector finds the discriminant
  word + the pointer word and traces the pointer only in the reference cases. Enough for a shaped root
  whose target does not move (a pinned / immortal buffer). This is the smaller, lower-risk half.
- **176.2 — relocation takeover** (pin-to-slot store/load + conditional writeback), so a shaped root's
  target can be relocated and compacted. This is the default `String` needs: [121](121-string-utf8-model.md)
  chose moving string buffers for the generational-nursery and fragmentation wins, so string buffers are
  ordinary movable heap objects, not pinned.
- **176.3 — frame-root placement route** for escape promotion ([148 §148.1](148-ssair-optimizer-tier.md)
  route (c)): a frame slot plus a field pointer-map the collector scans, letting a promoted object cross
  a non-inlined call without the heap representation. Rides the done inference stack that proves
  non-escape (166 / 168 / 169 / 164).

## Dependencies & relationships

- **Unblocks [121 String](121-string-utf8-model.md).** The 16-byte bit-stealing `word1` needs 176.1
  (conditional tracing) and 176.2 (moving buffers). The 121.1 immortal+heap interim, where `word1` is
  uniformly a managed-or-null buffer pointer, rides the existing struct-field GC rule and can precede
  this task; 176 gates the `small` / SSO case where `word1` holds inline bytes.
- **Is [148 §148.1](148-ssair-optimizer-tier.md)'s parked placement decision** (route (c)); 176.3 is the
  build. The inference track it was waiting on ([164](164-formal-inference-stage.md)) is done, and the
  escape summary it consumes is [169](169-interprocedural-escape-summary.md).
- **Rests on** the statepoint / stack-map substrate (`internals/backend.md`, "GC backend substrate") and
  the GC type-descriptor machinery (`LLVMGenGCMaps`, `internals/memory-model.md` §6).
- **Couples with** scalar promotion's reference-like-field widening ([148 §7.3.1 A2](148-ssair-optimizer-tier.md)):
  a bit-stealing `String` field is value-conditional, so its treatment as a loop-carried φ member must
  agree with the shaped-root model.
- **Both collectors** must stay in lockstep — the codegen type-maps and the self-hosted Nomu tracer — or
  the GC-stress suite legs break.
- **Independent perf follow-up:** [177 register-resident GC roots](177-register-resident-gc-roots.md) —
  whether LLVM's `max-registers-for-gc-values` lever helps ordinary roots, and if so whether a shaped root
  can share it. 176 ships on the stack-slot form regardless; 177 is a later optimization on top.

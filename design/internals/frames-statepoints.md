# What Nomu built on LLVM's statepoints, and where it fell short

One of the frames design documents ([frames.md](frames.md)); the output of task 240. It lists what Nomu uses LLVM's
statepoints and stack maps for, file by file, then every problem they have caused, each with its root
cause, whether it is the machinery's or Nomu's, and whether replacing the machinery would remove it. Tasks
241 (the contract) and 242 (the candidate designs) work from it.

## How the pieces fit

Every function Nomu emits a body for is marked `gc "statepoint-example"`. Managed references are typed
`ptr addrspace(1)`; everything else is `addrspace(0)`. The LLVM pipeline runs the optimizer first and
`rewrite-statepoints-for-gc` (RS4GC) last: `default<O3>,rewrite-statepoints-for-gc` in release,
`function(mem2reg,sroa),always-inline,rewrite-statepoints-for-gc` in debug. RS4GC turns each call not
marked `gc-leaf-function` into a `gc.statepoint`, finds the `addrspace(1)` SSA values live across it, and
rewrites their later uses to `gc.relocate` results. The backend spills those values to stack slots at the
call and records the slots in `__llvm_stackmaps`, keyed by the call's return address.

At a collection, the runtime walks each fiber's stack: it looks each return address up in a sorted index
the driver writes after the link, reads the record's slots, and overwrites each with the object's new
address. After the call, the code reloads the slots.

Around that core Nomu built a second path for values RS4GC cannot see (*shaped roots*: a `String`'s buffer
word, an enum payload that holds a reference), and a third for buffers whose type is known only at run time
(erased generics: a shadow stack).

## What the machinery provides, and where it is used

| piece | what Nomu uses it for | where |
|---|---|---|
| `addrspace(1)` and `gc "statepoint-example"` | marks a value as a managed reference, and a function as one RS4GC rewrites | `LLVMGen.swift` (`p1`), `LLVMGenRuntime.swift` (`emitFunction`), `LLVMGenLayout.swift` (type mapping) |
| RS4GC | finds live references at each non-leaf call, inserts `gc.relocate` | `LLVMBridge.swift` (the pipeline) |
| `gc-leaf-function` | keeps calls that never reach a collection from becoming statepoints | `LLVMGenRuntime.swift` (`gcLeafRuntimeFns`, `markGCLeaf`, `markCallGCLeaf`) |
| `"deopt"` operand bundles | carry shaped roots: an `i32` shape ordinal and a frame slot's address, which lands in the record as a `Constant` and a `Direct` location | `LLVMGenRuntime.swift` (`buildCallWithDeopt`, `pendingDeopt`), `SSAIRToLLVM.swift` (`shapedDeoptOps`, `emitHeaderPoll`), saved and restored around nested emission in `EgressConcurrency.swift`, `EgressBuiltins.swift`, `LLVMGenWitness.swift` |
| `__llvm_stackmaps` records | the root slots of each frame at each call (`Indirect` locations), the shaped roots (the deopt range) | read by `stackwalk.nomu` (`rtCollectRoots`, `rtWalkFrom`); relocated in place by `collect.nomu` |
| the per-function `StackSize` | the walker's frame size: it steps to the caller by `SP += StackSize`, with no frame-pointer chain or unwind tables | `stackwalk.nomu` (the pcsp walk), `FrameIndex.swift` (copied into the index) |
| the section itself | located with linker section-bracket symbols; kept alive under `-dead_strip` with `.no_dead_strip __LLVM_StackMaps` | `SSAIRToLLVM.swift` (`__gcStackmapBase`), `LLVMBridge.swift` |
| `llvm.frameaddress`, `llvm.returnaddress` | the anchor where a walk starts: a `noinline` function reads its caller's SP and return address | `LLVMGenRuntime.swift` (`emitCallerAnchor`, `schedForwarder`, `nomuAllocSlow`), `stackwalk.nomu` |

Built around the machinery, Nomu's own pieces:

- **Shape analysis and recording** (`ssair/sources/Shape.swift`, `ShapedLiveness.swift`): one `shape(T)` per
  type; which values and frame slots hold shaped content and where they are live; which slots to record
  (`recordedSlots`). The egress gives each such value a frame home and reloads its managed words `volatile`
  after a safepoint (`loadReloading`). `SSAIRVerify.swift` checks I11 (shaped content across a safepoint is
  recorded) and I12 (no derived pointer across a safepoint).
- **Shape tables** (`LLVMGenGCMaps.swift`): an ordinal per shaped type, resolved through a per-object table
  the index entry names.
- **The frame index** (`driver/sources/FrameIndex.swift`): after the link, read the binary's stackmaps and
  the linker map, drop folded duplicates, write a sorted index into a reserved section, re-sign the binary.
- **The typed-root shadow stack** (`SSAIRToLLVM.swift`, `rtShadowPush`/`rtShadowPopTo`; walked by
  `rtWalkShadow`): a linked list of `{prev, buffer, vwt}` nodes in the caller's frame, one per erased-generic
  buffer holding managed content, around the call.
- **Walk anchors and forwarders** (`LLVMGenRuntime.swift`): the allocation slow path and every scheduler
  call that parks are `noinline` functions that record their caller's `(sp, pc)` so the walk starts at the
  last Nomu frame; the forwarder itself has no GC strategy.
- **The address barrier** (`LLVMGenRuntime.swift`, `managedAddress`): the write barrier reads an object's
  address through side-effecting inline asm so the optimizer cannot hoist it (176.5.8, below).

## The problems

Each entry: what happened, why, whose it is, and whether a replacement would remove it. *Machinery* means
the cause is in LLVM's statepoint design or implementation; *Nomu* means it is in how Nomu used it.

### Managedness is a type

1. **A value that is a reference only sometimes cannot be a root.** `String`'s first word is a heap buffer
   pointer in one case and inline bytes in another. Typed `addrspace(1)`, the bytes would be relocated;
   typed `i64`, the pointer is invisible. RS4GC asks one question of a value, its type's address space
   (`GCStrategy::isGCManagedPointer(Type*)`). *Machinery.* Nomu built shaped roots on deopt bundles to work
   around it (176), at the cost of every problem in the next section. A replacement that records what the
   compiler knows per value removes it.
2. **A stack-promoted object cannot cross a non-inlined call.** The callee's parameter is `addrspace(1)`;
   the promoted object is a frame address, and no `addrspacecast` from 0 to 1 is accepted across a
   safepoint. Interprocedural stack promotion is blocked (148 §148.1); closure environments are never
   promoted for the same reason (`StackPromotion.swift`, "the `p1` env-param addrspace wall"); a nested
   promoted object with a managed field would make an `addrspace(1)` field point at a frame slot that RS4GC
   relocates as heap (148). *Machinery.* 179 proposed forking RS4GC's predicate; a replacement removes it.
3. **The spawn environment crosses as `addrspace(0)`.** A fiber's environment is handed through the runtime
   as a raw pointer, and casting it back to `addrspace(1)` is the cast RS4GC rejects, so the spawn routine
   takes it as `addrspace(0)` and reloads each capture as its own root (`SSAIRToLLVM.swift`, spawn
   routines). *Machinery*; a workaround in place.

### Shaped roots ride a mechanism built for deoptimization

4. **A deopt operand does not mark its memory written.** After the call LLVM forwards the pre-call value
   of a recorded slot, so the collector's write-back is missed. Every post-safepoint read of a managed word
   in a recorded slot is a `volatile` load (I11a; `loadReloading`), which also stops ordinary optimization
   of those loads (178.2 tracks narrowing it). An inline-asm memory clobber, the natural fix, fails: RS4GC
   tries to make the asm call a statepoint and the module fails verification. *Machinery.*
5. **The reload was missed for wrapped types: stale `String` reads (176.5).** The `volatile` was applied
   only to loads typed `StringBase`; a `let s: String` slot holds the `String` wrapper struct, so its load
   was plain and kept the old buffer address in registers. Up to 2,750,148 wrong reads of 3,000,000 under a
   small heap. Cause: six places decided shapedness separately. *Nomu*, made possible by problem 4: a
   mechanism where forgetting a reload is silent. Fixed by one `shape(T)` read by every consumer.
6. **A sub-field address records as `Indirect` and is dropped.** A deopt operand `gep(slot, off)` with a
   non-zero offset is spilled and recorded as `Indirect`, where the walkers expect `Direct`; the root is
   silently lost. Recording only bare alloca bases, with offsets in the shape descriptor, avoids it.
   *Machinery* (how deopt operands lower).
7. **Bundles do not survive inlining or leaf calls.** The always-inliner drops a deopt bundle on the call
   it collapses, so the allocation and poll hit paths are emitted in place when shaped roots are live
   (`emitAllocHitPath`, `emitSafepointPollWithDeopt`), and a `noinline` wrapper (`__nomu_gc_alloc_rooted`)
   keeps a bundle to the rewrite at one more frame and call (223). A bundle on a `gc-leaf` call is
   mishandled by the backend, so it must never be attached to one (`isGCLeafFn`). *Machinery.*
8. **A stack-map constant cannot hold a link-time value.** A shape is recorded as a per-compile ordinal
   resolved through a side table. Tables from different objects collided: a module's ordinal resolved in
   another module's table, printing `19561` for `7114012` with no crash (195). Fixed with per-object tables
   the index names. *Machinery* (the format), with the per-compile numbering *Nomu*'s.

### The optimizer runs blind to safepoints

9. **RS4GC runs last, so the optimizer sees no safepoints.** It must, since RS4GC tracks only SSA values
   (mem2reg and SROA must run first even at `-O0`) and optimizing after it would see the spill and reload
   traffic. The cost is that any transformation that turns a pointer into something RS4GC cannot relocate
   is invisible until it breaks. *Machinery* (the pass ordering the design requires).
10. **The write barrier tested a moved object's old address (176.5.8).** The barrier's fast path turns the
    object pointer into an integer for its range and log-bit tests. Inlined before RS4GC, the `ptrtoint` was
    hoisted out of a loop at `-O3`; after a collection promoted the object, the barrier tested its old
    nursery address and never remembered the store (4,788 wrong reads per run, release only). RS4GC
    relocates pointers only; an integer derived from one keeps the old address. Fixed by reading the address through side-effecting
    inline asm. *Machinery* (problem 9), found only by a tight-nursery test leg.
11. **The current-stack walk depends on an optimizer side effect.** `rtCollectRoots` reads its callers'
    slots through a pointer derived from `llvm.frameaddress`, and the caller spills its live roots at the
    call only because that memory effect appears in the function it calls directly. Moving the loop into a
    helper made the caller's roots vanish from the record (`selfhosted-gc.md` §9). The loop is kept inline
    and copied into `rtWalkFrom`. The root cause was not established; the walk reads frame memory through
    a path LLVM does not model as a use of the caller's values, and works only while the optimizer happens
    to keep them in memory.
12. **An empty struct cannot be a call argument.** RS4GC fails on LLVM's empty type `{}` ("Empty type
    passed to intrinsic"), so a field-less struct gets a one-byte placeholder (`LLVMGenLayout.swift`).
    *Machinery*; minor.

### Stack maps do not reach everything that holds a reference

13. **Erased-generic buffers are opaque.** A buffer whose type is a type parameter is a byte array to LLVM,
    so its managed content has no record. Nomu added a second root mechanism, the shadow stack, with a
    per-call push and pop (100.4.3.6). Under MMTk only one walker read it, and a value passed through an
    erased generic was rooted nowhere during the call (176.5.6). *Machinery* (stack maps describe values of
    static type), with the split mechanism *Nomu*'s.
14. **Derived pointers are banned across safepoints.** Statepoints support base/derived pairs, but shaped
    roots record bases, so Nomu forbids any interior pointer live across a safepoint and re-derives after
    (I12). *Nomu*; a constraint a replacement can keep or lift.
15. **Raw stack addresses are not described at all.** Statepoints record `addrspace(1)` values; frame
    addresses (stack-promoted objects, struct-return and by-reference slots, the shadow-stack nodes, and
    any such address LLVM keeps in a callee-saved register) are live across calls with no record. The
    Statepoints documentation lists "Objects on the Stack" and "Mixing References and Raw Pointers" as
    half-done. This is what blocks copying stacks (104). *Machinery*; the main reason for 194.

### The format and the linker

16. **Stack maps were lost across objects (195).** Each object brings its own `__llvm_stackmaps` blob; the
    linker places them back to back, and both walkers read only the first. Frames from every other object
    had no records: missed roots in one walker, an ended walk in the other. Fifteen GC crashes in 190.4.2
    were this. *Nomu* (the walkers' reading), on a format with no directory.
17. **No index, and a large format.** Records are variable length with no directory, so a reader steps
    every record to find one: 3.5–6 ms at a million records, over the 1 ms setup budget. A record is about
    68 bytes (12 per location, three meta constants), about 68 MB for a 2M-line program. Nomu built the
    link-time index (195), which patches the binary after the link and re-signs it. *Machinery* (the format
    is designed for a JIT's in-memory module).
18. **The linker cannot transform the records per function.** Each object's records are one blob, so
    dead stripping keeps every function that has a record, used or not (229); weak and folded duplicates
    keep their records bound to the kept copy (195 drops them by reading the linker map). *Machinery.*

### Costs and constraints carried

19. **Every live reference is spilled and reloaded at every safepoint.** `max-registers-for-gc-values`
    defaults to 0, and the walkers read only stack-slot (`Indirect`) locations, so a register location
    would be skipped silently. Keeping roots in registers is measured in 177. *Machinery* default, with the
    walker's limit *Nomu*'s.
20. **The leaf list is maintained by hand.** A call missing from `gcLeafRuntimeFns` becomes a statepoint
    with a record and a spill; a wrongly listed call is unsound. 223 found `rt_raw_alloc` and `rt_raw_free`
    not leaf, which gave the runtime object 518 needless records (964 to 446, 64 KB of section to 30 KB).
    *Nomu*; any mechanism needs to know which calls can reach a collection, which the call graph could give.
21. **The walk assumes a frame layout.** The pcsp walk finds the caller's frame record at CFA−16 and the
    frame pointer as `x29`, steps by `StackSize`, and treats a frame of dynamic size (an erased generic's
    runtime-sized buffer) through the saved frame pointer. arm64 and Mach-O specific. *Nomu*.
22. **`musttail` and statepoints** are noted as friction for guaranteed tail calls (129), not yet
    investigated.
23. **Managed pointers are in an integral address space.** The datalayout comes from the target machine
    unchanged (`e-m:o-…`, no `ni:1`), so LLVM may turn an `addrspace(1)` pointer into an integer and back,
    which RS4GC cannot relocate (problem 10's shape). Tasks 121 and 179 assume `ni:1` is set. No such
    round-trip was found in the suite's post-optimization IR (release adds 2 `inttoptr`s over debug); the
    gap was latent. *Nomu*; one datalayout setting, now set (243, claim 6).

## Summary

| # | problem | owner | open? | removed by a replacement? |
|---|---|---|---|---|
| 1 | conditional references cannot be roots | machinery | worked around (176) | yes |
| 2 | stack-promoted objects cannot cross calls | machinery | open (148.1, 176.4) | yes |
| 3 | spawn environment cast | machinery | worked around | yes |
| 4 | deopt operands not modeled as written; `volatile` reloads | machinery | worked around (178.2) | yes, if the mechanism models the write |
| 5 | stale `String` reads | Nomu | fixed (176.5) | the cause, problem 4 |
| 6 | sub-field address dropped | machinery | worked around | yes |
| 7 | bundles lost to inlining and leaf calls | machinery | worked around | yes |
| 8 | ordinals cannot be link-time values | machinery + Nomu | fixed (195) | yes |
| 9 | optimizer blind to safepoints | machinery | inherent | depends on the design |
| 10 | barrier tested an old address | machinery (9) | fixed (176.5.8) | depends on the design |
| 11 | walk depends on an optimizer side effect | not established | constrained | depends on the design |
| 12 | empty struct argument | machinery | worked around | yes |
| 13 | erased buffers need a shadow stack | machinery + Nomu | in place | depends on the design |
| 14 | no derived pointers across safepoints | Nomu | constraint | can be kept or lifted |
| 15 | stack addresses undescribed | machinery | open (104) | the purpose of 194 |
| 16 | stack maps lost across objects | Nomu | fixed (195) | — |
| 17 | no index; large records | machinery | worked around (195) | yes |
| 18 | no per-function linker transforms | machinery | open (229) | yes, with a per-function format |
| 19 | spill and reload at every safepoint | machinery default + Nomu | measured in 177 | depends on the design |
| 20 | leaf list by hand | Nomu | in place | needs the same knowledge |
| 21 | arm64 frame-layout assumptions | Nomu | in place | — |
| 22 | `musttail` | unknown | not investigated | — |
| 23 | managed pointers in an integral address space | Nomu | fixed (`ni:1`, 243) | — (a datalayout setting) |

**Reading it.** Of the 23, 15 trace wholly or partly to the machinery. Most fall in four groups:
managedness fixed by type (1–3), deopt bundles repurposed from deoptimization (4,
6–8), the optimizer running before safepoints exist (9, 10, 12), and a format designed for a JIT's single
in-memory module (17, 18). Problem 15 is outside what statepoints try to do. The Nomu-side problems are fixed, are bookkeeping any
design shares (20, 21), or are a missing setting (23). The two bugs that reached wrong output silently (5, 10) were found only by test legs
that reuse moved-from memory quickly, which is the argument for 194's stress modes.

## Refs

Tasks [176](../plans/tasks/176-shaped-gc-roots.md), [177](../plans/tasks/177-register-resident-gc-roots.md),
[179](../plans/tasks/179-value-level-gc-classification.md), [195](../plans/tasks/195-link-time-gc-frame-index.md),
[229](../plans/tasks/229-dead-strip-safepoint-code.md), [223](../plans/tasks/223-retire-the-c-floor.md),
[148](../plans/tasks/148-ssair-optimizer-tier.md), [129](../plans/tasks/129-tail-call-optimization.md),
[104](../plans/tasks/104-fiber-stack-strategy.md); [shaped-roots.md](shaped-roots.md),
[selfhosted-gc.md](selfhosted-gc.md) §9, [ssair.md](ssair.md) (I11, I12), [backend.md](backend.md) §2;
[LLVM Statepoints](https://llvm.org/docs/Statepoints.html).

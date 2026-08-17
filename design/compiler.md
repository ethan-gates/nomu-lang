# Compiler & Toolchain

**Status:** working draft. The home for how Nomu is built — compiler architecture, the mid-level IR, backend strategy, the tooling-first stance, and the debugger plan. Status tags: **Decided**, **Deferred**, **Open**.

**Implementation language:** Swift (decided) for the compiler itself.

---

## 1. Mid-level IR above the backend

A typed **mid-level IR** sits between the parser and the code-generation backend; semantics-aware passes run on *this* IR, then lower to the backend (analog: Swift's SIL). — **Decided; the IR and the semantic pass that builds it were implemented in M4.9.**

**Two representations, Rust-staged.** The pipeline is `source → lexer → parser (untyped AST) → semantic pass → typed IR → IR passes → codegen (emit C)`. There are deliberately only two trees: the untyped **AST** (parser output) and one **typed structured IR** the semantic pass builds *directly* from it — no separate "typed AST" step, because our AST is immutable `enum`s and can't be annotated in place the way Swift decorates its mutable AST. Our typed IR ≈ **Rust's THIR**; the lower CFG/SSA level (the **M7 optimizer tier** — precise escape analysis, devirtualization, etc.; not yet built, NOIR lowers straight to LLVM today) ≈ **Rust's MIR / Swift's SIL**.

**Altitude — structured, not CFG/SSA.** The IR keeps `if`/`switch`/loops as nested nodes and closures first-class, so codegen stays mechanical and the C backend keeps structured control flow. Every node is **typed** and carries a **source span** — debug info threaded from the start (cheap now; retrofitting is miserable) and preserved by every pass.

**The semantic pass** (name/scope/member/method resolution, expression typing, call/argument checking, return checking) produces the IR and reports **collected diagnostics** (collect-and-continue, not exit-on-first-error). It replaced the old ad-hoc type tracking in codegen (`typeOf` + a `Scope: [String:String]` string map) with a real internal **`Type` model**: `int`/`bool`/`string`/`void`, `named(name, kind ∈ {struct, enum, class, actor})`, `function(params, ret)`, and `error` (suppresses cascades); backed by symbol tables and a lexical scope stack. M5 extends the model (`typeParam`, existentials, generic instances). (POD and let/var checks still run in a small separate AST pass before the semantic pass; an **extension-merge pass** — M4.12 — also runs on the AST before it, folding plain `extension T { … }` methods into their target type's member set so the semantic pass sees one type with all its methods. M5 Phase A's conformance extensions reuse that merge seam. Extension model: `interfaces.md` §1.)

**The IR is the M5 seam.** Member/method dispatch is resolved in the IR — a method call names its concrete target — so codegen never re-resolves. M5 extends this: the call node gains a dynamic/witness form for `any`, and generic calls carry witness arguments.

Passes over the mid-level IR:
- **exhaustiveness checking** — *implemented (M4.9)*; runs on the typed IR, the altitude Rust uses (THIR).
- **mutation analysis** — *implemented (M4.11)*; infers each method's mutating-ness (writes to `self`, transitively through self-calls) and validates `let`-field / `self` writes (`types.md` §3).
- **share analysis** — materializing shareability into module interfaces (`concurrency.md` §5). *Currently still in codegen* (spawn-capture + actor-handler-param checks); migrates to an IR pass with M5's shareability work.
- **closure conversion** — *currently still in codegen* (closures stay first-class in the IR); promoted to a pass later.
- **monomorphization** — M5.
- **escape analysis** (`memory-model.md` §6.1) — M6.
- **GC safepoint / barrier insertion** — M6.

The backend (LLVM) does not understand the language's semantics, so running these passes on LLVM IR would be the wrong altitude.

(The pass list changed with the memory-model pivot: ARC insertion / refcount elision / isolation-region checks are gone; escape analysis and GC barrier/safepoint insertion take their place, and monomorphization gains importance as a performance lever.)

---

## 1a. The optimizer tier — SSAIR (M7)

**Status:** working draft, spec-first. The tier itself is **Open** (design in progress); the pieces below are marked **Proposed** unless a prior decision pins them. This section is the **design home** (the *why* + the shape); the **ordered build plan** (phases 7.1–7.5, exit criteria) lives in `m7-spec.md`.

**One-line intent.** **SSAIR** is a lower, control-flow-explicit, SSA intermediate representation — a separate IR from NOIR (its own types, dumper, files), the level where the language-aware optimizations that carry the "faster than Swift/Go" thesis run. Structured NOIR (§1) lowers into SSAIR; SSAIR lowers to LLVM. It is Nomu's analog of **Rust's MIR / Swift's SIL**, sitting below THIR-altitude NOIR and above LLVM IR. (Named 2026-08-14; the sibling to NOIR, both ending in IR.)

### Why a separate tier (the altitude argument)

LLVM optimizes at the wrong altitude for four wins Nomu needs, because by the time code is LLVM IR the language facts are erased:

- **Precise escape analysis** — LLVM will not un-heap a `__nomu_gc_alloc` call; it sees an opaque runtime call, not an allocation whose lifetime we can prove local (`memory-model.md` §6.1).
- **Devirtualization of witness-table calls** — an `any I` / generic dispatch is an indirect call through a loaded function pointer at the LLVM level; the fact that the concrete conformer is knowable is a Nomu-level fact, gone by codegen.
- **Bounds-check elimination** — the check is a Nomu semantic guarantee on `index`; LLVM sees a compare-and-branch with no knowledge that it is redundant with a prior check or a loop bound.
- **Inlining + specialization on our type info** — on top of the existing whole-program monomorphization (M5), driven by Nomu-level cost and type knowledge rather than LLVM's post-lowering heuristics.

Structured NOIR can't host these either: they need **def-use chains and a CFG to follow values across control flow**, which the nested `if`/`switch`/`while` tree lacks. The conservative escape pass shipped in M6 (`EscapeAnalysis.swift`; `memory-model.md` §6.1) is exactly what you can do without them — intra-procedural, single-walk, no flow sensitivity — and its ceiling is why the precise pass waits for this tier.

**Design against the whole tenant set at once (Decided 2026-08-13, roadmap M7).** SSAIR is shaped to serve precise EA, devirtualization, BCE, and inlining/specialization together, so its form is validated against all four before it freezes. Building it for one pass would bake in a shape the others fight.

### Position in the pipeline

```
source → lexer → parser (AST) → semantic pass → NOIR (structured, §1)
       → monomorphization (M5)
       → LOWER TO SSAIR  ← the M7 tier
       → optimizer passes (EA, devirt, BCE, inline/specialize)
       → lower to LLVM IR → statepoint rewrite → object code
```

The tier lands **after monomorphization** (passes see concrete types, no type parameters) and **before LLVM lowering**. **Single path (Decided 2026-08-14):** SSAIR does not sit beside the old lowering — the SSAIR→LLVM step *replaces* today's direct NOIR→LLVM (`lowering.swift`). Both debug and release run `NOIR → SSAIR → LLVM`; debug runs SSAIR with zero (or few) passes, release runs the full set. Two paths exist only transiently during 7.1 — the pre-M7 compiler is the differential oracle — and the old direct path is deleted once the new path is verified. This resolves the earlier debug-routing question: debug routes through SSAIR, it does not skip it.

### IR shape (Proposed)

- **Functions are a CFG of basic blocks.** Each block is a straight-line list of instructions ending in one **terminator** (`br`, `condBr`, `switch`, `ret`, `unreachable`). Structured control flow from NOIR (`if`/`switch`/`while`, `break`/`continue`) lowers to blocks + terminators here — the one place the structured tree is flattened.
- **SSA values with block arguments** (the Swift/MLIR style) rather than φ-nodes — cleaner to construct from a tree-walk and to manipulate in transforms. Each value is typed (carry the NOIR `Type`) and dominance is explicit.
- **Explicit memory + allocation ops.** `alloc` (the site EA reasons about, still lowering to `__nomu_gc_alloc` by default), `load`/`store` with the **GC address space** attached (addrspace 1 = managed, 0 = stack), field GEPs, and the **write-barrier** as an explicit op so barrier elision is a pass over this IR. This is what lets precise EA rewrite an `alloc` to a stack slot and drop the barriers that fed it.
- **Explicit dispatch ops.** A call carries its dispatch kind — `direct` (known target), `witness` (through a witness-table slot, the devirt target), or `indirect` (closure/fn-pointer). Devirtualization is a rewrite from `witness` to `direct`, which then unlocks inlining.
- **Closures lowered to explicit environments.** Closure conversion (still in codegen today, §1 pass list) moves here: a closure becomes an explicit env struct + a direct/indirect call, so the optimizer sees the capture set as ordinary values (feeds scalar-capture EA, §6.5.3).
- **Pattern matches lowered to decision trees / switch terminators** — exhaustiveness already checked upstream (§1), so this tier sees only the lowered branch form.

**Preserved by construction (the invariants every pass must hold):**
- **Types** on every value (concrete post-mono).
- **Source spans** on every instruction — debug info is threaded from the front and **must survive every pass** (§1, §4); the DWARF quality the debugger rests on depends on it. A transform that drops a span is a bug.
- **GC precision info** — address spaces and which values are managed roots, so the statepoint rewrite downstream still sees precise roots.

### Pass framework (Proposed)

- **Two pass kinds:** *analyses* (produce side tables keyed by value/site identity, mutate nothing — e.g. the escape result, dominator tree, alias facts) and *transforms* (rewrite the IR, invalidating analyses). The M6 conservative EA already uses the side-table shape, so its precise replacement slots into the same consumer contract in codegen — the codegen half is **reused unchanged** (`memory-model.md` §6.1).
- **A pass manager** with explicit analysis dependencies + invalidation. Small and hand-rolled first; no need to mirror LLVM's.
- **Ordering (Proposed):** devirtualize → inline/specialize → (EA, BCE) on the now-concrete, inlined bodies. Devirt-before-inline matters: turning a `witness` call into a `direct` call is what makes it an inlining candidate, and inlining is what makes intra-procedural EA and BCE see across the old call boundary. Precise EA benefits most after inlining exposes local allocation lifetimes.

### First tenants

1. **Precise flow-sensitive escape analysis** (completes the escape-analysis direction, `memory-model.md` §6.1). Def-use + CFG let a pointer be followed across branches and through the now-explicit closure envs; lifts the conservative pass's "any call argument escapes" to an interprocedural summary after inlining. Replaces the EA front-end; the codegen consumer is unchanged. Also clears the M6 conservative pass's deferred tail (non-scalar closure captures, `any`-boxes, statically-bounded arrays) that the structured pass couldn't reach.
2. **Devirtualization** of `witness`/`any` calls where the concrete conformer is known (a `some`/opaque underlying, a monomorphized instance, or a locally-constructed box). Rewrites `witness` → `direct`.
3. **Bounds-check elimination** on `index` — redundant-with-dominating-check and provable-in-range-of-loop-bound cases.
4. **Inlining + specialization** on top of monomorphization, driven by Nomu type/cost info.

The IR is designed so all four compose (see ordering above), rather than as four independent bolt-ons.

### Lowering out to LLVM (rebased `lowering.swift`)

The SSAIR→LLVM step is today's `lowering.swift` with its **input rebased** from the structured tree to SSAIR — the GC-ABI emission (address spaces, the `__nomu_gc_alloc`/`__nomu_write_barrier`/`__nomu_poll` hooks, object/witness/any-box layout, the `gc "statepoint-example"` attribute, calls) is preserved in one place, and the traversal changes from tree-walk to CFG-walk. The rebase also *simplifies* it: control-flow flattening moves into the lowering-in step (SSAIR already has explicit blocks + terminators), and alloca-per-scalar-local goes away (SSAIR values are direct), which removes the mem2reg-before-statepoint dependency for scalars — LLVM receives already-in-SSA values, so the statepoint rewrite sees SSA-valued GC pointers directly. The mapping is close to mechanical: blocks → LLVM basic blocks, SSA values → LLVM values, block args → LLVM φ, the `alloc`/`store`/barrier/dispatch ops → the existing emitted forms. Statepoint insertion stays **late** (post-opt, at the LLVM level, §2). GC precision preservation through the tier's transforms is a stated invariant with a test obligation (`m7-spec.md` §7.0.5).

### Build phases

The ordered build plan is `m7-spec.md`: **7.1** modularization (split the frontend monolith into per-stage modules + split `lowering.swift`, so SSAIR + passes land granular), **7.2** SSAIR + inert lowering (differential-tested behaviorally identical to the pre-M7 compiler before any pass runs, then the old direct path is deleted), **7.3** pass manager + precise escape analysis (the largest single-pass impact), **7.4** devirtualization, **7.5** inlining/specialization + BCE. Each pass phase is independently microbenchmarkable and gated behind an A/B disable flag (the escape / inline-alloc precedent), so a regression is bisectable and the tier is switchable wholesale.

### Open questions

- **Inlining cost model** — what drives the heuristic (callee size, call-site hotness, specialization).
- **Debug info through inlining** — inline-site DWARF records, or defer.
- **Interprocedural EA summary depth** — how much survives without whole-program fixpoint; monomorphization's whole-program view may make a cheap summary enough.
- **Artifact/dump format** and **alias/effect model** (§7.0.6 in the spec).
- **Interprocedural EA summary** — how much survives without whole-program iteration to fixpoint; whether monomorphization's whole-program view makes a cheap summary enough.
- **Artifact/dump format** for the tier and whether it reuses the NOIR dumper or needs its own.
- **Alias/effect model** — how much aliasing precision the passes need before the cost outweighs the win.

---

## 2. Backend strategy

- **Prototype: emit C or bind a simple backend** — throwaway scaffolding to get native execution fast and validate the surface + type system + runtime integration without building production codegen. — **Decided (direction).**
- **Release builds: LLVM**, for peak native performance, driven via a stable interface. — **Decided (post-prototype).**
- **Debug/dev builds: consider Cranelift** for fast compiles. — **Deferred** (past M9 — a later fast-compile play once LLVM iteration pain bites).
- **MLIR** if heavy language-specific optimization is wanted. — **Not pursued for M9 (2026-07-31)**; plain LLVM. Reconsidered only if heavy custom optimization is later wanted.

**M9 mechanism — Decided; M9 built (2026-08-03).** (M9 is done — 8.1–8.4 and the 8.5.2/8.5.3 perf items; its dedicated build-plan spec was retired once it shipped, as was the M6 GC spec — the GC-substrate facts M6 rests on are folded into the "GC backend substrate" note below.) Drive LLVM via its **C API** (`import LLVM_C`) from Swift (Decided 2026-08-01): importing LLVM's **C++** modules via Swift cxx-interop does not build (`Format.h` `operator<<` ambiguity under interop), whereas the C API builds/links/runs and covers IR + `TargetMachine` + `DIBuilder` + pass pipeline (incl. `rewrite-statepoints-for-gc`). Full C++ reach stays available through a **thin C++ shim** (ordinary C++, no interop) for rare C-API gaps (`DIBuilder` variant parts, custom passes). LLVM is brought in via the **`llvm/llvm-project` Bazel overlay** (`http_archive` at a pinned commit → `@llvm-project//llvm` `cc_library` targets), built from source and hermetic. `swift-llvm-bindings` evaluated and not used. (The earlier "hand-written C++ shim" is the fallback for gaps, not the primary path.) **GC roots via LLVM statepoints** (`addrspace(1)` + `statepoint-example` + RewriteStatepointsForGC → stack maps the MMTk binding reads as precise roots) — chosen as the *most performant* precise-root mechanism for a moving collector (return-address-keyed stack maps, as HotSpot/.NET; the shadow-stack alternative taxes every call and is rejected on performance). The mutator-performance levers are the **inlinable alloc/barrier/poll seams** — the alloc bump-pointer fast path, the write barrier (the dominant cost under LXR's RC), and the safepoint poll are emitted **inline** at the LLVM level, only slow paths as calls; statepoints inserted **late** so opts run first. Lower the **structured typed IR straight to LLVM** (no bespoke MIR until escape analysis needs it, §1). Scope is **LLVM-only, minimal-correct** — no MLIR, no Cranelift, no incremental in M9.

**GC backend substrate (as built, M6 · 2026-08-12).** The facts the moving GC rests on, folded here when the M6 spec retired (the shipped compiler + runtime are the record):

- **Three inline seams** (`internal alwaysinline`, `Lowering.swift`), shipped inert in M9 · 8.4 and filled by M6:
  - `__nomu_gc_alloc(i64 size) -> ptr addrspace(1)` at every managed allocation — a statepoint (not `gc-leaf`); M6 filled the per-carrier bump-pointer TLAB fast path (load cursor/limit, bump, branch to `rt_alloc` slow path).
  - `__nomu_write_barrier(obj, slot, val)` — `gc-leaf`, at every managed-reference field write; M6 filled the generational logging barrier (GEP the header from `obj`, test the logged bit, log on first mutation). The header and barrier are co-designed so the logged bit sits where an interior GEP from `obj` reaches it in one step.
  - `__nomu_poll()` — `gc-leaf`, at the header of loops reaching no other safepoint; M6 filled the branch-on-flag form (`runtime.md` §6).
- **`mem2reg`/`sroa` before the statepoint rewrite is a correctness prerequisite**, not just perf: the lowering puts every local in an `alloca`, and `RewriteStatepointsForGC` tracks only SSA-value GC pointers, so promotion must run first or almost no roots are found. Pipeline: `function(mem2reg,sroa),…,rewrite-statepoints-for-gc` (debug) / `default<O2>,rewrite-statepoints-for-gc` (release); the rewrite runs **last** either way. Every emitted function carries `gc "statepoint-example"`.
- **`gc-leaf` classification** (callers skip the statepoint): leaf = `printf`, `rt_str_lit`, `rt_mutex_new/unlock`; non-leaf/statepoint = `rt_alloc`, `fiber_spawn`, `spawn_join`, `rt_sleep_ms`, `rt_read_line`, `rt_mutex_lock`, and (once `String` became a GC object) the allocating `rt_str_concat`.
- **Stack-map parser + root walk** ship in `runtime.c`: `nomu_gc_stackmap_init` parses `__llvm_stackmaps` (v3) into a return-address → GC-slot index; `nomu_gc_walk_current` drives a libunwind cursor reporting each live root (SP-relative slots, callee-saved registers recovered per frame). Precise (excludes dead-on-stack objects). A parked fiber's saved `ucontext` is walked the same way (`runtime.md` §6).
- **Object header** is a subdivided `i64` (mark/log bits + type-id; the vestigial `refcount` dropped). Class/actor objects are `{ header, fields… }`; the object model's size/scan tables are in `c-types.md`.

LLVM is right eventually but is a big time sink that obscures the early questions, so the prototype gets native execution by a cheaper route first. The **GC integration (via MMTk)** is the real, new backend work:

- **precise stack maps / safepoints** (needed because Immix/LXR move objects),
- **the object model** (how to scan an object for references),
- **write-barrier insertion**.

This is the gating runtime engineering and must be co-designed with codegen.

---

## 2a. Symbol mangling (C backend) — Decided (M4.15)

Generated Nomu symbols share C's global namespace, so an unmangled name matching a libc symbol (`abs`, `read`, `free`, `time`, …) is a compile/link collision (surfaced when the prelude's `abs` clashed with libc `abs`). Every **globally-visible generated identifier** is therefore mangled through **one module — `src/codegen/sources/Mangle.swift`** (the single swap point; the scheme can be replaced by rewriting that file).

- **Scheme:** fully-qualified `nomu_<module>_<scope…>_<symbol>` — the module, any enclosing scopes, then the symbol, each **9-encoded** (reversible) and joined by `_`, so the join is unambiguous (a literal `_` becomes `90`, a `.` becomes `91`, the escape `9` becomes `99`). Escape and codes are **all digits** deliberately: letters are never rewritten, so every letter in a mangled name is a real source letter and words stay readable (a digit run is machinery). A top-level symbol has no scope (`abs` → `nomu_main_abs`); a method's scope is its type (`Rect.area` → `nomu_main_Rect_area`). The **module is an implied `main`** until real modules exist (`modules.md`). Plain names stay readable; noise appears only on underscores, dots, and the rare digit-`9`. Fully de-mangleable.
- **Scope:** free functions, nominal types, methods / actor handlers, enum value tags (+ the tag enum type), and synthesized constructor / `release` / `deinit`. **Not** mangled: struct fields and locals/params (scoped in C, so no global collision) and runtime ABI symbols (`rt_*`, `String`, `Closure`, `printf`…). **`main` → `nomu_main`** is the sole exemption — the runtime entry calls it by that fixed name.
- **Why this scheme (priority order: no-collision > readable > de-mangleable > perf):** ruled out the naive `_`-join (ambiguous on underscores/overloads); rejected `$` (a GCC/Clang extension, not ISO C) and `__`/leading-`_` delimiters (**reserved by the C standard** — UB / libc-internal clashes); rejected Itanium-style dense mangling and disambiguator hashes (unreadable, and perf/size is the lowest priority). 9-encoding is portable ISO C, reversible, and clean for the common case; the digit escape (vs. GHC's letter `z`) keeps letters readable as words.
- **Forward (M5+):** the module segment is already in the grammar (real module names replace the implied `main` when modules land); extend `Mangle` to encode **generic type arguments** for monomorphized instances (e.g. `Box<Int>`) and **arg types** if/when overloading is wired into codegen — all additive to the same grammar.

---

## 3. Tooling-first / query architecture

Architect the compiler **as a server** from early on — query-based, so an LSP can cheaply ask "what's the type here?", with incremental compilation and stable parser error-recovery. — **Decided (architectural commitment).**

Great tooling (Rust, TypeScript) comes from designing the compiler as a server early, not bolting an LSP on later. Tooling is one of Nomu's deltas over Nim and a first-class deliverable, so this is committed up front while it's still cheap.

---

## 4. Debugger

Do **not** build a debugger from scratch. **Emit DWARF and extend lldb.** — **Decided.**

Choosing LLVM + native binaries means breakpoints, stepping, unwinding, watchpoints, and remote/time-travel debugging already exist on our binaries the moment we emit correct debug info (Rust and Swift both took this route). The real work is making existing tools understand *our* semantics — the abstraction gap widened by monomorphization, match lowering, closures-as-structs, and fibers suspended across the scheduler. DWARF is the bridge; its quality depends on debug info surviving every IR pass (§1).

**Tiered plan:**
- **Tier 0 (near-free):** DWARF line tables + basic types → breakpoints, stepping, backtraces, primitive inspection.
- **Tier 1:** DWARF 5 **variant parts** for enums (discriminant + payload, as Rust does) + reference/value layout + **lldb data formatters** (render an enum as its active case, a COW array as its contents).
- **Tier 2:** GC-aware stepping (skip compiler-inserted barrier/safepoint frames so stepping stays in source); a debug-build mode that limits escape-analysis/optimization so inspection works.
- **Tier 3 (hard, differentiating):** a **runtime-aware plugin** presenting a *logical* view — reconstruct backtraces across suspension points, list live tasks by their structured-scope tree, inspect actor state + pending mailbox. The structured-concurrency + actor model makes this possible in a way Go's detached goroutines can't.

**Pragmatics:** target the **Debug Adapter Protocol** (lldb ships `lldb-dap`) → every editor for free. On Linux, **`rr`** gives reverse/time-travel debugging on standard native binaries.

Exposing runtime structures (task tree, actor mailbox) with a stable layout must be co-designed with the runtime, not bolted on.

---

## 5. Library tiers (language / runtime / stdlib)

The build realizes a three-layer separation (positioning in `vision.md` → "Library tiers"):

- **Language** — the compiler-known surface (type system, generics, interfaces, linear types, and a small named set of blessed intrinsics such as the continuation).
- **Runtime** — the mandatory floor: GC (MMTk) + the M:N scheduler/poller. **Always linked** — there is no runtime-less build, because Nomu declines to define reference types or heap allocation without it.
- **Standard library** — ordinary Nomu code with no compiler privilege, and **elidable**.

Two deployment shapes fall out: **language + runtime** (no batteries; minimal footprint) and **+ stdlib**. The consequence for the compiler: privileged capabilities (`park`/`unpark`, GC intrinsics) are reached only through **language/runtime intrinsics**, never handed to a stdlib function that user code couldn't itself call — that is what keeps the stdlib pure and elidable. — **Decided (2026-07-16).**

## 6. C backend → LLVM transition checklist

Things to revisit when the C codegen is replaced by the LLVM backend (M9). The C backend is scaffolding — these are the known gaps.

- **Preamble → runtime library** — everything in `emitPreamble` (fiber scheduler, timer heap, poller, `rt_alloc`, `String`, `Closure`) becomes a compiled `.a` the LLVM backend links against; no more per-file inlining.
- **`ucontext` → hand-written assembly** — `swapcontext`/`makecontext` replaced with ~20-line arm64 + x86-64 assembly (avoids the macOS signal-mask syscall on every fiber switch).
- **`int64_t` for `Bool`** — `Bool` currently maps to `int64_t`; LLVM should use `i1`/`i8`.
- **GCC statement expressions** — `({ ... })` is not valid C99 and has no LLVM IR equivalent; audit the emitter for any remaining uses before the switch.
- **Safepoints** — the moving GC (MMTk/Immix, M6) needs precise safepoints at call sites and loop back-edges; insert via LLVM's statepoint intrinsics or a custom pass.
- **Precise stack maps** — the GC must scan parked fiber stacks; the LLVM backend must emit stack maps (the C backend has none).
- **Write barriers** — Immix requires write barriers on pointer stores; the C backend has none; the LLVM backend inserts them in codegen.
- **`rt_alloc` header trick** — `rt_str_concat` reaches behind `ObjectHeader` via pointer arithmetic; replace with a proper allocation API the GC can understand.
- **Bump-and-leak allocator** — `rt_alloc` uses `calloc`; goes away entirely when MMTk lands (M6); all allocations must go through the GC API.
- **`ObjectHeader` refcount field** — vestigial (used only by the old actor release path, not a real GC header); remove when MMTk takes over.
- **Debug info** — the C backend gets DWARF from `cc` for free; the LLVM backend must emit its own via `DIBuilder`.
- **Actor mutex** — `pthread_mutex_t` embedded in actor structs; should become a fiber-aware mutex (park/unpark) to avoid blocking a carrier while a handler is held.

---

## 7. Open questions

- **Runtime language + MMTk binding (M6).** — MMTk is Rust and exposes a C ABI; the irreducible Rust is a `VMBinding` binding crate, while callers can stay C. Open: keep the runtime (scheduler/allocator) in C with a thin Rust binding and codegen-inlined alloc fast path + barriers, vs. move the runtime to Rust for cleaner MMTk integration (rewrites the M4 scheduler). Codegen target stays C either way (emitting Rust rejected — `unsafe`-everywhere, throwaway before LLVM). Decided (2026-07-21) to **defer to M6** and proceed under two invariants (held through M5) so every M6 option stays open: (1) **single allocation seam** — every heap allocation goes through one codegen-controlled call (`rt_alloc` today), so the allocator can be swapped for MMTk's with a localized change; (2) **explicit, scannable object model** — the M5 object shapes (`any` boxes, witness tables, generic instances) carry a clear header and discoverable pointer layout, so a C or Rust binding (and later LLVM-emitted barriers/maps) can scan them precisely — no representation tricks that assume conservative-only scanning, and the `rt_alloc` header pointer-arithmetic hack (§6) is to be dropped with the M6 object-model work.
- **GC precision vs. backend (M6 ↔ M9 coupling).** — **Resolved (2026-07-30): M9 (LLVM) precedes M6.** A moving collector (Immix) needs **precise stack maps**, which the C backend can't emit (§6). The C-path bridges — a **shadow stack** (portable, throwaway) or **conservative scanning** (pins, fights moving and muddies the footprint numbers under test) — were rejected because M6's purpose is to validate the *performance* thesis, which those degrade. So LLVM statepoints supply precise roots first, then the moving collector rests on them (`roadmap.md`; the GC backend substrate is in §2 above). Parked fiber stacks are scanned precisely via per-fiber saved SP/PC + frame maps (`runtime.md` §6).
- ~~**MLIR vs. plain LLVM** for the release backend~~ — Resolved: plain LLVM, MLIR not pursued for M9 (§2).
- **Cranelift** for fast debug builds — deferred past M9; when it earns its place (§2).
- **Incremental compilation + cached monomorphizations** — the shape that keeps LLVM iteration bearable.
- **Runtime-structure layout** for the Tier-3 debugger plugin — co-designed with the scheduler/actor runtime (`concurrency.md`).

---

## 8. Pipeline boundary hardening (deferred)

The M4.9 pipeline (parse → semantic pass → typed IR → passes → codegen) is built as the **minimal amount to get something working**. The boundaries between phases warrant a deliberate later pass — careful consideration, not now. The checklist to revisit:

- **Per-phase input→output testing** — golden tests at each boundary (source→tokens, tokens→AST, AST→typed IR, →C), so every phase is independently verifiable.
- **Phase output formats designed for speed** — the serialized form of each phase's output (AST, typed IR) chosen to be fast to read/write, so caching and tooling aren't bottlenecked.
- **Format stability** — versioned, backward-compatible boundary formats, so cached artifacts survive compiler changes (a prerequisite for incremental).
- **Parallelism** — where phases, or per-decl/per-function work within a phase, can run concurrently.
- **Incremental compilation** — recompute only what changed; ties to the query-based architecture (§3) and cached monomorphizations (§7).
- **Per-phase debuggability** — inspect/dump each phase's output in isolation. `ASTDump` exists for the AST; M4.9 added a **typed-IR dump** (`--dump-typed-ast`); dumps for later phases remain to extend.
- **Interface/implementation module split** (M7 §7.1, Decided 2026-08-16) — each IR is its own **interface module** (format: types + dump), separate from the **implementation modules** that produce/consume it (`support` | `ast`/`parse` | `noir`/`sema` | `midend` | `ssair`/`ssairgen`/`ssairpasses` | `llvmgen`). The interface module is the structural home for the phase-output-format and format-stability items above, and the dependency-surface the query architecture (§3) memoizes against. Landing as the first M7 slice (`m7-spec.md` §7.1).

Hooks already in place that keep the door open: the IR carries debug info/spans from the start (§1), `ASTDump` gives a dump pattern to extend, and §3 commits to the query/incremental direction. The hardening itself is deferred until the minimal pipeline works end to end. — **Deferred (noted 2026-07-21); the module split lands in M7 §7.1.**

**Architecture evaluation (2026-07-30).** Checked whether the code is quietly foreclosing the three committed capabilities (debug info §1/§4, fine-grained incremental §8, query server §3), under the rule that C-backend-only limits are throwaway and only frontend/IR/LLVM-path gaps count. Findings: **debug info** is safe (the span invariant is held; the missing `#line` is C-backend-only). **Fine-grained incremental** (intra-module, per-file — "20 files, edit 2, rebuild 2") and the **query server** are the *same* engine (memoized per-decl queries + fingerprint invalidation); its prerequisites (multi-file input, per-unit codegen, dependency/fingerprint layer) are unbuilt but not foreclosed, and the soundness property that makes it work — **modular checking** (bodies depend only on referenced signatures) — is held. The **one live blocker** is in the frontend, which survives to LLVM: the lexer/parser/typechecker **`exit(1)` on first error** with no recovery, contra the §3 server commitment. Actionable frontend backlog: `src/frontend/README.md`.

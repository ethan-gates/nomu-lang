# Memory Model

**Status:** working draft. The home for how Nomu represents and manages memory — the value/reference split, the collector, immutability, escape analysis, the performance recipe, and every binding form's memory meaning. Status tags: **Decided**, **Deferred**, **Open**.

**Pivot note (2026-07-15):** Nomu manages reference-type memory with a **tracing garbage collector (MMTk)**, not ARC. The earlier bet — *isolation earns non-atomic reference counting* — is retired, along with the machinery that served it (`shared`, atomic/non-atomic RC, region/uniqueness inference, `send`-for-memory, freeze-on-share, ORCA, `weak`/`unowned`). All of it existed to reach memory safety without a GC; MMTk removes the reason for it.

---

## Memory model in brief

- **Reference types are GC-managed.** Backend is MMTk (generational Immix to start; an LXR-style reference-counting collector as the footprint endgame — a collector swap, not a language change). Cycles are collected automatically; there is no `weak`/`unowned`, no refcount in the surface, no manual break.
- **Value types are copied**, laid out inline. Escape analysis keeps non-escaping objects off the heap (invisible optimization).
- **Memory is invisible.** No `shared` keyword, no region/uniqueness analysis, no `send`-for-memory. The programmer does not annotate memory.
- **Performance** comes from value types + escape analysis + monomorphized generics, plus a quality collector — the same recipe as C# with Native AOT, not from manual memory control.
- **Memory safety is total** — no use-after-free, no dangling, no cycle leaks.
- **Data-race freedom is a separate axis.** A tracing GC preserves heap integrity, not application-level consistency: two tasks mutating a shared object still race the *data*. Preventing that is the concurrency model (§7 and `concurrency.md`), not the collector's job.
- **Deterministic resource release** (files, sockets, locks) is a separate mechanism (§6). GC governs memory reclamation timing, not resource lifetime.

---

## 1. The value / reference split — the performance foundation

**Structs and enums are value types** (passed by value, live inline/on the stack, no heap identity). Only explicit **reference types** live on the GC heap. — **Decided.**

This is the primary performance lever. Value types pay no allocation and no collector cost — the bulk of a program that is plain data (and *all* pattern matching over enums) never touches the heap. It also keeps most objects out of the collector's working set, which is what makes GC cheap here: the collector's cost is proportional to live *heap* data, and the split moves most data off the heap.

**Why reference types exist at all** (the split is "use the right one," not "avoid references"): the real axis is **data vs. entity** / **copy semantics vs. identity**. A value is defined entirely by its contents; an entity has identity independent of contents. Reference types are *required* for:

- **Identity / entities** — file handles, sockets, windows, connections, running actors. Copying creates a second one — a bug. You want aliasing: many holders, one object.
- **Shared mutable state that must stay in sync** — caches, pools, a document edited from several views.
- **Graphs and cycles** — a value can't contain itself. Linked lists, parent-pointing trees, observer graphs need indirection (Swift's `indirect enum` becomes a reference under the hood). The collector reclaims these including cycles, with nothing to break by hand.
- **Unique resources with deterministic teardown** — a file descriptor must close exactly once (§6).

**Heuristic for users:** *If I had two of these with identical contents, are they the same thing or two different things?* Same → value. Two different things, each with its own life → reference.

---

## 2. Type categories

- **Value types** — `struct`, `enum`. Copied on assignment. No heap identity. `let` makes the whole value immutable via value semantics. A value type **may hold reference-typed fields** — copying the value shares the embedded reference (GC-managed, no retain/release to reason about); handing it across a task boundary shares that reference, a concurrency question, not a memory one (§7).
- **Reference types** — `class`. Heap identity, GC-managed, freely shareable (memory-safe). Interior mutability follows the type's field declarations. `class` means "reference type" — Nomu has no class inheritance (`types.md`).
- **Actors** — reference types with isolation; accessed by message (a method call, no suspension marker), not direct field access. A handle is an ordinary GC reference; actor lifetime is reference-driven (collected when unreferenced-and-idle), with no `weak` and no dangling.

---

## 3. Garbage collection via MMTk

Reference-type memory is managed by a **tracing garbage collector**, integrated via **MMTk** (the Memory Management Toolkit). Ship on **generational Immix** first; an **LXR-style reference-counting collector** (Zhao/Blackburn/McKinley, PLDI 2022 — RC-primary + Immix backing + backup tracing) is the footprint endgame. Swapping collectors is a runtime choice, not a language change. — **Decided.**

**Sourcing (Decided 2026-07-30):** ship on **mainline GenImmix** — a maintained, production plan, a genuine live borrow. The **LXR branch is unmerged/stalled**, so the RC-hybrid endgame is a later **owned** reimplementation behind the same MMTk interface, *not* a dependency on the stalled upstream: depending on abandoned research code costs as much as owning it, with more friction. Commit to the interface so owning/swapping the collector stays localized.

**As built (M6, 2026-08-12) — object-model decisions (Decided 2026-08-04):**
- **Address-space model.** `addrspace(1)` = a managed GC-heap reference; `addrspace(0)` = code/static/C-owned memory. `rt_alloc` returns `addrspace(1)` directly — no `0→1` addrspacecast at alloc sites (`RewriteStatepointsForGC` rejects a GC base from a differing-addrspace cast). The managed set: class/actor objects, closure boxes, any-boxes, spawn boxes, and their interior GEPs.
- **Existentials and closures are heap-boxed reference values** (the statepoint rewriter forbids a GC pointer in a by-value first-class aggregate). A closure is a pointer to a fused `{ fn, caps… }` object (scan captures, skip `fn`); an `any I` box is a pointer to `{ witness, payload }` (scan `payload`, skip `witness`).
- **Witness tables are static / non-scanned.** A witness table holds only function pointers, pointers to other static tables, and a reserved type-metadata slot — no GC-heap pointer — emitted once per conformance/monomorphized instance to immortal memory, so the `witness` word is never a root. Holds while monomorphization keeps tables static; a future move to runtime-instantiated dictionaries would make the table a heap object needing tracing (watch item).
- **`String` as a GC object — Decided; not yet built.** The intended form heap-boxes `String` as a GC-managed pointer-free byte array (large strings → non-moving large-object space, literals → immortal space), collected like all heap data. Rejected keeping the buffer runtime-owned: with no ownership it collapses to leaking or to atomic refcounting on every copy/drop (String is shareable) — the retain/release tax a tracing GC avoids (§8). **As built (M6):** the collectable form was implemented and reverted — a struct/enum with a String field is a category-3 value aggregate (values mixed with a GC pointer) that `RewriteStatepointsForGC` can't relocate ("FCA unimplemented"); it needs the D6 category-3 spill seam first. Strings currently use an immortal interim (`{ data addrspace(0), len }`, buffer in never-collected space, leaks). Status + the spill-seam gate: `c-types.md` §2 / §3.4.

The design forks behind these (rejected alternatives, reopen triggers) were retired with the M6 spec; the runtime-facing GC decisions (mutator granularity, safepoints, parked-fiber scanning) live in `runtime.md` §6, and the backend substrate (statepoints, seams, pass pipeline) in `backend.md`. The shipped GC code (`src/gcbinding/`, `src/runtime/`) is the implementation record.

A tracing GC gives memory safety directly — no use-after-free, no dangling, cycles collected automatically with no `weak`/`unowned` and nothing to annotate. The programmer never reasons about memory. MMTk provides production and research collectors behind one binding interface, so Nomu commits to the *interface* (object model, root/stack scanning, barriers) rather than to any single collector, and can move from a mature collector to the tight-footprint one without touching the language. MMTk is written in Rust, which fits Nomu's Rust-oriented codegen.

**Rejected alternatives:**
- *Non-atomic ARC earned by isolation (the original Nomu bet):* elegant on paper, but making it sound required region/uniqueness inference, and getting memory *performance* out of it required a visible ownership discipline. That discipline is the Rust-style friction the language exists to avoid; a tracing GC deletes the reason for all of it. Retired.
- *Atomic ARC everywhere (Swift model):* permanent per-operation refcount tax; concurrent cycle collection genuinely hard. Rejected.
- *Reference capabilities + ORCA (Pony):* gives no-pause, no-barrier, per-actor GC — but its advantages come from Pony's reference-capability type system (a co-design), which is exactly the annotation friction being avoided. Stripped of the capabilities, ORCA degrades to an ordinary concurrent collector. Rejected — the elegance isn't free.
- *Borrow checker (Rust):* best runtime performance and smallest runtime, but the annotations *are* the mechanism. Rejected — the price is paid in syntax.
- *Mutable Value Semantics / Hylo (access conventions, no ARC):* deletes the collector by making values un-shareable, but taxes every parameter with an access-convention annotation — the common-case tax the language declines to pay (see the Hylo evaluation in `vision.md`). The GC obtains MVS's cycle-and-sharing simplification by a different route, with no per-parameter annotation.

---

## 4. Immutability is a type property

Deep immutability is a property of a **type** (a class whose fields are all `let`, recursively), not a binding-level freeze. `let`/`var` follow Swift semantics — rebinding, with value types deep-immutable via value semantics and reference-type interior mutability following the type's fields. — **Decided.**

This is the Swift model, and it replaces the retired `shared let`/`val` freeze machinery. An immutable type can be shared for concurrent reads with no synchronization and no collector complication (it can't form new cycles by mutation). It costs no aliasing analysis — it's a structural check at the type definition.

### Binding keywords (Swift semantics)

- `let` — the name cannot be rebound. For a **value type** this makes the whole value immutable (value semantics do the work). For a **reference type** it prevents rebinding the name; the object's interior mutability follows the type's fields.
- `var` — rebindable; for a value type, mutable in place.
- **Field-level:** a field declared `let` is immutable through any binding; an unmarked field follows the binding. (`let`/`var` fields on `struct`/`class` landed M4.10 — assigning to a `let` field is a compile error; the flag also feeds the deeply-immutable-class check for shareability, `concurrency.md` §5.)

A class whose fields are all `let` (recursively) is a deeply-immutable type — the basis for safe concurrent read-sharing.

---

## 5. Binding forms

### 5.1 Value-type bindings

- `let x: Int` / `var x: Int` — inline, copied. Handing one across a task boundary copies it; trivially safe.
- `let p: Point` — immutable composite; copied wholesale. `var p` — mutable in place.
- A value type **may hold reference-typed fields.** Copying the value shares the embedded reference (GC-managed — no retain/release to reason about). Handing such a value across a task boundary shares that reference: a concurrency (race) question, not a memory one (§7).

### 5.2 Reference-type bindings

- `let n: Node` — GC-managed heap object; `n` cannot be rebound; object fields mutable per the type. Cycles collected by the GC.
- `var n: Node` — rebindable.
- A reference type whose fields are all `let` is an **immutable type** — safe to share for concurrent reads with no synchronization.

### 5.3 Actor bindings

- `let a: Counter` — GC handle to an actor. Lifetime is reference-driven; actor graphs (including actor↔actor cycles) are collected by the GC; no `weak`, no dangling. You interact by message (a method call), not field access. Isolation makes the actor's internal state safe to keep unsynchronized.
- `var a: Counter` — same, rebindable.

### 5.4 Function parameters

- **Value params** — copied; `let` by default. Whether the compiler copies or borrows for speed is an invisible escape-analysis optimization, not a safety annotation.
- **Reference params** — passed by reference, GC-managed. No borrow-vs-retain safety question survives (the GC owns lifetime).
- There is **no `send` / `consuming` for memory.** Race safety (§7) does not use ownership transfer either — it requires the crossing value be "shareable," not that it be moved out of the sender.

---

## 6. Escape analysis and deterministic resource cleanup

### 6.1 Escape analysis and allocation

The compiler performs **escape analysis** to keep non-escaping objects off the GC heap (stack allocation / scalar replacement), and heap allocation uses the collector's fast path (bump-pointer in a thread-local buffer). — **Decided + Built (M6 conservative → M7 precise, 2026-08-24).**

This is the mechanism that recovers manual-memory-grade performance for the common case with no programmer involvement. An object the compiler proves doesn't escape its frame never touches the collector at all. This analysis is a **best-effort optimization, not a soundness requirement**: if it can't prove locality, the fallback is "allocate on the GC heap" — always correct, merely unoptimized. Its precision affects speed only, never correctness, and never the programmer.

**As built.** Two generations. **M6** shipped a conservative front-end pass (`EscapeAnalysis.swift`, NOIR→NOIR, intra-procedural, single-walk, no flow sensitivity) feeding codegen a side table of non-escaping sites; it un-heaped the leaf case. **M7** replaced it with a precise flow-sensitive pass on the SSAIR tier (def-use + CFG), reusing the same codegen-consumer contract, and retired the conservative pass with the NOIR egress (M7.7). The M7 pass does two rewrites:

- **Stack promotion** — a non-escaping `alloc` (class instance, closure object, or `any I` box) becomes a `stackAlloc` and its write barriers drop; the egress builds the object storage on an entry alloca, so LLVM's SROA scalar-replaces it and a managed field becomes a statepoint-tracked SSA root (the I5 mechanism, `ssair.md`). Actors are never promoted (shared-heap semantics).
- **Scalar promotion (loop-carried φ-web)** — a non-escaping class reassigned to a fresh allocation each iteration flows through a loop block-parameter φ; LLVM's SROA cannot un-heap a phi-captured allocation, so the tier decomposes the object into per-field SSA values (the object φ widens into one φ per field, the `alloc` disappears, a managed field becomes an ordinary `addrspace(1)` SSA root). This is **Approach B — field scalarization**, the move Swift SIL (explode loadable aggregates) and Go SSA (`decompose`) make above their backend. *(Rejected Approach A — a single hoisted stack slot threaded through the loop φ: it needs the `p1`-block-param addrspace wall, carries a field-order aliasing hazard when a prior object is read after the fresh one is built, and LLVM won't scalarize a phi-captured slot anyway, so the register win may not land.)*

Non-escape is over-approximate (I4, `ssair.md`): a value escapes on return, any call/send/spawn argument, a store *of* the value, boxing, or capture. Scalar promotion's soundness reduces to two already-trusted mechanisms — SSA construction at field granularity, and `addrspace(1)` SSA values relocated by the statepoint rewriter.

**Rejected / deferred directions.** *Array-buffer stack promotion was assessed and dropped* — a statically-bounded, never-appended `arrayLit` catches almost nothing (the costly arrays are `.append` loops and runtime-sized scratch buffers, exactly what such a gate rejects); the real lever is smallvec-style inline storage, a representation change that belongs with the stdlib `Array` design, not this pass. Deferred tails — interprocedural "any call argument escapes" lift, closure-env / spawn-env promotion, in-place-mutation scalar promotion, wider scalarizable field types — are in `plans/tasks/148-ssair-optimizer-tier.md`.

### 6.2 Deterministic resource cleanup

Deterministic release of **non-memory resources** (files, sockets, locks, DB connections) is a separate concern from GC — a tracing GC reclaims memory on its own schedule and says nothing about *when* a resource is released. This is the one capability a tracing GC does not provide for free that ARC did. Two mechanisms:

**`defer` — Decided (2026-07-16).** Swift-style scoped cleanup: `defer { … }` runs at scope exit, in reverse order, on **every** exit path — normal return, error return, or cancellation unwind (`concurrency.md` §7). The baseline resource-cleanup tool.

**Linear / non-copyable types — Open (design deferred; task `plans/tasks/101-defer-linear-types.md`).** A type-checked "must be consumed exactly once" (Swift `~Copyable`, Rust move-only), for resources where scoped `defer` is insufficient (a handle passed *between* scopes that must still be closed exactly once) and for the continuation token (below). Still to design:
- **Declaration** — a `~Copyable`-style negative marker vs. a positive keyword.
- **Consume + move semantics** — what consumes a linear value (a consuming parameter, last use, an explicit `consume`); assignment moves rather than copies.
- **The must-consume analysis** — tracking exactly-once consumption on every path, including early returns and cancellation-unwind (a light ownership pass — the real work).
- **Interactions** — linear fields (a struct with one is itself linear), closures capturing a linear value, generic linear parameters, collections of linear values; and the **affine ("at most once," droppable) vs. strict-linear ("exactly once")** choice.
Ties to generics.

**Continuation contingency.** The **continuation** token (`concurrency.md` §3) is a linear value whose single consumption is `resume` — one feature, two clients (resource cleanup + continuations), part of the case for building it. Its **compile-time** resume-once/must-resume guarantee is contingent on linear types landing; until then (and across the FFI boundary always) resume-once is **runtime-checked**, so nothing is blocked by deferring the design.

---

## 7. Concurrency — race-free by construction (the shareability rule)

GC delivers memory safety, not data-race freedom, so Nomu adds one rule. **Reference types are task-local by default; a value crossing a task boundary must be "shareable."** — **Decided (2026-07-15).** The full model and share-analysis live in `concurrency.md`; the binding-level summary:

- **"shareable"** = value type (fields shareable) · deeply-immutable type · actor handle. (A fourth category — a self-synchronizing type — is **reserved but its design is deferred**; adding it is additive and needs a trusted `unsafe` shareability escape hatch. See `concurrency.md` §10.) A bare mutable `class` is not shareable.
- **Auto-derived structurally** for concrete types — nothing to annotate on ordinary code. The check fires only when you try to send something unsafe, and surfaces as a **declared bound** only at abstraction boundaries where the concrete type is hidden (a "shareable" bound on a generic parameter, interface refinements, shareable closure/function types).
- **Frame:** Rust's `Send`/`Sync` without the borrow checker — the guarantee, minus the part of Rust that hurts.

---

## 8. Performance profile (honest)

The target is **Swift-class performance**. The recipe: value types with inline layout + escape analysis + monomorphized generics + a quality collector — the C#-with-Native-AOT recipe, not Go's (Go under-specializes its generics).

- **Matches Swift** on value-heavy code and specialized generics.
- **Beats Swift** on reference/graph-heavy code — a tracing GC pays nothing per access, while Swift pays atomic retain/release on every share.
- **Concedes to Swift** on two axes, stated plainly: **memory footprint** (a collector wants headroom — realistically ~1.1–1.3× live set with a modern collector, tunable via a soft memory limit, closer to malloc with the RC-based collector), and **worst-case latency** (some jitter and occasional short pauses — small, and accepted).

**The honest caveat:** the *design* permits Swift-class performance — nothing in the language semantics caps the ceiling below Swift. *Realizing* it is a multi-year backend investment (monomorphization, escape analysis, codegen, collector integration). A prototype will not match Swift and should not try to; the design's job is to keep the ceiling high by holding three properties — inline value types, specializable generics, and "the collector handles the rest."

---

## 9. Open questions

- **Deterministic resource cleanup** — `defer` is Decided (§6.2); linear / non-copyable resource types are deferred (task `plans/tasks/101-defer-linear-types.md`).
- **Collector choice over time** — when to move from generational Immix to the LXR-style RC collector for footprint (§3).
- **Concurrency safety details** — spelling ("shareable" vs "sendable"), the shared-mutable primitive, shareable-closure syntax (§7; full list in `concurrency.md`).
- **Access control × binding forms** — what changes under `public`/`internal`; publicly-immutable/privately-mutable fields. Homed in `modules.md` (stub).
- **Performance realization** — escape analysis, inline value layout, monomorphization, MMTk integration (precise stack maps, barriers, object model). Compiler work, invisible to the surface (`backend.md`).

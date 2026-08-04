# M8 — Implementation Spec (LLVM Backend)

**Status:** working draft — the ordered work plan for M8, derived from `compiler.md` (§1 IR,
§2 backend strategy, §4 debugger, §6 C→LLVM transition checklist), `memory-model.md` §3/§6,
and `runtime.md`. It pins the build sequence; the design lives in those docs. The big backend
forks (8.0.4) are **Decided (2026-07-31)** and the phased build plan (8.1–8.5) is laid out with
per-slice work and exit criteria; slice records fill in as they land. The IR-production
mechanism (A) is refined in §8.0.4-A: drive LLVM via its **C API** (`import LLVM_C`) from Swift
(cxx-interop over LLVM's C++ modules does not build), LLVM via the **`llvm/llvm-project` Bazel
overlay** (`http_archive` at a pinned commit; the pins live in `bazel/llvm_extensions.bzl`). 8.1
(toolchain bring-up) is **complete**.

> Authoring conventions per `lang-project/milestone-doc-guide.md`.

**Build status (2026-07-31):** **not started — design-opening.** M8 is the **next build
milestone** (reordered before M6; `roadmap.md`). Target is **plain LLVM**, MLIR not pursued.
The three big forks (8.0.4) are now **Decided (2026-07-31)**: LLVM **C++ API behind a thin C++
shim** (A); **LLVM statepoints → stack maps** for GC roots + **no bespoke MIR** (B);
**LLVM-only, minimal-correct** scope (C). Phasing (8.1+) can now firm up.

**Framing correction:** the roadmap names M8 "real backend (LLVM)," but M8 is the
**convergence substrate for three later consumers**, not just a release-perf swap: the moving
GC (M6 — precise stack maps), cancellation (M7 — safepoint polls), and scheduler preemption
(`runtime.md`) all ride the **safepoint/statepoint machinery M8 emits** (`concurrency.md` §7).
So M8's safepoint design must be **triple-purpose** from the start, though M6/M7 build after.

**Prerequisites:** none hard — the typed IR (M4.9), whole-program monomorphization (M5), and
the C runtime (M4) all exist. M8 *replaces* the C emitter (`src/codegen/sources/CodegenIR.swift`,
~1340 lines of C-string emission) with LLVM lowering; the **C backend stays as a reference
oracle** for differential testing until M8 is green.

---

## 8.0 · Front matter

### 8.0.1 · Scope

**Ships in M8:**
- Structured typed IR → **LLVM IR**; native release binaries via the LLVM toolchain.
- **DWARF debug info** (Tier 0: line tables + basic types) via `DIBuilder` — the C backend got
  this free from `cc`; the LLVM path must emit its own (`compiler.md` §4, §6).
- The **GC substrate M6 needs** — precise **stack maps** + **safepoints** at calls/back-edges,
  and the **write-barrier insertion seam** (inert until M6, but the codegen hook exists).
- The **safepoint poll seam** M7 cancellation + runtime preemption ride.
- **Runtime as a linked library** — the C preamble (scheduler, poller, `rt_alloc`, `String`,
  `Closure`) compiled to a `.a` and linked, no more per-file inlining (`compiler.md` §6).

**Deferred** (design ref):
- **MLIR** — no language-specific-opt layer; plain LLVM (`compiler.md` §2). Reconsidered only
  if heavy custom optimization is later wanted.
- **Cranelift** debug-build backend — a later fast-compile play once LLVM iteration pain bites
  (`compiler.md` §2).
- **Incremental compilation + cached monomorphizations** — its own effort, tied to the query
  architecture (`compiler.md` §3, §7, §8); M8 must **not foreclose** it, not build it.
- **Own MIR (CFG/SSA)** — deferred with escape analysis / language-aware GC passes
  (`compiler.md` §1). LLVM IR is itself CFG/SSA, so M8 lowers the structured IR straight to it.
- **Debug Tier 1+** — enum variant parts, lldb formatters, runtime-aware plugin (`compiler.md` §4).
- **Perf items** — `ucontext`→hand-written asm, fiber-aware mutex, `Bool` as `i1`/`i8` — M8
  tail or follow-on (`compiler.md` §6).

### 8.0.2 · Compiler surface touched

Current: `… → typed IR → CodegenIR (emit C strings) → cc`. M8 replaces the last two stages.
- **New backend** — typed IR → **LLVM IR** via the LLVM **C API** (module / function /
  basic-block construction, not string emission). The per-node lowering *logic* in `CodegenIR`
  carries over; the *string emitter* does not. `Mangle.swift` survives (symbol names are
  backend-neutral). New build components: the `llvm-project` Bazel overlay and the `src/llvmgen`
  `swift_library` driving `import LLVM_C` (§8.0.4-A).
- **Debug info** — `DIBuilder` threaded from the IR's spans (carried on every node, §1).
- **Runtime** — preamble carved into a compiled `.a`; codegen emits calls and links it.
- **Closure conversion / share analysis** — "still in codegen" today (§1); either kept inline
  in lowering or promoted to a pre-LLVM pass (8.0.4-B).

### 8.0.3 · Dependencies

```
8.1 (toolchain bring-up + native hello-world: swift-llvm-bindings, llvm-project overlay, runtime .a)
└─ 8.2 (full language lowering: every IR node → LLVM, C-backend parity)
   ├─ 8.3 (DWARF Tier 0 via DIBuilder)
   └─ 8.4 (GC substrate: statepoints + stack maps + inlinable seams)  [serves M6/M7]
8.5 (perf tail: ucontext→asm, i1 Bool, opt pipeline, fiber-aware mutex)   [descopable]
```
8.1 gates everything (nothing lowers until the bindings path runs). 8.2 is the bulk. 8.3 and 8.4
depend on 8.2 and are independent of each other. 8.5 trails and is descopable.

### 8.0.4 · Big design decisions

- **A · LLVM IR production: the LLVM **C API** from Swift — Decided (2026-08-01; supersedes the
  earlier "C++ API via `swift-llvm-bindings`" pick).** Importing LLVM's
  **C++** modules via Swift cxx-interop **does not build** (`Support/Format.h` `operator<<`
  ambiguity under interop — the first of many such incompatibilities). The LLVM **C API**
  (`import LLVM_C`) builds/links/runs end-to-end and covers the M8 backend needs (IR,
  `TargetMachine`, `DIBuilder`, pass pipeline incl. statepoints). C++ reach is preserved via a
  **thin C++ shim** (normal C++, no interop) for the rare gap. `swift-llvm-bindings` not used
  (≈2 KB over LLVM's own module map; the importable surface is LLVM's own `module.modulemap`,
  shipped with `@llvm-project`). The Swift-facing surface must stay **flat and importable** — free
  functions, opaque pointers, POD structs, scoped enums — since Swift cannot import LLVM's
  templated / virtual-class C++ (the governing interop constraint). `import LLVM_C` still needs
  `-cxx-interoperability-mode=default` (LLVM's C headers require the `cplusplus` module feature via
  `LLVM_Config`), and that flag is **viral** — every target transitively importing it needs it.

  **C-API coverage + shim triggers (A′).** Covered, no shim: IR (`Core.h`), object emission
  (`TargetMachine.h`), debug info (`DebugInfo.h`, Tier 0), opt + statepoints
  (`Transforms/PassBuilder.h` `LLVMRunPasses` incl. `rewrite-statepoints-for-gc`; `addrspace(1)`;
  `LLVMSetGC`). Anticipated gaps → C++ shim, in likelihood order: (1) **`DIBuilder` variant parts**
  (`DW_TAG_variant_part`, enums-as-active-case in DWARF — 8.3 Tier 1 / M10; the most likely first
  shim; Tier 0 is fully covered); (2) **custom LLVM passes** (the C API runs *named* passes only —
  none planned in M8, escape analysis is at our IR level); (3) **hand-emitted `gc.statepoint`
  intrinsics** if the pass-driven route proves insufficient (8.4); (4) newest-LLVM features the C
  API lags (only on a deliberate version bump — we pin). Expected frequency low; C-API-primary
  should carry through M8 and likely M6.

- **B · GC roots via LLVM statepoints; no bespoke MIR — Decided (2026-07-31), reconfirmed
  (2026-08-03) against the conservative-stack alternative.** Governed by *what is fastest for
  MMTk*, not what is easiest. LLVM **statepoints** (`addrspace(1)` GC pointers + `gc
  "statepoint-example"` + RewriteStatepointsForGC) emit return-address-keyed **stack maps** — the
  state-of-the-art precise-root mechanism (HotSpot / .NET): GC pointers stay in registers/stack in
  steady state and root cost is paid **only at collection**. Statepoints handle relocation
  natively (Immix/LXR).

  **Alternatives evaluated and rejected.** The **shadow-stack** taxes *every call* with push/pop
  bookkeeping regardless of GC — rejected on performance. The **conservative-stack / precise-heap
  (pinning)** design — which would drop statepoints entirely, giving preempt-anywhere and a far
  smaller backend (no `addrspace(1)`, no poll placement, no RewriteStatepointsForGC) — was
  re-examined at length (2026-08-03) and rejected on **fiber-count scaling**. Its costs (whole-stack
  conservative scan, **pinning** of stack-referenced objects, and false retention) all scale with
  the number of fibers *and* with park duration, and they degrade exactly the moving-footprint
  thesis (and LXR's evacuation-based advantage) that M6 exists to validate — on the massively
  concurrent workloads a fast language is judged by. Statepoints' costs (mutator spill/reload,
  time-to-safepoint) stay bounded by *running* fibers (≤ carriers), not by total fiber count. Since
  Nomu's M:N runtime targets **10k+ fibers**, precise roots are the fiber-scaling-aligned choice.
  It is the same tradeoff seen from both sides: conservative skips the mutator reload tax *by*
  pinning (can't-move), precise pays the tax *to* move everything. Nomu wants the latter. (Precise
  roots are also strictly upgradeable-from-nothing later if measured otherwise; MMTk supports both
  root strategies — the door stays open, 8.0.8.)

  **Preemption is separate from GC roots.** Signal-based async preemption (Go-style SIGURG) is
  adopted for **scheduler fairness** — it stops a compute-bound fiber at any PC. It does **not**
  carry GC root scanning: LLVM emits relocatable maps only at statepoints, so a signal-interrupted
  fiber isn't scannable at an arbitrary PC. Fairness rides signals; GC rides statepoints.

  The mutator-performance battleground is *not* the root mechanism but the **inlinable
  alloc/barrier/poll seams** (8.0.7). **No own MIR in M8:** LLVM IR is itself CFG/SSA, so lower the
  **structured typed IR straight to LLVM**; a bespoke MIR (≈ Rust MIR / Swift SIL — a low CFG/SSA
  form to host language-aware passes) is built only when **escape analysis** needs language types
  LLVM has discarded (`compiler.md` §1).

- **C · Scope fence: LLVM-only, minimal-correct — Decided (2026-07-31).** No MLIR, no Cranelift
  second backend, no incremental compilation in M8; debug info Tier 0 only; perf items (8.5) to
  the tail. Keeps M8 small and unblocks M6/M7 fast; must not *foreclose* incremental
  (`compiler.md` §8), but does not build it.

### 8.0.5 · Runtime posture

The C runtime (M:N `ucontext` scheduler, poller, timer heap, `rt_alloc`, `String`, `Closure`)
becomes a compiled `.a`. The alloc seam stays `rt_alloc` (routed to MMTk in M6). Safepoints M8
emits are **triple-purpose**: GC roots (M6), cancellation poll (M7), preemption (runtime). No
new surface syntax; no language-semantics change — M8 is a backend swap.

LLVM is a **compile-time** dependency of `nomuc` only (statically linked libLLVM); **compiled
Nomu programs ship no LLVM** — a program is native code + the runtime `.a` + libc (LLVM produced
it, as clang produces a C binary, but is not in it). So `nomuc` is a large binary (libLLVM is
hundreds of MB — normal for a compiler); packaging it is an M8-tail concern, not a blocker.
Programs stay small.

### 8.0.7 · Performance posture (the levers "down here")

Max performance at the backend is a stated goal; the levers, in rough order of mutator impact:
- **Inlined write barriers (highest — and the LXR premise).** LXR is an RC collector: its
  barrier fires on pointer writes and is the *dominant* mutator cost. The barrier **fast path
  must be inlined at the LLVM level**, only the slow path a call. If barriers are emitted as
  call stubs, LXR's performance premise is lost. (Seam built in M8/8.4; filled in M6.)
- **Inlined allocation fast path.** MMTk's bump-pointer alloc emitted **inline** (compare, bump,
  branch-to-slow), not a `rt_alloc` call — allocation is hot.
- **Safepoint poll form.** Predicted conditional branch on a per-thread flag vs. a HotSpot-style
  **protected-page load** (near-zero in the common case). Decided with measurement in 8.4.
- **Statepoint placement.** Run the LLVM optimizer *first*, insert statepoints **late**
  (`RewriteStatepointsForGC` is designed for this) so opts run on normal pointers; keep
  safepoints **sparse** (calls + loop back-edges only) and **minimize GC-pointer liveness
  across** them, since statepoints do add reload overhead.
- **Codegen basics** — `Bool` → `i1`/`i8`, `-O` release pipeline, `ucontext`→asm (8.5).

The through-line: M8 builds the alloc/barrier/poll **seams as inlinable primitives**, not
function calls — that inlinability is what lets M6/LXR be fast.

### 8.0.8 · Risks / watch items

- **LLVM version pinning** — the pinned `llvm-project` overlay commit (in
  `bazel/llvm_extensions.bzl`) is the blast radius; the bazel integration (incl. the overlay's
  from-source LLVM build) was the riskiest early unknown, now resolved (8.1 complete).
- **Statepoint codegen quality** — statepoints add reload/spill overhead around safepoints and
  can inhibit opts; mitigated by late insertion + sparse safepoints + minimal cross-safepoint
  liveness (8.0.7). Keep the binding boundary clean enough to revisit the root mechanism if
  measured quality is inadequate.
- **Statepoint discipline** — `addrspace(1)` hygiene and RewriteStatepointsForGC constraints
  (every GC pointer live across a safepoint must be discoverable); the object/pointer model
  must satisfy it (co-designed with `m6-spec.md` 6.1).
- **Differential correctness** — keep the C backend as an oracle; every example matches
  C-backend output until M8 is green.
- **Debug-info fidelity across lowering** — spans → DWARF through monomorphization /
  match-lowering / closures-as-structs (`compiler.md` §4).
- **C-isms in the current emitter** — `({ … })` statement expressions and `int64_t` `Bool`
  vanish under IR construction, but audit the lowering logic as it ports (`compiler.md` §6).

---

## 8.1 · Toolchain bring-up + native hello-world ✅ (2026-08-01)

Intent: stand up the whole LLVM path end to end on a trivial program — mostly build/interop
plumbing, the riskiest unknown, so it went first. Deps: none. Approach (8.0.4-A): the LLVM **C
API** (`import LLVM_C`) + the `llvm-project` Bazel overlay, called from Swift; the runtime
compiled to a `.a` and linked.

Built in five linear steps: (8.1.1) the `llvm-project` overlay as hermetic `cc_library` targets,
proven from C++; (8.1.2) Swift drives the LLVM C API against `@llvm-project` — the pivot to the C
API after LLVM's C++ modules failed to import under cxx-interop (§8.0.4-A); (8.1.3) a hand-built
arithmetic-`main` + external `print`, verified; (8.1.4) host-triple `TargetMachine` object
emission + runtime `.a` + link; (8.1.5) a real `main` lowered from the typed IR. The pins and
bazel wiring live in `MODULE.bazel` + `bazel/llvm_extensions.bzl`; the lowering seam is
`src/llvmgen/{LLVMBridge,Lowering}.swift`. (The differential-oracle C backend that guarded 8.1–8.2
was retired at the 8.2 exit.)

**Exit — met.** `fun main() { print(2 + 3) }` (and arithmetic/`let`/multi-`print` variants)
compiles through the LLVM path to a native binary that runs and prints the correct value; `bazel
build`/`test` green with the LLVM targets.

## 8.2 · Full language lowering — C-backend parity ⬜

Intent: lower every typed-IR node to LLVM until the LLVM backend matches the C backend on the
whole suite. Deps: 8.1. Approach: port `CodegenIR`'s per-node lowering *logic* to the bindings'
IR-construction API, sliced by feature area; closure conversion stays inline (as today) unless a
pre-pass proves cleaner (8.0.4-B). Differential-tested against the C backend throughout.

- **8.2.1 ✅ (2026-08-02)** — primitives + control flow + functions: Int/Bool/String literals,
  arithmetic/comparison, `let`/`var`, assignment + `+=`, `if`/`else`, `return`, calls, `print`,
  string concat (`rt_str_concat`). `src/llvmgen/Lowering.swift` (`IRToLLVM`), C-API-driven.
  ABI parity with `CodegenIR.cType`: Int **and** Bool are `i64` (bool 0/1); String is the
  runtime `{ i8*, i64 }` struct passed/returned by value (a two-GPR aggregate — the natural LLVM
  struct matches the C ABI, confirmed differentially on arm64). Comparisons: `icmp`→`zext i64`.
  Functions are lowered on demand from `main` (call-graph reachability), so the prelude's unused
  decls — which use not-yet-covered features — are never lowered. Locals use allocas
  (`let`/`var`/params uniform); `if/else` via `condbr` + merge block with per-branch local
  scoping. Unsupported nodes/types return a `file:line:col`-prefixed error (no crash) — the 8.2.2
  boundary. Differential-tested: `test/differential/{hello,control,functions,strings}.nomu` build
  with both backends and match on stdout + exit (arithmetic, comparisons, `if/else`, `var`/`+=`,
  user funcs, recursion, string literals/concat).
- **8.2.2 ✅ (2026-08-02)** — value types: `struct` construction, field load/store, methods,
  mutating methods (`self` by-ref), computed properties (get/set). A struct is an LLVM struct in
  field order, by value; `construct` builds it with `insertvalue`. Free functions and methods
  share one on-demand callable registry (keys `f:<name>` / `m:<type>:<method>`). Field/local
  access goes through an **lvalue path** (`lvalue` → address): a local is its alloca, a struct
  field GEPs into the base's address (rvalue bases spill to a temp), and inside a method body a
  bare field name resolves through `self`. Mutation is **inferred** (no `mutating` keyword) — an
  inferred-mutating method takes `self` as a pointer (call passes the receiver's address, mutates
  in place); a read-only method takes `self` by value (a copy). Computed properties are methods
  named `prop.get`/`prop.set`. Differential-tested (`test/differential/structs.nomu`): fields,
  method calls, in-place mutation, computed props, and nested structs (`box.origin.y = 55`) all
  match the C backend.
- **8.2.3 ✅ (2026-08-02)** — enums + `match`: payload-carrying enum construction (tag + payload
  layout), `switch` lowering (discriminant branch + pattern bindings), enum methods/properties
  (exhaustiveness already checked upstream). An enum is `{ i64 tag, [P x i64] payload }` — since
  enums never cross the runtime C ABI, the layout is internal and need not match `CodegenIR`'s
  union; all supported field types are 8-aligned/8-multiple, so a case's storage is exactly its
  field-slot count and P is the largest case's. `enumInit` writes the case index as the tag and
  each payload field via the case's struct type GEP'd over the payload region; `switch` reads the
  tag into an LLVM `switch` (exhaustive → `unreachable` default), and each arm binds its payload
  fields (local copies) before its body. Enum methods reuse the struct callable/self machinery
  (self by value / by pointer). Differential-tested (`test/differential/enums.nomu`): Int/String/
  struct payloads, no-payload cases, `switch` with bindings, and an enum method matching the C
  backend.
- **8.2.4 ✅ (2026-08-02)** — reference types + closures. **Classes**: `{ i64 header, fields… }`
  heap objects (`rt_alloc`, bump-and-leak — the header slot mirrors `ObjectHeader.refcount`,
  unused until M6); a class value is the object pointer (reference semantics), fields at index
  i+1 (past the header). Field access and methods generalize the struct machinery via an
  `AggKind` (struct-value vs class-ref): a struct field GEPs off the value's address, a class
  field off the pointer; `self` is always the object pointer for a class method (by value for a
  read-only struct/enum method, by pointer when mutating). **Closures**: a closure value is
  `{ ptr fn, ptr env }` (matches runtime `Closure`); the body is hoisted to `nomu_cloN(ptr env,
  params…)`, the site `rt_alloc`s the env and copies captures by value. Captures are the body's
  free variables naming enclosing locals (free-var walk mirrors `CodegenIR`, respecting
  shadowing). Calls: a global name is direct; a closure-typed value loads `fn`/`env` and calls
  `fn(env, args…)` indirectly (also the path for a closure passed as an argument — `.function`
  params lower to `closureTy`). Differential-tested (`test/differential/{classes,closures}.nomu`):
  class methods + reference mutation across a call, String fields, capturing/no-arg/higher-order
  closures — all match the C backend.
- **8.2.5 ✅ (2026-08-02)** — interfaces + generics + `Result`. **Witness tables** are built lazily
  (per `type::iface`) as LLVM globals: a `witness.<I>` struct of `ptr` slots — one per method
  requirement, `_get`/`_set` per property, a `base_<B>` per transitive base, then a reserved
  `type_witness` — initialized with **uniform-signature thunks** `ret(ptr self, params…)` that
  bridge the payload to the concrete impl's `self` ABI (by value for a read-only value method, by
  pointer for a mutating/class method) and re-box a covariant-`Self` result. A property thunk is a
  direct field load/store when stored-field-backed, else routes through the `prop.get`/`prop.set`
  accessor. **`any I` is `AnyBox { ptr witness, ptr payload }`** (`anyBoxTy`, internal — never
  crosses the runtime C ABI); `.box` wires witness + payload (reference type → the pointer; value
  type → an `rt_alloc`'d copy). **Dynamic dispatch** (`.methodCall` on an `.existential`) loads the
  slot fn ptr from the box's witness and calls `fn(payload, args…)` (call type taken from the
  site). **`any A & B`** uses a `comp.<A&B>` composite witness (a sub-table ptr per interface);
  dispatch loads the owning interface's sub-table, then its slot. **Existential upcast** (`any B` →
  `any A`) re-boxes through the source witness's `base_<A>` pointer. **`some`/opaque** devirtualizes:
  `concreteUnderlying` (via `IRModule.opaqueUnderlyings`) resolves the hidden type, so a requirement
  call lowers to a direct concrete call (or stored-field load for a `prop.get`) with no box.
  **Monomorphized generics + `Result<T,E>` need nothing new** — whole-program mono runs before
  codegen (the LLVM path lowers `monoModule`), so a generic instance arrives as a concrete named
  struct/enum (`Box<Int>`, `Result<Int,String>`) the 8.2.1–8.2.4 machinery already lowers; no
  `.typeParam`/`.generic`/witness params survive. `lowerExpr`'s node switch is now exhaustive (no
  `default`). Differential-tested (`test/differential/{interfaces,composition,opaque,upcast,
  generics}.nomu`): `any`-dispatch + defaults + stored/computed property requirements, composition,
  opaque devirt incl. `-> Self`, upcast + property-set through `any`, and generic func/type +
  `Result`/`Option` — all match the C backend.
- **8.2.6 ✅ (2026-08-02)** — concurrency. **Actors** are reference types laid out
  `{ i64 header, fields…, i8* mu }` (`actor.<name>`, heap `rt_alloc`); like a class the value is
  the object pointer and fields sit at index i+1. Construction initializes each field (a declared
  `= expr` initializer, else the matching ctor arg) and installs a fresh mutex in the trailing slot.
  Each **`on`-handler** is declared on demand (`declareActorHandler` synthesizes an `IRFunc`, `self`
  by pointer) and **mutex-serialized**: `defineBody` brackets it with `rt_mutex_lock` at entry and
  `rt_mutex_unlock` at every exit (each `return` and the fall-through). Fields are accessed directly
  through `self` under the lock (no copy/write-back — simpler than `CodegenIR`, equivalently correct
  since all access is serialized). **The mutex is an opaque runtime `void*`** (`rt_mutex_new/lock/
  unlock`, added to the runtime) — the LLVM backend has no portable `pthread_mutex_t` layout, and
  the actor layout is internal anyway; additive to the ABI, the C backend still inlines
  `pthread_mutex_t`. **`spawn let`** closure-converts the value onto a fiber: a hoisted start
  routine `void* nomu_spawnN(void* env)` loads captures (free vars of the value, by value into a
  heap env, like a closure), computes the value, and returns an `rt_alloc`'d box of the result;
  the site `fiber_spawn`s it and stores the `SpawnHandle` (`{ i8* fiber }`). Reading the binding
  (`varRef`) `spawn_join`s and loads the box; every `return` and the function fall-through join all
  the function's active spawns (`spawn_join` is idempotent) — the structured-concurrency guarantee.
  **Colorless blocking calls**: `sleep` → `rt_sleep_ms`, `readLine` → `rt_read_line(0)`. Share
  analysis stays a frontend/Sema safety check, not repeated in codegen. `lowerStmt`'s switch is now
  exhaustive (no `default`). The `enterThunk`/`leaveThunk` helper now also saves/resets the
  spawn/actor-mutex state, so a `return` inside a hoisted closure/spawn/thunk body can't join the
  enclosing function's spawns (which would reference its allocas cross-function). Differential-tested
  (`test/differential/{spawn,actor}.nomu`, deterministic outputs): concurrent spawn/join with a
  captured value, and three concurrent workers bumping a mutex-serialized actor to an exact count —
  both match the C backend (actor run 20× stays exact).

**Exit:** a **differential harness** runs every `examples/*.nomu` plus the `src/codegen/tests`
programs through both backends and asserts identical stdout + exit code — all pass. The
lowering `switch` covers every typed-IR node kind (no `default`/unhandled case remains).

**The C backend is a parity-only oracle — retired, not extended past 8.2 (decided 2026-08-02).**
The two backends diverge fundamentally at M6: precise/moving GC needs LLVM statepoints + stack
maps the C backend can't emit, so there is nothing to "double-implement" — GC and every
statepoint/stack-map-dependent feature is **LLVM-only from the start**. The C backend's value is
entirely this 8.2 bring-up: a trusted reference to diff against. At the 8.2 exit, the durable
asset is the **program corpus** (the `.nomu` files + their known stdout/exit), not the second
backend. So: capture **golden stdout+exit** for every corpus program (generated by the C backend
— its last act), flip the harness from "diff two backends" to "run LLVM, assert against goldens"
(`diff_backends.sh` → a golden runner; corpus + BUILD wiring carry over), then **retire the C
backend before M6**. Delete vs. freeze is left open until parity (delete preferred — no bit-rot,
no double-compile); the settled part is: do not extend the C backend past parity, ever.

## 8.3 · DWARF Tier 0 ⬜

Intent: near-free debug info — line tables + basic types via `DIBuilder`, from the spans every
IR node already carries (`compiler.md` §1, §4). Deps: 8.2. Approach: `DIBuilder` via the
bindings (or the supplement, if uncovered).

- **8.3.1 ⬜** — `DIBuilder`: compile unit + per-function subprogram + line table
  from node spans.
- **8.3.2 ⬜** — basic-type DWARF for Int/Bool/String + struct field layout; locals/params
  given locations.

**Exit:** on an LLVM-built binary, a scripted lldb (`lldb-dap`) session sets a line breakpoint,
single-steps in source order, prints a correct backtrace, and reads a primitive local — over a
sample program in the test suite.

## 8.4 · GC substrate — statepoints, stack maps, inlinable seams ⬜  [serves M6/M7]

Intent: build the safepoint/statepoint machinery and the inlinable alloc/barrier/poll seams M6
(GC) and M7 (cancellation) will fill — inert now, but shaped for performance (8.0.7). Deps:
8.2. Approach (8.0.4-B): `addrspace(1)` GC pointers, `statepoint-example` GC,
`RewriteStatepointsForGC` inserted **late**; seams emitted **inline** (fast path inline, slow
path a call).

- **8.4.1 ⬜** — mark heap-object pointers `addrspace(1)`; set the GC strategy; run
  `RewriteStatepointsForGC` after the opt pipeline.
- **8.4.2 ⬜** — safepoints at call sites + loop back-edges, kept **sparse**; poll form (branch
  vs. protected-page) chosen with a microbenchmark.
- **8.4.3 ⬜** — stack-map emission + a runtime parser; a smoke test enumerates the precise
  roots live at a forced safepoint.
- **8.4.4 ⬜** — the **alloc fast-path**, **write-barrier**, and **cancellation-poll** seams as
  inlinable primitives (inline fast path + out-of-line slow-path stub), inert (slow path a
  no-op / plain `rt_alloc`) until M6/M7.

**Exit:** every safepoint emits a parseable stack map; the smoke test recovers the *exact* set
of live GC roots on a known-answer program; the three seams are present, inline-shaped, and
provably inert (differential harness output unchanged vs. 8.2). Hands M6 a working precise-root
+ barrier substrate.

## 8.5 · Perf tail (descopable) ⬜

Intent: recover backend performance once correctness is green; can trail M8 or spill to a
follow-on. Deps: 8.2 (asm/mutex), 8.4 (opt↔statepoint ordering).

- **8.5.1 ⬜** — `ucontext` `swapcontext`/`makecontext` → ~20-line arm64 + x86-64 fiber-switch
  asm (drops the macOS signal-mask syscall per switch).
- **8.5.2 ⬜** — `Bool` → `i1`/`i8` (from `int64_t`); audit remaining C-ism artifacts
  (`compiler.md` §6).
- **8.5.3 ⬜** — LLVM opt pipeline: new pass manager, `-O` release vs. debug levels, ordered
  **before** statepoint rewriting (8.0.7).
- **8.5.4 ⬜** — fiber-aware mutex (park/unpark) replacing actor `pthread_mutex_t`, so a held
  handler doesn't block a carrier (`compiler.md` §6).

**Exit:** measurable throughput/latency improvement over the 8.2 baseline on a benchmark (e.g.
`examples/speed-nomu.nomu`); correctness unchanged (differential harness still green).


### post m8 ideas
- comptime
  - compiler architecture review for perf
  - compiler perf diagnostics by default
- discuss module level interface as input
- dead code stripping
- runtime
  - llvm -O flag forwarding
  - profile `time nomuc -h` taking 500ms
- cleanup llvm experiments
- start prioritizing stdlib via language benchmarks (post GC)
  - lowest nomu primitives (string, collections, byte buffers, raw memory)
  - swiss tables
- pipeline
  - emission options
  - intermediate based iso regression
  - bazel usage

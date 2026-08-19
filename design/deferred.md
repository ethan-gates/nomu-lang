# Deferred implementation work (TODO backlog)

A running list of feature work that is **intentionally postponed** — the direction is
decided, the build is parked until a real trigger arrives. Distinct from a design
*Open* question (still undecided) and from a milestone's in-scope deferrals (those live
in the owning `mN-spec.md`). Each entry records **what**, **why deferred**, the
**trigger** that should un-park it, and the **design ref**.

Status vocabulary matches `readme.md` §"Reading the status tags".

## Current-phase perf triage (2026-08)

A guideline, not a rule — applied case by case. In the current phase, perf work worth picking up now
usually falls into one of two buckets:

1. **Large architectural directions** that steer the whole system — the actor message model, GC plan
   direction, the M7 optimizer tier.
2. **Work already in flight or awaited** — the C-compilation cache, the parallel differential,
   allocation inlining.

A local, self-contained perf win with unmeasured value is usually better parked here until a workload
asks for it. **Caveat:** a "small" decision or feature that combines with other small ones into an
architectural direction is category 1 in disguise; surface it and decide it explicitly rather than
letting a direction accrete unremarked.

## How entries are tagged

Each entry carries a **Type** and a **Lifecycle** stage:

- **Type** — `user-facing` (visible to a Nomu programmer), `language-feature` (new syntax/semantics),
  `perf`, `refactor` (internal structure, no behavior change), or `observability` (compiler
  introspection).
- **Lifecycle** — `needs-design` (direction not yet specified), `needs-grounding` (direction clear,
  needs code investigation/measurement before building), `ready-to-build` (designed + grounded, just
  parked), or `blocked` (waiting on a named prerequisite).

---

## `shared` on function-type / existential spellings

**Type / Lifecycle:** `language-feature · ready-to-build` (trigger-gated).

- **What.** The explicit `shared (A) -> B` (shareable closure/function type) and
  `shared any I` (shareable existential) spellings (`generics.md` §2). The
  `<shared T>` *bound* shipped in M5 (`generics.md` §7); these two spellings did not.
- **Why deferred (Decided 2026-07-28).** No consumer in M5. Shareability is
  auto-derived structurally (`generics.md` §7), so no annotation is needed for the
  common case. The explicit marker is only required on a **closure/generic parameter
  forwarded to a task where the forwarding body is hidden from the caller**
  (`concurrency.md` §5). Those hidden-body boundaries are **interface method
  requirements** and, later, **module boundaries** — neither exercised for
  closure-forwarding under M5's single compilation unit. Building it now means
  threading the capability through `Type` (`.function`/`.existential`/`.composition`,
  ~27 switch sites + assignability rules) with nothing to exercise it.
- **Trigger to build.** An interface requirement needs to forward a closure to a task
  (so its signature must spell `shared (A) -> B`), or modules land (hidden bodies
  across the boundary).
- **How to build then.** Param-focused and sound, mirroring 5.3.2: parse the spelling,
  record param shared-ness in the signature, discharge at call sites (arg closure's
  captures shareable / arg value's type shareable), treat a `shared` param as
  shareable in-body via name-tracking (`Sema.sharedParams`) — a full `Type`-model
  change is optional, needed only if shared-ness must flow through fields/returns.
- **Ergonomic alternative (separate item).** Bottom-up **inference** of a closure
  param's shareability requirement from a visible body (`concurrency.md` §5,
  "inferred bottom-up" — a *Leaning* item) keeps `shared` unwritten for ordinary
  functions. Larger analysis; independent of the spelling above.
- **Refs.** `generics.md` §2, §10; `concurrency.md` §5; `interfaces.md` §8.

---

## Docs reorganization: working design docs vs. a language spec

**Type / Lifecycle:** `refactor · needs-design`.

- **What.** Split the doc set into two audiences: **working design docs** (the
  `mN-spec.md` build plans, decision records, and per-feature design like `loops.md` —
  how and why we build) and a **language specification** (what the language *guarantees
  to the programmer*: syntax, semantics, and the contracts a Nomu author can rely on,
  independent of implementation). Today both live intermixed across `design/`.
- **Why deferred (raised 2026-08-03).** The design docs are still churning as M9 lands;
  extracting a stable programmer-facing spec now would track a moving target. The split
  pays off once the language surface settles.
- **Trigger to build.** After M6 (post-GC), when the surface is stable enough that a
  guarantees-oriented spec stops thrashing. Revisit as a post-M6 item.
- **How to build then.** Decide the boundary (spec = observable behavior + syntax +
  semantics; design docs = rationale + build plan + internals), then lift the
  programmer-facing content out of `syntax.md`/`concurrency.md`/`types.md`/etc. into a
  spec, leaving the working docs to cross-reference it. Discuss scope first.

---

## Language + compiler-perf work (2026-08 session)

Terse pointers, each tagged `[Type · Lifecycle]`. Promote to a full What/Why/Trigger/How entry when
picked up.

- **Operator surface design** `[language-feature · needs-design]` — a holistic pass over operators
  before extending any. Open pieces: equality/relational on non-numerics (`String` uses `.eq(...)`
  today, aggregates have none); **logical-not `!`** (only `!=` exists); **unary minus** (`-x`; write
  `0 - x` today). Comparison type-checking already rejects non-numeric `== != < >` with a clean error
  (`Sema.binaryResult`). Decide the whole set + the overload/requirement story together. Ref:
  `generics.md` §10 (operators-as-requirements).
- **Grouping parentheses as a primary expression** `[user-facing · ready-to-build]` — `(a + b) * c`
  does not parse; `(` only opens a call/param list. Add a parenthesized-expression case to
  `parsePrimary`. Small, self-contained (worked around in `examples/benchmarks/hashmap.nomu`).
- **Generic hash map `HashTable<V>` / whole-aggregate element reads** `[language-feature · blocked]` —
  the hashmap is concrete `String → Int`; a generic value type, and reading a whole array element by
  value (`let e = a[i]` mixing values + refs), both recreate the category-3 FCA case. Blocked on the
  **D6 spill** (`c-types.md` §3.4).
- **Identifier interning** `[perf · needs-grounding]` — intern identifiers to integer symbols at lex
  time; downstream Sema comparisons/maps become int-keyed. Touches Sema's string-keyed tables and
  interacts with macro **hygiene** (carry `(symbol, hygiene-ctx)`) and future parallel/incremental
  compilation. Ground against Sema's map usage first. Deliberately deferred out of the parser-perf pass.
- **Lexer allocation levers** `[perf · ready-to-build]` — after the byte-lexer + compact-spans work,
  two small wins remain: parse `Int` literals directly from bytes (drop the per-number `String`), and
  reuse one scratch `[UInt8]` across string literals (drop the per-literal array). Keywords/operators
  are already allocation-free; identifiers still allocate their `String` (fundamental until interning).
- **LLVM sub-stage timing split** `[observability · needs-grounding]` — the `codegen` timing bucket is
  the whole `emitObject` call (IR→LLVM lowering + transform passes + object emit). Split it with timing
  hooks inside `LLVMBridge`. Driver-level stages (lex → link) already report per-stage (`Timings`).
- **Streaming / pull lexer** `[refactor · needs-design]` — a `pull_next_token()` model instead of
  full up-front tokenization, to cut peak memory / allow lex+parse overlap. `Lexer.next()` is already
  the pull primitive; a pull driver needs a rewindable lookahead buffer for the parser's backtracking.
  Parked — the batch model is fine and this is not a throughput lever.
- **Float-exponent literals** `[language-feature · needs-design]` — accept `1e9` / `2.5e-3`. Small
  lexer change plus syntax agreement; today only the decimal-point form (`3.14`) lexes.
- **Fiber-pinned mutator cache** `[perf · needs-grounding]` — the §6.6 inline alloc fast path reads the
  per-carrier MMTk mutator via the thread-local `rt_mutator`; on macOS a thread-local read compiles to a
  `_tlv_get_addr` call, so the fast path is not fully call-free on Darwin. Cache the mutator where
  codegen can reach it without a tlv call (a fiber/carrier-pinned slot or a reserved register), removing
  the per-alloc tlv cost. Ground against a profile first — confirm the tlv read actually dominates the
  alloc fast path before building. Ref: the inline alloc seam, `compiler.md` §2 (GC backend substrate).

---

## User-level language surface (backlog, 2026-08-18)

Core surface features raised together (2026-08-18). Each is `needs-design` unless noted; terse on
purpose — promote to a full What / Why / Trigger / How entry when picked up. The **Roadmap** line
records the three-head assessment (architecture ripple / performance envelope / programmer
expectations) as input, pending a roadmap decision.

- **`init`** `[language-feature · needs-design]` — custom initializers beyond today's synthesized
  memberwise `T(field:)`. Opens: init-body validation/normalization, multiple inits + overload
  resolution, failable init (`init?` → `Option`/`Result`), designated-vs-convenience (if any), and
  default field values. **Roadmap: one-liner pointer.** Reshapes the construction contract
  (programmer-expectation) but rides the type-system track; the memberwise-only form is a placeholder
  the roadmap should flag as provisional.

- **`deinit` / finalization** `[language-feature · needs-design]` — cleanup hooks on classes (and
  actors?). Under a moving generational GC this is finalization: run timing (GC-scheduled), ordering,
  resurrection, keep-alive/pinning, the finalizer queue, and interaction with the M8 linear types +
  `defer` (deterministic cleanup). **Roadmap: yes.** Hits all three heads — finalization is a GC
  subsystem (architecture), finalizers add collector work and pin objects (perf envelope), and "when
  does my cleanup run" is a core contract (programmer-expectation). The fork — whether classes get a
  GC-finalized `deinit` at all, versus deterministic cleanup only through linear/`defer` — gates the
  resource-management story and belongs next to M8. **► Decide-early (ahead of roadmap):** decide this
  fork alongside M8's `defer` + linear-types resource-cleanup work — same problem space.
  (Design-ahead, not build-ahead.)

- **Tuples** `[language-feature · needs-design]` — anonymous structural product types, multiple return
  values, destructuring. Ripple: structural aggregates in a nominal type system, the multi-value
  return ABI + cost model, pattern-match integration, and whole-aggregate value reads (the category-3
  FCA / D6 spill, `c-types.md` §3.4). **Roadmap: yes (or strong one-liner).** Structural types plus a
  multi-return calling convention are type-system and ABI foundations later features design around;
  pairs with pattern matching.

- **Operator overloading for user types** `[language-feature · needs-design]` — two forks, decided
  separately:
  - *Closed-set overloading via interface conformance* — user types implement the built-in operators
    (`==`, `<`, `+`, …) as interface requirements (`generics.md` §10, operators-as-requirements).
    Today `String` uses `.eq(...)` and aggregates have no comparison. **Roadmap: one-liner pointer** —
    interface/generics maturity; programmer-expectation ripple (writing `a + b` / `a == b`). Extends
    the "Operator surface design" item above.
  - *User-defined custom operators* (new operator tokens + precedence) — **Decided 2026-08-18: hold
    closed.** Custom operators pull on parser architecture (precedence/ambiguity) and cut against
    `syntax.md` §1 ("one canonical way; resist a second form"). Kept out unless a concrete need
    reopens it. Roadmap: none.

- **Pattern matching (full)** `[language-feature · needs-design]` — generalize today's enum-case
  `switch` + exhaustiveness IR pass into real patterns: nested / tuple / struct destructuring, value
  and range patterns, wildcard `_`, guards, or-patterns, and binding forms (`if let` / `guard let`).
  **Roadmap: yes — milestone-scale.** The match compiler (decision-tree / automaton lowering +
  generalized exhaustiveness) is a compiler subsystem; patterns are a core reasoning surface; match
  compilation quality is a perf lever. Depends on tuples/enums. "The big one."

- **Parameter labels + argument model** `[language-feature · needs-design]` — scope (decided
  2026-08-18): label rules (external vs internal name, omission) and whether labels are part of API
  identity / overload resolution; **default argument values**; and **argument evaluation order**.
  Variadics out of scope for now. **Roadmap: one-liner pointer** (leaning yes). The label grammar is
  trivial; the weight is default args + label-as-identity pulling on overload resolution and the
  call-site cost model (default-arg lowering / ABI), plus evaluation order as an observable contract.

---

## Fiber stack strategy: growth, overflow, and high-fiber-count throughput

**Type / Lifecycle:** `perf · needs-design` (runtime + compiler architecture). **Evaluate.** Raised
2026-08-18; also goal-3 of the current design session ("fixed vs dynamic stack").

**► Decide-early (ahead of roadmap): before M8.** M8 scopes growable fiber stacks; the fixed-vs-dynamic
decision must precede that build. This session's goal 3. (Design-ahead, not build-ahead.)

- **What.** Decide how fibers get their stacks so Nomu runs very high fiber counts at throughput
  beating Go/Swift. Today: a fixed `RT_STACK_SIZE` = 128 KiB per fiber (`runtime.c`), with no
  stack-overflow detection or recovery and no compile-time bound analysis. The space to evaluate:
  fixed stacks (current), guard-page + lazy commit (reserve large virtual, fault in physical pages),
  copy-on-grow / movable stacks (relocate on overflow, fixing interior pointers via precise stack
  maps), segmented stacks (rejected historically by Go for hot-split), and compile-time stack-depth
  analysis (bound per call-graph — size statically or flag unbounded recursion). The answer is likely
  a hybrid.

- **Why it's open — the tensions.** Three forces pull against each other:
  - **Memory floor per fiber** sets the max fiber count in RAM. 128 KiB × millions is the ceiling; a
    smaller default plus growth is what unlocks massive fan-out (the M8 dynamic spawn group's
    workload).
  - **Context-switch + call cost.** Fixed stacks keep function prologues free of any stack-limit
    check. Growable stacks in Go's style add a per-call `morestack` check — a throughput tax the
    "better than Go" target has to weigh. Guard-page recovery keeps prologues free but pays on the
    fault and leans on virtual-address reservation.
  - **GC coupling.** Moving a stack means relocating every root and interior pointer into it, which
    the precise stack maps (M9 statepoints) + the M6 parked-fiber precise scan already make possible;
    copy-on-grow reuses that walk (roadmap M8 note). Stack strategy is therefore tied to the GC root
    machinery.

- **Architectural reach — "how much derives from it."** Depends on the choice:
  - *Guard-page + lazy commit*: mostly a runtime change (mmap layout + fault handler); codegen/ABI
    largely untouched. Lowest ripple; costs virtual address space and is hard to shrink.
  - *Copy-on-grow / movable*: threads through codegen (prologue stack-limit check or fault
    trampoline), the calling convention, and the GC (pointer fix-up on relocate). Highest ripple;
    matches Go's proven high-fiber model.
  - *Compile-time bound analysis*: a new whole-program pass over the call graph (recursion + indirect
    / witness calls are the hard cases); shrinks default stacks or statically rejects unbounded
    growth, complementing either runtime scheme.
  What the item must answer: quantify what each option forces to be rewritten, so the choice is made
  with the blast radius known.

- **Trigger.** Roadmap M8 (growable stacks + syscall-free switch, riding the dynamic spawn group).
  Bring the *decision* ahead of the build — runtime + codegen shape depend on it, and it underwrites
  the "insane throughput at high fiber count" thesis.

- **Refs.** `runtime.md` §6 (safepoints, parked-fiber precise scan, mutator); `roadmap.md` M8
  (growable-stacks note); `runtime.c` `RT_STACK_SIZE` + `swapcontext` switch.

- **Roadmap.** **Yes — elevate.** All three heads: architecture (codegen / ABI / GC coupling under
  copy-on-grow), performance envelope (the memory-per-fiber floor and the per-call stack-check tax set
  the high-concurrency ceiling), programmer expectations (whether deep recursion is safe, and whether
  overflow crashes or recovers). It already sits on the roadmap as an M8 perf-tail one-liner; promote
  it to a first-class design question, since the "better than Go" concurrency thesis rests on it.

---

## Memory debugging / heap introspection

**Type / Lifecycle:** `observability · needs-design`. **Evaluate** (importance uncertain). Raised
2026-08-18; likely very late-stage.

- **What.** Developer tooling to inspect the live heap: an object-graph view, retention / root paths
  ("why is this object still alive"), allocation + footprint profiling, per-type live counts. The
  analogue is Xcode's memory-graph view.
- **Why the rationale differs from Swift.** Xcode's memory graph earns its keep mostly by finding
  reference cycles, which ARC leaks. Nomu's moving GC collects cycles, so that use disappears. The
  value that remains in Nomu is *logical* retention — an object held alive by an unintended root or
  reference (a cache, a long-lived collection) that the collector correctly cannot reclaim — plus
  allocation / footprint profiling, which feeds the LXR footprint-endgame goal.
- **How it would build.** Reuse the GC's object-graph walk (the precise scan already enumerates roots
  + references) to snapshot the live graph; surface retention paths from roots to a selected object;
  host it on the M11 runtime-aware debugger plugin (DAP) and/or the M10 tooling surface. Opt-in
  instrumentation, off the steady-state hot path.
- **Trigger.** Late — after the M11 debugger (GC-aware stepping, data formatters) exists to host it,
  and once benchmark-scale programs (the LXR gate's stdlib) create heaps worth inspecting.
- **Roadmap.** **Deferred-only.** Fails the three-head test: low architecture ripple (reuses the GC
  walk), no steady-state perf cost (opt-in), no change to a programmer's reasoning contract. Rides
  M10/M11 tooling as a feature. Worth a mention inside the M11 debugger scope so it stays on the list.

---

## First-class FFI to the C ABI

**Type / Lifecycle:** `language-feature · needs-design` (runtime + GC + codegen). **Evaluate.** Raised
2026-08-18. Substrate partly grounded (`c-types.md`, `runtime.md` §5 attach + pinning); the
first-class surface and call semantics are open.

- **What.** Direct, low-overhead interop with the C ABI as a primary language feature — call C
  functions, pass/return C-compatible types, expose Nomu functions to C, and hold C-side callbacks.
  "First-class" means cheap calls, layout-compatible structs (`c-types.md`), and an ergonomic binding
  surface (over today's hand-written shims).

- **Why it's architecturally heavy (moving GC + colorless concurrency).**
  - **Pinning.** A managed pointer handed to C must stay put while C holds it. The moving Immix
    collector has to pin (or copy) across the boundary — direct coupling to relocation.
  - **Foreign-thread attach.** A C thread that calls into Nomu must attach to the runtime: acquire a
    mutator context, register roots, and participate in safepoints (`runtime.md` §5).
  - **Safepoint transition.** A fiber inside a C call cannot reach a safepoint, so the runtime marks
    in-C as a parked/blocked state (like syscall offload) so stop-the-world GC does not wait on it —
    with the leaf-call vs may-call-back distinction (a callback re-enters the runtime).
  - **Marshalling + ownership.** C ABI type mapping (structs, `String`, pointers), who owns
    passed/returned memory (malloc heap vs GC heap), and copy-vs-borrow at the boundary.

- **Perf envelope.** The pin/unpin + safepoint-transition cost per call decides whether C interop is
  usable in hot paths. First-class means the common leaf call approaches a raw C call; the design has
  to keep the boundary thin.

- **Programmer expectations.** What is safe to pass to C, whether and how callbacks work, ownership and
  lifetime rules across the boundary, and the thread-safety contract for foreign calls — a learnable
  contract.

- **Trigger / sequencing.** Currently "Ongoing" on the roadmap. The substrate (attach + pinning) rides
  the runtime; the surface benefits from modules (binding organization) and matters once real C
  libraries are wanted (stdlib primitives, OS interfaces). Settle the pinning + safepoint-transition
  model before the surface is built.

- **Refs.** `c-types.md` (C type mapping), `runtime.md` §5 (foreign-thread attach + pinning), §6
  (safepoints / parked scan), `compiler.md` §2 (backend / calling convention).

- **Roadmap.** **Yes — promote from "Ongoing" to a first-class design question.** All three heads:
  architecture (pinning + attach + safepoint transition thread through GC, scheduler, codegen),
  performance envelope (per-call boundary cost decides hot-path usability), programmer expectations
  (the safety / ownership / threading contract). The moving collector makes this harder than a
  non-moving runtime would, so the decision should be made explicitly.

---

## Self-hosting the runtime: GC + scheduler in Nomu, bootstrapped in assembly

**Type / Lifecycle:** `perf · refactor · needs-design` (runtime + language subset + compiler + GC).
**Evaluate.** Raised 2026-08-18 — an author north-star ("a powerful, tiny language runtime"),
self-described as maybe-not-critical but strongly wanted.

- **What.** Rewrite the runtime — the garbage collector and the M:N scheduler — in Nomu itself,
  compiled by the Nomu compiler, with a small per-architecture assembly floor to bootstrap (context
  switch, entry / TLS / stack setup, the pre-runtime moment). The model is Go's: a runtime written in
  the language plus arch-specific asm stubs. This replaces MMTk (Rust, the ~26 MB link archive) and
  the C runtime (`runtime.c` / `core.c`).

- **Three goals (author's framing).**
  1. **Remove Rust and C** — a pure Nomu + assembly runtime; no foreign-language dependency in
     produced binaries.
  2. **Performance** — the runtime compiles through the same optimizing backend (SSAIR passes +
     LLVM), so runtime operations (allocation fast path, write barriers, scheduler hooks) can inline
     into user code across the former runtime/user boundary, the way Go's in-language runtime does.
  3. **Binary-size ceiling < 999 KB** — with the GC/scheduler present and essential (the ceiling
     holds without relying on dead-stripping them out), the whole self-contained runtime still fits a
     tiny footprint. Removing the 26 MB MMTk archive is the enabler; monomorphization + DCE keep only
     the runtime paths a program uses. *(Reading of "no dead_stripping GC/scheduler": the ceiling
     holds even though the runtime is always linked in — flag if this misreads the intent.)*

- **Why it's architecturally enormous.**
  - **A runtime-Nomu subset.** GC and scheduler code must avoid recursively invoking the services
    they implement: no implicit GC allocation, no write barrier, no unplanned safepoint, controlled
    stack growth. This needs a language mechanism analogous to Go's runtime pragmas (`//go:nosplit`,
    `//go:nowritebarrier`, `//go:noescape`) — a way to mark and check runtime-level code. New surface
    + new checking.
  - **Bootstrap floor.** The irreducible per-arch assembly: context switch (today C `swapcontext`),
    thread / TLS / stack setup, the entry sequence before the collector and scheduler are live.
  - **Collector replacement + LXR overlap.** The collector itself in Nomu, and its relationship to the
    **LXR footprint-endgame** item (also an owned reimplementation behind `VMBinding`). These may be
    one effort — LXR could be the collector that gets written in Nomu. Decide whether to fold them.
  - **Compiler support.** Emitting code that satisfies the runtime-subset constraints, the
    asm-interfacing calling convention, and the bootstrap linkage.

- **Perf envelope.** Goal 2 is explicit. The upside is inlining hot runtime ops into user code once
  the boundary dissolves; the risk is that a Nomu-written collector must match a tuned native one.
  Against the "faster than Go/Swift" thesis this is upside (Go proves the model), contingent on the
  backend + runtime-subset being good enough.

- **Programmer expectations.** Mostly internal, with a real outward promise: a single, tiny,
  dependency-free relocatable binary — part of the language's identity as a powerful tiny runtime.

- **Base prerequisites.** **Unsafe raw pointers / raw-memory primitives** are a hard floor — the
  collector and allocator manipulate untyped memory. Also: the runtime-subset mechanism and the stdlib
  low-level primitives (byte buffers).

- **Trigger / sequencing.** Implementation is very late (needs a mature, performant Nomu — M7
  optimizer, M9 backend — plus the prerequisites above). **Design early, build late (decided
  2026-08-18):** settle the runtime-subset mechanism and the unsafe raw-pointer surface ahead of time
  so later decisions do not foreclose this, even while the build waits. Fits after the language is
  self-sufficient; naturally paired with (or subsuming) the LXR collector effort.

- **Refs.** `roadmap.md` (LXR endgame; MMTk removal noted in the M7 handoff), `runtime.md` (scheduler,
  safepoints, mutator), `memory-model.md` §3 (object model / `VMBinding`), `compiler.md` §2 (backend
  substrate).

- **Roadmap.** **Yes — a named late epoch (or fold into the LXR endgame).** All three heads at
  maximum: architecture (a self-hosting runtime + runtime-Nomu subset + bootstrap replace the entire
  GC/runtime substrate), performance envelope (goal 2 plus the < 999 KB footprint ceiling), programmer
  expectations (the tiny dependency-free binary promise). Even as a passion/optional item, its pull on
  earlier decisions — keep `VMBinding` clean, keep the runtime minimal, design the runtime-subset
  mechanism when annotations/effects are on the table — argues for a roadmap anchor so nothing
  forecloses it.

---

## Tail call optimization

**Type / Lifecycle:** `perf · needs-design` (the guarantee question is `language-feature`). **Evaluate.**
Raised 2026-08-18.

- **What.** Reuse the caller's frame for a call in tail position, so tail recursion (and mutual
  recursion) runs in constant stack space instead of growing the stack per call.

- **"Tiny pass or something bigger?" — both, by scope.**
  - **Self-tail-call → loop:** a small SSAIR pass. Rewrite a function's tail call to itself into a
    back-edge to entry with parameter reassignment — a tail-recursive function becomes a loop. High
    value, self-contained, the common case.
  - **General proper tail calls** (tail calls to *any* function, mutual recursion, trampoline/CPS
    styles): larger. Needs the frontend/backend to emit LLVM `musttail`, a uniform calling convention
    across the tail edge, and care around the moving GC — `musttail` + statepoints (precise stack
    maps) have known friction, and the safepoint/stack-map story must still hold when the frame is
    replaced.

- **The real fork — guarantee vs best-effort.** Is TCO a **language guarantee** (unbounded tail
  recursion is always safe, Scheme-style) or a **best-effort optimization** (applied when it can be,
  Swift/Go-style)? This is the deciding axis:
  - *Guaranteed* is a programmer-expectation contract — people can write loops as tail recursion and
    rely on constant stack. It forces the general-proper-tail-call machinery and interacts with the
    fiber stack strategy and GC statepoints.
  - *Best-effort* is a pure optimization with no contract; the self-tail-loop pass covers most of the
    real-world win.

- **Interactions.** Couples with the **fiber stack strategy** item (TCO lowers stack depth, easing the
  high-fiber-count memory floor) and with **GC safepoints/statepoints** (frame reuse under precise
  stack maps).

- **Trigger.** The self-tail-loop pass can land opportunistically inside SSAIR (M7 tier) once there's
  a workload. The guarantee-vs-best-effort decision wants settling before the stack strategy is
  finalized, since the two constrain each other.

- **Roadmap.** **One-liner pointer — for the guarantee decision only.** The *optimization* is
  deferred-only (an SSAIR/LLVM pass, no ripple). The *guarantee* is a programmer-expectation contract
  (unbounded tail recursion safe or not) that couples with the stack-strategy item, so that one
  decision belongs on the roadmap. Default lean: best-effort self-tail-loop first; revisit a guarantee
  if a functional style or the self-hosting runtime wants it.

---

## IR hardening / polish: format, stage I/O, machine-readability, streaming

**Type / Lifecycle:** `refactor · observability · needs-design`. **Evaluate.** Raised 2026-08-18.
Anticipates the compiler growing into a large system that needs tools running over its IRs.

**► Decide-early (ahead of roadmap): inject into the current M7.** SSAIR is new right now; set the
format + stage-boundary discipline before more IR node kinds and passes accrete. Cheapest moment.
(Design-ahead, with a light build.)

- **What.** Harden the intermediate representations (AST, NOIR, SSAIR) from debug dumps into
  deliberate, durable formats. Four evaluation axes:
  1. **Format covers current + future needs** — a versioned, extensible IR text format (new node kinds
     / fields without breaking readers), designed once across all three IRs as a shared discipline.
     Today each IR has an ad-hoc printer (e.g. `SSAIRDump`); emit is file-based under `build/`
     (`--emit-ast/-noir/-ssair`, `--stop=`).
  2. **Per-stage I/O override** — each stage as a function `IR_in → IR_out` with parse + serialize at
     the boundary, so a stage runs on an injected artifact (hand SSAIR a `.noir` file, skip the
     frontend). Enables **per-stage unit tests** and treating a stage as an **invariant** (golden IR
     fixtures in, expected IR out). Needs a *parser* per IR (round-trip), stable stage boundaries, and
     a `--start-from` counterpart to `--stop`. Generalizes the "Intermediate-based iso regression"
     backlog item.
  3. **Machine-readability** — the formats self-consistent and semi machine-readable (a defined grammar
     / structured syntax) so external tools — verifiers, visualizers, diff/localization tools — run
     over IR as the compiler scales.
  4. **Streaming** — whether IRs are processed/emitted incrementally versus whole-module in memory.
     Evaluate want/need; ties to the deferred "Streaming / pull lexer" item and compile-time memory.
     Likely defer (the batch model is fine now).

- **Cost/value tension (goal 2, viability).** A round-trippable canonical format is an ongoing
  invariant: every IR change has to keep its parser in sync, whereas a print-only debug dump is free to
  drift. The payoff — per-stage tests, stage-as-invariant, tooling — has to beat that maintenance
  carry. Worth scoping: full round-trip for every IR, or only the stage boundaries unit tests target.

- **Trigger / why early.** The format + stage-I/O contract gets more expensive to retrofit as more
  stages and IR node kinds accrete. Settle the format discipline early even if full tooling comes
  later. Fits the M7 IR tier (SSAIR is new) and the M10 tooling milestone.

- **Refs.** `compiler.md` §1 (pipeline / IRs), the emit/stop flags (`--emit-*`, `--stop=`),
  `SSAIRDump` / `SSAIRGen`, `NOMU_DUMP_SSAIR_PASSES`; deferred "Intermediate-based iso regression".

- **Roadmap.** **One-liner pointer.** Primarily the architecture head: a round-trippable, versioned IR
  format + decoupled stage I/O is a compiler-architecture foundation that testing and future tooling
  rest on, and it is cheaper decided early. Little perf-envelope or programmer-expectation ripple (an
  internal concern), so a roadmap anchor for the *format / stage-I/O discipline* is enough — it rides
  M7 (IR tier) and M10 (tooling) rather than a standalone milestone.

---

## Modules + multi-file / multi-module compilation

**Type / Lifecycle:** `language-feature · needs-design` (language + compiler + driver + build system).
**Evaluate.** Raised 2026-08-18. The largest missing architectural piece; trigger for several parked
items.

**► Decide-early (ahead of roadmap): the compilation-model fork before M10.**
Separate-compilation-vs-whole-program-mono constrains how much direct-to-LLVM / mono logic accretes,
and M10's LSP depends on modules for responsiveness. Decide the model early even if the full build
lands around M10. (Design-ahead, not build-ahead.)

- **What / scope.** A module system and separate multi-file / multi-module compilation:
  - **Modules + visibility** — multiple files, module boundaries, `public`/`private` (and any
    module-internal level). Changes how programmers structure and export API.
  - **Module interface format** — the artifact a consumer compiles against: exported signatures,
    types, witness tables, shareability facts, and (open) generic bodies for cross-module
    specialization/inlining. Analogues: Swift `.swiftinterface` / `.swiftmodule`, Rust crate metadata.
    This is the deferred "Module-level interface as input" item made concrete.
  - **Linker outputs** — per-module object files + symbol visibility / mangling across modules (builds
    on M4.15 mangling), and how they link into a final binary.
  - **nomuc scope / driver** — a driver refactor plus a scope decision: nomuc is a compiler today;
    modules push it toward an "uber CLI" like `swift` (`swiftc` + `swift run` + SPM). Decide — keep a
    pure compiler with a separate build/package tool, or fold build / run / package subcommands into
    one CLI.
  - **Incremental compilation** — a changed module recompiles without rebuilding the world. **Candidate
    to break out** as its own roadmap item; depends on the module interface + stable stage boundaries
    (ties to IR hardening).
  - **LSP** — the M10 query-based compiler server reasons in module units; modules + incremental are
    what make it responsive.
  - **Bazel + remote execution** — multi-module builds should run under Bazel and use its caching +
    remote build execution (RBE) fully. That requires hermetic, file-based per-module compilation
    (deps' interfaces in → object + interface out), which constrains the interface to a clean artifact
    and constrains nomuc to a "compile one module given its deps" mode.

- **The central architectural fork — separate compilation vs whole-program monomorphization.** The
  compiler today is single-CU with **whole-program monomorphization** (M5) and cross-everything
  inlining. Modules pull the other way:
  - Bazel RBE, incremental rebuilds, and LSP responsiveness all want **hermetic separate compilation**
    — each module built from its deps' *interfaces*, without re-reading their full source/IR.
  - Whole-program mono + cross-module inlining want **all IR present at once** (the runtime-perf and
    self-hosting goals lean here).
  These conflict. Resolution is likely a **hybrid**: separate compilation as the default build graph
  (fast, cacheable, RBE-friendly), plus an optional whole-program / LTO / cross-module-optimization
  pass for release builds (cf. Swift `-cmo`, Rust `-C lto`). Cross-module generics then need a
  decision: witness-passing at the boundary (no specialization — the machinery already exists for
  `any`) versus shipping generic bodies in the interface for use-site specialization (Rust-style).
  This fork sets the whole compile-time / runtime-perf tradeoff.

- **Perf envelope.** Two axes: **compile-time** (incremental + RBE + caching = build scalability) and
  **runtime** (whether cross-module inlining/specialization survives the boundary). The hybrid keeps
  both, at design cost.

- **Programmer expectations.** Module boundaries + visibility are a structural contract — API surface,
  what is exported, encapsulation. A real change to how code is organized and reasoned about.

- **Triggers this un-parks.** The `shared (A) -> B` / `shared any I` spellings (hidden bodies across a
  module boundary) and "Module-level interface as input" both fire when modules land.

- **Refs.** deferred: "`shared` on function-type / existential spellings", "Module-level interface as
  input", "IR hardening" (hermetic artifacts); `modules.md`; `compiler.md` §1 (pipeline), §2a
  (mangling); `roadmap.md` M10 (tooling / LSP).

- **Roadmap.** **Yes — a named milestone (with incremental compilation possibly split out).** All
  three heads, hard: architecture (separate-compilation-vs-whole-program-mono is a foundational fork
  the driver, backend, and generics model bend to), performance envelope (compile-time scalability +
  cross-module runtime perf), programmer expectations (modules + visibility restructure how code is
  written). It gates parked work and underlies LSP + Bazel scaling. Consider breaking out **incremental
  compilation** and the **nomuc uber-CLI / build tool** as adjacent items if the milestone gets broad.

---

## SIMD (stdlib module + backend support)

**Type / Lifecycle:** `language-feature · needs-design` (stdlib + backend + type-system). **Evaluate.**
Raised 2026-08-18. Motivating case: a SIMD-backed swiss-table as the default `Table`.

- **What.** Explicit SIMD in two layers: a **stdlib SIMD module** (fixed-width vector types +
  elementwise ops, comparisons, reductions, movemask), similar to Swift's `SIMD` types; and **backend
  support** lowering them to LLVM `<N x T>` vectors + target intrinsics (SSE/AVX, NEON) with a scalar
  fallback. LLVM's native vectors + autovectorization supply the plumbing; the surface, type-system
  integration, and cross-target abstraction are the work.

- **Motivating example — swiss tables.** The durable point: **SIMD is used in hash maps.** A
  Google-swiss-table / hashbrown-style flat map scans 16 control bytes per probe with a SIMD
  byte-compare + movemask, which is why a fast future `Table` wants SIMD capability. Everything past
  that point is open research/design:
  - **No "real" stdlib hash map exists yet.** Today there is a tiny hand-written Nomu prototype that
    works (`examples/benchmarks/hashmap.nomu`, concrete `String → Int`). The eventual real, generic
    map — its algorithm (swiss-table or otherwise), and whether it lives in the C `core` floor or in
    Nomu — is undecided.
  - **Whether it consumes the *Nomu* SIMD API is conditional.** If the real map ends up in the C
    `core` floor (M4.13), it can use C intrinsics directly and needs no Nomu SIMD surface. If we push
    to remove the C floor (the self-hosting-runtime goal — a pure Nomu + asm core), the map becomes
    Nomu and consumes the Nomu SIMD module. So the swiss-table motivates SIMD *capability*; its
    dependence on the *stdlib SIMD API* rides the C-core-floor decision. Cross-ref: "Self-hosting the
    runtime".

- **The architectural fork — const generics or a fixed family.** `SIMD16<UInt8>` wants an integer
  (const) type parameter, which Nomu's generics (type-params only) lack. Two paths:
  - **Const / value generics** (`SIMD<let N: Int, T>`) — a real type-system feature that also unlocks
    fixed-size arrays and other width-parametric types. Larger ripple.
  - **Fixed generated family** (`SIMD2`…`SIMD64` + a `SIMDScalar`-style interface) — Swift's choice;
    no const generics, more generated code. Contained.
  This decision is the architecture-relevant part; the rest is stdlib + backend.

- **Also.** Aligned vector storage/layout, the vector-register ABI (ties to `c-types.md`), and
  cross-arch portability (logical widths lowered per target with scalar fallback — ties to the
  per-arch self-hosting story).

- **Dependencies.** The generic hash map (deferred, blocked on the D6 spill) and raw-memory /
  byte-buffer primitives (the control-byte array) both gate the swiss-table outcome.

- **Perf envelope.** Direct. A SIMD-backed default `Table` and a vectorizable stdlib move the
  achievable floor for collection + numeric code — a stated "faster than Go/Swift" lever.

- **Programmer expectations.** The SIMD module is opt-in for perf code (low reasoning-contract change);
  the *default `Table` being swiss-table-fast* is a programmer-facing perf contract.

- **Roadmap.** **One-liner pointer.** Driven by the perf-envelope head (fast default collections +
  vectorized stdlib) and the const-generics fork (type-system ripple if taken). Under the fixed-family
  path the SIMD module rides the stdlib/backend, and only the *const-generics decision* + the
  *SIMD-backed default `Table` commitment* need a roadmap anchor. Gated behind generic collections +
  raw memory.

---

## Standard library: core types + basic I/O

**Type / Lifecycle:** `user-facing · needs-design` (language + stdlib + runtime). **Evaluate.** Raised
2026-08-18. Large, cross-cutting; the GC gate is now lifted (M6 done). Seeds/expands the deferred
"Stdlib via language benchmarks" item.

- **What — two clusters.**
  - **Core data types:** strings (including the UTF-8 decisions), numbers, collections. Decide where
    each belongs (C `core` floor vs Nomu — M4.13), then create or polish. Other core types likely join
    here.
  - **Basic I/O to get programs started:** file I/O and network I/O, on the colorless blocking model
    (syscall offload, `runtime.md` §5). Other candidates likely (env, process, time, stdio).

- **Highest-stakes sub-decisions (permanent programmer contracts).**
  - **String / UTF-8 model** — the indexing unit (byte / Unicode scalar / grapheme cluster), the
    storage (UTF-8 backing, small-string optimization), normalization, and whether there is a `Char`
    type. Swift indexes by grapheme (O(n)) over a UTF-8 store; Rust exposes UTF-8 bytes with scalar
    `char`. Nomu's choice sets a permanent expectation *and* cost model (indexing complexity,
    iteration). `String` is a C primitive today, so this decision also revisits that placement.
    Programmer-expectation + perf, both hard.
  - **Numeric semantics** — fixed-width integer types (`Int` / `Int8…64` / `UInt*`), overflow behavior
    (trap-in-debug / wrap-in-release à la Swift, always-checked, or always-wrap), `Float` / `Double`,
    and conversions (`.double` / `.int` exist, `double_core.nomu`). Overflow policy is a safety + perf
    contract.
  - **Collections + value semantics** — `Array` (a basic one exists, `arr_*.nomu`), the map (open —
    see the SIMD/hashmap item), `Set`; and whether value collections are copy-on-write (ties to the
    surfaced CoW item — a cost-model contract).

- **Cross-cutting — where does it belong.** Each primitive sits somewhere on the C `core` floor ↔
  pure-Nomu axis. That placement couples with **self-hosting** (removing the C floor pulls these into
  Nomu) and **modules** (the stdlib as modules with interfaces). Decide per-primitive, consistent with
  those directions.

- **Dependencies.** Collections + strings want **raw-memory / byte-buffer primitives** (deferred) and
  the GC (done). I/O wants the **async runtime** (done), the **syscall-offload path** (`runtime.md`
  §5), and **error handling** (`Result` — I/O fails). Syscalls are already reachable: the privileged C
  runtime makes them and can expose a blessed set of I/O primitives as builtins (the way `print` /
  String ops are today), so I/O needs **no general first-class FFI**. FFI enters only under the
  self-hosting path (I/O written in pure Nomu calling libc) or for user-defined bindings. Numbers are
  largely self-contained once overflow policy is set.

- **Discipline.** Drive priorities by language benchmarks (the existing deferred item): build the
  lowest primitives first (String, byte buffers, raw memory, collections), measure, and let real
  programs set the order.

- **Perf envelope.** Direct and central — strings, collections, and byte buffers are the perf floor of
  real programs; the "faster than Go/Swift" thesis is measured on stdlib-heavy workloads.

- **Programmer expectations.** The stdlib is the surface programmers touch constantly — the String
  model, collection APIs + value semantics, numeric overflow, and the I/O model are all core mental
  model.

- **Roadmap.** **Yes — a named stdlib track (expand the "Stdlib via benchmarks" item).** All three
  heads: architecture (the C-floor-vs-Nomu placement + module packaging), performance envelope (the
  stdlib *is* the perf floor), programmer expectations (the daily surface). Call out **String/UTF-8**
  and **numeric overflow** as their own high-stakes decisions inside it — each sets a permanent
  contract. Collections gated on raw memory; I/O gated on the syscall-offload path (present) + error
  handling.

---

## Unsafe raw memory / raw pointers

**Type / Lifecycle:** `language-feature · needs-design` (language + backend + memory model).
**Evaluate.** Raised 2026-08-18. Load-bearing prerequisite for self-hosting, stdlib collections, and
SIMD.

**► Decide-early (ahead of roadmap): design before the stdlib track.** Collections, strings, SIMD, and
self-hosting all rest on it, so settle the unsafe surface before the stdlib work starts.
(Design-ahead, not build-ahead.)

- **What.** An unsafe layer: raw pointers, untyped memory (alloc/free off-heap or pinned within the GC
  heap), raw load/store, pointer arithmetic, and manual layout. The escape hatch below the safe type
  system that low-level code needs.
- **Why consequential.** It is a named hard prerequisite for:
  - **Self-hosting runtime** — the collector + allocator manipulate untyped memory.
  - **Stdlib collections + strings** — byte buffers, control-byte arrays (swiss-table), the String
    backing store.
  - **SIMD / c-types** — raw aligned storage, FFI marshalling.
  It also touches the **GC**: raw pointers into managed memory must be pinned or excluded from the
  moving collector's view, and the safe/unsafe boundary is where the GC's precise-root guarantee ends.
- **Design axes.** The unsafe surface (pointer type spellings — `Unsafe*Pointer`-style, or a
  capability), whether unsafe memory is GC-managed / pinned / off-heap, provenance + aliasing rules,
  and how much the compiler checks versus trusts.
- **Perf envelope + expectations.** Perf: the floor primitives rest on it. Expectations: a
  clearly-marked unsafe boundary is a contract — what safety is given up, what invariants the caller
  must uphold.
- **Roadmap.** **Yes.** Architecture (GC boundary + memory model) + perf envelope (the primitive
  floor). Consequential because so much rests on it — self-hosting, stdlib, and SIMD all name it as a
  dependency. Design early (per the self-hosting "design early, build late" note).

---

## Copy-on-write for value collections

**Type / Lifecycle:** `language-feature · needs-design` (memory model + stdlib + backend). **Evaluate.**
Raised 2026-08-18.

- **What.** Whether value-semantic collections (`Array`, the map, `Set`, `String`) are copy-on-write:
  a mutation on a uniquely-referenced buffer happens in place; a mutation on a shared buffer copies
  first. Swift's model. Requires a uniqueness check at mutation points.
- **Why consequential.** It is a **cost-model contract** programmers tune against — passing a big array
  by value stays cheap until a shared one is mutated. It shapes how value semantics is implemented
  across the whole stdlib, and it couples with the **GC**: the uniqueness check wants a reference
  count, which a tracing/moving collector does not maintain — so CoW needs a side count on the buffer
  or a different uniqueness mechanism. That coupling is the architectural piece.
- **Interactions.** The value/reference split (`memory-model.md` §2), the GC (uniqueness without RC),
  and every value collection in the stdlib.
- **Perf envelope + expectations.** Both, hard: it sets whether value-collection copies are cheap
  (perf) and the programmer's mental cost model for passing collections around.
- **Roadmap.** **Yes.** Perf envelope (the copy cost model) + programmer expectations (value-semantics
  contract) + architecture (uniqueness under a tracing GC). One of the more consequential items.

---

## Frontend surface features (error handling, optionals, iteration, associated types)

Grouped per the 2026-08-18 read: these are **primarily frontend**, without necessarily requiring
midend/backend changes. Each is still a real feature; the shared thread is limited pipeline reach.

- **Error handling: `?` operator + typed throws** `[language-feature · needs-design]` — the `?`
  propagation operator and typed throws over the existing `Result<T, E>` (M5 shipped `Result`;
  `?` / typed throws deferred, `types.md` §5). Mostly frontend: desugars to `switch` / early-return on
  `Result`; the error-return ABI is the one midend/backend touch. **Roadmap: one-liner pointer** — a
  programmer-expectation contract (how errors propagate), frontend-focused.
- **Optional ergonomics** `[language-feature · needs-design]` — `if let` / `guard let` binding forms
  and optional chaining `?.` over `Option<T>`. Overlaps **pattern matching** (binding forms are
  patterns) and error handling. Frontend desugaring. **Roadmap: deferred-only / fold into pattern
  matching** — ergonomic sugar, low ripple.
- **`for … in` + iteration protocol + ranges** `[language-feature · needs-design]` — `for x in xs`,
  range syntax (`0..<n`), and the iterator / sequence interface they lower to. The **iteration
  protocol** is the one non-frontend piece (a stdlib interface + how iteration borrows/owns); the loop
  lowering is frontend (to the existing `while`). **Perf contract (decided 2026-08-19):** `for … in`
  is the **bounds-check-free-by-construction** iteration path (safe-by-construction, Rust-iterator
  style) — so array iteration needs no bounds-check-elimination pass; the M7 BCE loop-bound case was
  descoped in favor of this (`m7-spec.md` §7.5). **Roadmap: one-liner pointer** — core surface, the
  iterator interface is a small design contract, and it carries this perf-envelope commitment.
- **Associated types + where-clauses on generics** `[language-feature · needs-design]` — associated
  types on interfaces (`associatedtype`) and `where` clauses on generic bounds. The heaviest of this
  group. Relatively frontend/sema-focused (type-checking + witness layout), though associated types
  add real type-system depth (existentials carrying associated types, path-dependent types).
  **Roadmap: one-liner pointer (leaning yes)** — type-system depth; frontend-focused but
  architecturally real for the generics model.

---

## Monomorphization cost model

**Type / Lifecycle:** `perf · needs-grounding`. **Evaluate.** Raised 2026-08-18.

- **What.** The code-size / compile-time cost of whole-program monomorphization (M5) — every generic
  instantiated per concrete type — and the tradeoff against dictionary / witness-passing (which Nomu
  already has for `any`).
- **Assessment (2026-08-18): low far-reaching derivatives.** A tuning knob — measure code-size /
  compile-time, and if it bites, offer witness-passing for size-sensitive generics. The consequential
  version of this question is the separate-compilation-vs-whole-program fork in the **modules** item,
  which is where the real decision lives.
- **Roadmap.** **Deferred-only.** No wide derivative. Revisit if binary size becomes a problem.

---

## Post-M9 backlog (raw)

Carried over from the retired `m8-spec.md` "post m8 ideas" list — things worth doing, not yet
scheduled. **Raw and terse on purpose**: each is a pointer, not a decided build. Promote an item
to a full entry above (What / Why / Trigger / How) when it's picked up. The `[size · when]` tag is
a rough estimate to help sequencing, not a commitment.

**Near-term cleanups (small; good between-milestone tasks, no gate):**
- **Clean up the LLVM experiments** `[small · anytime]` — remove the throwaway bring-up scaffolding
  now that 8.x is green: `src/llvmgen/llvm_smoke.cpp`, the `llvmswift_smoke` binary + its
  `main.swift`, and any dead 8.1 smoke targets. Low risk; shrinks the backend surface.
- **`nomuc` startup latency** `[profiled 2026-08-04; fix = opt build]` — `nomuc -h` is ~0.8 s with
  no compilation, **path-independent** and **99 % CPU** (0.81 s user / 0.01 s sys), i.e. it runs
  *before* `main`: **LLVM global constructors** (registering `cl::opt` options + target/pass
  registries across the linked Core/CodeGen/Passes libs). Only the host target (AArch64) is linked —
  not target bloat. The dominant factor is that both `nomuc` and libLLVM are built **fastbuild
  (unoptimized)** — 242 MB, 761 k debug entries — so that static-init code runs slow. **Fix:** ship /
  develop with an optimized build (`bazel build -c opt`, which optimizes LLVM's static-init paths and
  strips) — expected to cut startup several-fold; measure to confirm. No code change; a build-mode
  choice. (Not a code fix; folds into "compiler architecture review for perf".)
- **LLVM `-O` flag forwarding** `[small · partly done]` — the `-O`/`--release` toggle landed in
  8.5.3; remaining is finer control (explicit `-O0/1/2/3`, forwarding to the link step) if wanted.

**Compiler infra / pipeline (medium; opportunistic):**
- **Dead-code stripping** `[medium]` — strip unreachable functions/symbols from the emitted binary
  (LLVM `internalize` + `globaldce`, and/or `-dead_strip` at link). `-O` does some; a deliberate
  pass would shrink binaries.
- **Compiler perf diagnostics** `[per-stage timings landed 2026-08-11]` — per-stage timing prints on
  every invocation to stderr (`Timings`; driver stages lex → parse → sema → mono → codegen → runtime →
  link, with opt level + input size). Remaining: the LLVM sub-stage split (see "LLVM sub-stage timing
  split" above) and optional allocation counts.
- **Compiler architecture review for perf** `[medium · ongoing]` — a pass over the compiler's own
  hot paths (startup, monomorphization, lowering); the `nomuc -h` latency is one entry point.
- **Emission options** `[medium]` — broaden `--emit-*` / `--stop=` (e.g. emit LLVM IR, asm, object
  choices) beyond today's ast/noir/binary.
- **Intermediate-based iso(lated) regression** `[medium]` — regression tests keyed on intermediate
  artifacts (NOIR / LLVM IR), not just stdout+exit, to localize where a change diverges.
- **Bazel usage** `[small–medium]` — build-ergonomics cleanup (target layout, incremental build
  friction).

**Language features (large; later, some gated):**
- **`comptime`** `[large]` — compile-time evaluation. A whole feature; design not started.
- **Module-level interface as input** `[medium–large]` — accept a module's interface (signatures)
  as compilation input; ties into the deferred incremental-compilation / module-boundary work.
- **Stdlib via language benchmarks** `[large · gated on M6 / GC]` — once real GC lands, drive stdlib
  priorities from benchmarks: the lowest Nomu primitives (`String`, collections, byte buffers, raw
  memory) and e.g. swiss-table maps. Explicitly post-GC (collections need the collector).

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
  **D6 spill** (`c-types.md` §3.4; `m6-spec.md`).
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
  alloc fast path before building. Ref: `m6-spec.md` §6.6.

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

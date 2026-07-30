# Compiler & Toolchain

**Status:** working draft. The home for how Nomu is built — compiler architecture, the mid-level IR, backend strategy, the tooling-first stance, and the debugger plan. Status tags: **Decided**, **Deferred**, **Open**.

**Implementation language:** Swift (decided) for the compiler itself.

---

## 1. Mid-level IR above the backend

A typed **mid-level IR** sits between the parser and the code-generation backend; semantics-aware passes run on *this* IR, then lower to the backend (analog: Swift's SIL). — **Decided; the IR and the semantic pass that builds it were implemented in M4.9.**

**Two representations, Rust-staged.** The pipeline is `source → lexer → parser (untyped AST) → semantic pass → typed IR → IR passes → codegen (emit C)`. There are deliberately only two trees: the untyped **AST** (parser output) and one **typed structured IR** the semantic pass builds *directly* from it — no separate "typed AST" step, because our AST is immutable `enum`s and can't be annotated in place the way Swift decorates its mutable AST. Our typed IR ≈ **Rust's THIR**; the lower CFG/SSA level (deferred to M6, for escape analysis / GC barriers) ≈ **Rust's MIR / Swift's SIL**.

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

## 2. Backend strategy

- **Prototype: emit C or bind a simple backend** — throwaway scaffolding to get native execution fast and validate the surface + type system + runtime integration without building production codegen. — **Decided (direction).**
- **Release builds: LLVM**, for peak native performance, driven via a stable interface. — **Decided (post-prototype).**
- **Debug/dev builds: consider Cranelift** for fast compiles. — **Deferred.**
- **MLIR** if heavy language-specific optimization is wanted. — **Open.**

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

Things to revisit when the C codegen is replaced by the LLVM backend (M8). The C backend is scaffolding — these are the known gaps.

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

- **Runtime language + MMTk binding (M6).** — MMTk is Rust and exposes a C ABI; the irreducible Rust is a `VMBinding` binding crate, while callers can stay C. Open: keep the runtime (scheduler/allocator) in C with a thin Rust binding and codegen-inlined alloc fast path + barriers, vs. move the runtime to Rust for cleaner MMTk integration (rewrites the M4 scheduler). Codegen target stays C either way (emitting Rust rejected — `unsafe`-everywhere, throwaway before LLVM). Decided (2026-07-21) to **defer to M6** and proceed with M5 under two invariants (single alloc seam; explicit scannable object model — `m5-spec.md` §5a).
- **GC precision vs. backend (M6 ↔ M8 coupling).** — A moving collector (Immix) needs **precise stack maps**, which the C backend can't emit (§6). So precise MMTk may couple to LLVM (M8) more than the M6-before-M8 order implies. Alternatives on the C path: a **shadow stack** (codegen-maintained root list, portable, per-call overhead) or **conservative stack scanning** (no maps, but pins objects — fights a moving GC). Parked fiber stacks make precise scanning harder still. May reorder M6/M8; open.
- **MLIR vs. plain LLVM** for the release backend (§2).
- **Cranelift** for fast debug builds — when it earns its place (§2).
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

Hooks already in place that keep the door open: the IR carries debug info/spans from the start (§1), `ASTDump` gives a dump pattern to extend, and §3 commits to the query/incremental direction. The hardening itself is deferred until the minimal pipeline works end to end. — **Deferred (noted 2026-07-21).**

**Architecture evaluation (2026-07-30).** Checked whether the code is quietly foreclosing the three committed capabilities (debug info §1/§4, fine-grained incremental §8, query server §3), under the rule that C-backend-only limits are throwaway and only frontend/IR/LLVM-path gaps count. Findings: **debug info** is safe (the span invariant is held; the missing `#line` is C-backend-only). **Fine-grained incremental** (intra-module, per-file — "20 files, edit 2, rebuild 2") and the **query server** are the *same* engine (memoized per-decl queries + fingerprint invalidation); its prerequisites (multi-file input, per-unit codegen, dependency/fingerprint layer) are unbuilt but not foreclosed, and the soundness property that makes it work — **modular checking** (bodies depend only on referenced signatures) — is held. The **one live blocker** is in the frontend, which survives to LLVM: the lexer/parser/typechecker **`exit(1)` on first error** with no recovery, contra the §3 server commitment. Actionable frontend backlog: `src/frontend/README.md`.

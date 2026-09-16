# 154 — Source-tree decomposition (large-file grokkability)

Status: **in-progress** · Avenue: Infra · Size: L

## What

Break the compiler's largest Swift source files into hierarchical capability files so
that reading a file's header (doc comment + imports + type/namespace name) tells you
whether the detail you want lives there. The four non-test files over 1k LoC are the
scope:

| File | Start | Now |
|---|---|---|
| `frontend/sema/sources/Sema.swift` | 3099 | 556 (done) |
| `midend/ssairgen/sources/SSAIRGen.swift` | 1311 | — |
| `llvmgen/SSAIRToLLVM.swift` | 1198 | — |
| `frontend/parse/sources/Parser.swift` | 1060 | — |

## Why

A single 3k-line file forces a full read (or blind grep) to answer "does this file
contain X." Hierarchical files with a one-line "what's in here" header make the tree
cheap to navigate — for humans and for the assistant, whose per-file read cost is the
bottleneck. The goal is grokkability, not line-count golf: only extract a **cohesive
capability**, never scatter one concern across files.

## Decomposition guidelines

Learned while decomposing Sema; apply to the other three.

1. **Keep the hub, extract capabilities.** The central mutable walk stays put — the AST→IR
   lowering methods and the shared oracle (`resolve`, `checkExpr`, `checkCall`, the interface
   queries). Reading the hub file should still show what the pass *does*. Extract the
   self-contained capabilities *around* it.
2. **A capability is a caseless-enum namespace of `static func`s over the state.** Call sites
   read `PointerIntrinsics.checkRawPtrMethod(&s, …)` — the owning capability is explicit at
   every call, which is the readability a bare free function loses. `static func` on a
   caseless enum is a free function with a name prefix; zero runtime cost.
3. **Value semantics, always.** Pass `inout State` for a capability that mutates the state,
   `borrowing State` for one that only reads (copy-free, and callable from non-mutating
   contexts like `resolve`). Never introduce a reference-type context object — see
   Performance below.
4. **Draw the boundary on coupling, not on topic.** A function with few external callers
   moves cleanly; a primitive used pervasively by the hub stays. In Sema the shared oracle
   (`resolve`, `transitiveBases`, `aggregatedMethods`, `unify`/`substitute`/`mismatch`,
   `typeNameAndArgs`) stayed; the capability-specific logic moved. Map both directions before
   cutting: external callers to rewire, and what the moved code calls back into.
5. **Finished-format passes are the cleanest cut.** A pass that consumes a completed module
   and calls nothing back into the hub (Sema's `Mutation`, `Exhaustiveness`, `RuntimeSubset`)
   can be a free function, or even its own module. Mutually-recursive capabilities (they call
   the hub and the hub calls them) must stay in the same module — a module wall would be a
   dependency cycle — so they get a namespace, not a module.
6. **Minimal visibility widening.** Drop `private → internal` only for the members a capability
   touches. Everything stays module-private; the module's public API is unchanged.
7. **A pass may add elements the generator never emitted** (e.g. mutation annotates the IR).
   Treat the generated module as an input to later passes, never as final.

## Performance considerations

Principle #1 of the language is extreme performance; the *compiler's* own hot path (the
recursive type/expr walk) is measured, so the decomposition must not regress it.

- **State stays a value type; behavior moves to namespaces over `inout`/`borrowing` it.** A
  micro-benchmark of the hot walk (recursive descent mutating shared state) showed a
  reference-type context (class) is **~70–80% slower** than the mutating struct — ARC
  retain/release plus pointer indirection plus lost in-place mutation. A two-object class
  split (immutable env + mutable state) was ~6% faster than a single class but still far
  behind value semantics. So: no context object; thread the struct.
- **`borrowing` for read-only capabilities** avoids copying the struct's ~15 COW field headers
  on every call, and lets non-mutating hub methods (`resolve`) call into them.
- **Caseless-enum `static func` namespacing is free** — benchmarked within noise (−2%) of a
  bare `inout`-struct free function.
- **Build/verify in `-c opt`.** The release `nomuc` is ~80 MB with ~15× faster process startup
  than the fastbuild binary; startup dominates each invocation, and the golden harness runs
  the binary ~95× per capture.

## Verification

`tools/ir-golden.sh` (added for this work) is the invariant every step holds:

- `capture <dir>` builds `//:nomuc -c opt` and emits NOIR (all examples, incl. error paths via
  `--stop=noir`) + SSAIR (clean-compiling ones) into a snapshot, in parallel (~2.5 s).
- `compare <before> <after>` byte-diffs two snapshots.

Baseline lives at `build/ir-golden/before` (gitignored). Each capability extraction is a
**pure move** (no forwarding shims), verified `IDENTICAL` against the baseline plus the
`frontend_tests` suite before the next. Fire-from-the-hip is safe because the baseline
localizes any behavior change to the step that introduced it.

## Subtasks

### 154.1 — Sema.swift (done)

3099 → 556. Extracted, each golden-`IDENTICAL` + tests-green:

- `RuntimeSubset.swift` (116) — the runtime-subset NOIR validation pass; joins `Mutation`
  and `Exhaustiveness` as a finished-module pass. Free function.
- `PointerIntrinsics.swift` (551) — `RawPtr`/`Ptr<T>` builtin typechecking. `enum` over `inout Sema`.
- `GenericInference.swift` (217) — generic call inference + generic-type construction/member
  typing. Shared primitives (`unify`/`substitute`/`mismatch`/`typeNameAndArgs`) stayed in Sema.
- `TypeResolution.swift` (94) — composite type formation (`any`/`some`/applied generics).
  `borrowing Sema`; `resolve` stayed as the hub dispatcher.
- `InterfaceModel.swift` (227) — refinement-graph validation, interface default checking,
  conformance checking, IR witness-table building. Mixed `inout`/`borrowing`; the interface
  *queries* stayed as the Sema oracle.
- `TypeChecks.swift` (~165) — scalar operator typing: `binaryResult`, `checkUnary`,
  `adoptUInt8Literal`, `isComparisonOp`, `checkComparison`. Pure helpers take no `Sema`;
  `binaryResult`/`checkComparison` are `borrowing`; `checkUnary` is `inout` (checks its operand
  through `s.checkExpr`).
- `EnumConstruction.swift` (~115) — `EnumType.case(args)` (and leading-dot `.case`) → typed
  `enumInit`: `buildImplicitEnum`, `buildEnumInit`, `buildGenericEnumInit`, `matchEnumArgs`.
  All `inout Sema`.
- `NOIRGen.swift` (~1237) — the whole NOIR-generation walk: declaration/member lowering
  (`lowerDecl`/`lowerGenericDecl`/`lowerMethods`/`lowerAccessors`/`lowerFunc`/`lowerActor`/…),
  statement lowering (`lowerBlock`/`lowerStmt`/`lowerSwitch`), and expression/call checking
  (`checkExpr`/`checkCall` + `coerce`/`checkAssignable`/`checkArgs`/`checkArgTypes`/`fieldType`/
  `recordOpaque`/`recordComposite`/`irVar`/`isMutableReceiver`/`rejectLetFieldTarget`). An `enum`
  over `inout Sema` (read-only leaves take `borrowing`; pure `irVar` takes none), matching the
  other capabilities — no cross-file `extension Sema`. Nested `coerce(checkExpr(…))` and
  `f(&s, …s.read…)` sites were hoisted to `let`s to satisfy exclusivity; output is byte-identical.

This completes the generation-vs-oracle split for Sema. The finished-module **passes** were
already their own files (`Mutation`, `Exhaustiveness`, `RuntimeSubset`); `NOIRGen.swift` is now
**generation**; `Sema.swift` (556) is the **oracle + driver + state** — `check()`, `collectGlobals`,
type resolution (`resolve`), the symbol/interface queries (`kindOf`/`methodDecl`/`transitiveBases`/
`aggregatedMethods`/…), `unify`/`substitute`, `ptrIntrinsic`, scopes, and the stored state. 154.1
is done.

### 154.2 — SSAIRGen.swift (1311)

Not started. Same generation-vs-passes lens: separate NOIR→SSAIR generation from SSAIR→SSAIR
passes; extract capability clusters around the core lowering walk.

### 154.3 — SSAIRToLLVM.swift (1198)

Not started. LLVM emission; likely splits by IR construct family (values/aggregates/control
flow/intrinsics) around the emit driver.

### 154.4 — Parser.swift (1060)

Not started. Recursive-descent parser; candidate cuts by grammar region (declarations,
statements, expressions/precedence, types) — note expression and statement parsing are
semantically close and should stay together if they share state.

### 154.5 — NOIRGen LoC reduction (done)

Follow-up to 154.1, each step golden-`IDENTICAL` + tests-green. Two shared shapes now have a single
definition in `gen/NOIRGen.swift`:

- `requirementCall(&s, receiver:, req, method:, selfAs:, args, at:)` — the witness / interface-default
  call shape (check args, resolve params+return with `Self` bound to `selfAs`, emit the `.methodCall`).
  Collapsed 5 sites: existential, opaque, bounded type-param, interface-default, inherited-default.
- `withMethodScope(&s, selfType:, fields:, params:, returnType:, block)` — push a scope, declare
  `self`(optional)+fields+params, set `currentReturnType`, lower the block, restore. Collapsed 4 sites:
  `lowerMethods`, `lowerStaticMethods`, `accessorBody`, `lowerFunc`.

The actor-handler body kept its inline scope setup — its fields are `[NOIRActorField]`, not
`[NOIRField]`, so it doesn't fit `withMethodScope` without generalizing the signature (not worth it
for one site). `NOIRGen.swift`: 1237 → 1225; the win is the removed duplication (nine former copies
of two shapes), not the line count.

## Refs

- `tools/ir-golden.sh` — the golden-IR verification harness.
- `frontend/sema/sources/` is grouped by stage: `core/` (Sema oracle + driver + `TypeResolution`),
  `gen/` (the NOIR-generation walk `NOIRGen` + its capability helpers `EnumConstruction`,
  `GenericInference`, `PointerIntrinsics`, `TypeChecks`, `Builtins`, `InterfaceModel`, `Shareability`),
  `passes/` (`Mutation`, `Exhaustiveness`, `RuntimeSubset`), `astpass/` (`Typechecker`,
  `ExtensionMerge`). Files overlapping gen and another concern live under `gen/`. The BUILD glob is
  `sources/**/*.swift` — folders are organizational only; it stays one `sema` module.
- `gen/NOIRGen.swift` is the model for moving a large recursive walk into a capability namespace
  (an `enum` over `inout Sema`, not a cross-file `extension`).
- Sibling finished-module passes already in this shape: `Mutation.swift`, `Exhaustiveness.swift`,
  `Shareability.swift`.

# Globals — module-private top-level `let`

**Avenue:** Risk · **Type/Lifecycle:** `language · runtime · needs-design` · **Size:** L · **Status:** in progress
(224.1–224.3 built; globals hold no GC-managed reference for now) ·
**Source:** [223](223-retire-the-c-floor.md).1, whose runtime globals need it; split out so globals are
designed for user code and the runtime together.

## What

Nomu has no globals today: the parser accepts only type and function declarations at the top level, and
sema, NOIR, SSAIR and LLVM have no global. This task adds them, under one rule for user code and the
runtime. The language-level rule lives in `../../language/modules.md` ("Initialization & entry point").

## Rules (agreed)

- A global is a top-level `let`, with an optional type annotation (inferred as for a local `let`).
  Top-level `var` is an error: state that changes after startup lives in an actor held by a `let`.
- A global is `private` or `internal`; `package` and `public` are errors. Public compile-time constants are
  [222](222-public-compile-time-constants.md).
- Its type is an immutable value that holds no GC-managed reference: numbers, `Bool`, `String` (a
  literal), and structs and enums built only from those. `RawPtr` is allowed in the runtime tier only.
  Actor references and strings computed at startup wait for open question 1's options A or B. Classes and arrays are rejected while
  they are shared mutable references (`../../internals/c-types.md` §3).
- **Constant or startup.** An initializer that evaluates at compile time becomes read-only static data.
  Any other is a startup global: it runs once before `main`, modules in topological order.
- **Order within a module: proven at compile time.** Startup initializers run in the order their reads
  require, following each initializer into the functions it calls (Go's rule); an interface or closure
  call is assumed to reach every candidate in the module. A cycle is a compile error naming the globals in
  it. With the order proven, every read sees the final value: a read is one load, with no check, emitted
  as an invariant load so LLVM may hoist and combine it.
- **Hot runtime state lives in static storage.** The runtime's hot-path values (the stop-the-world
  flag, the write barrier's values, the carrier-local slot's key, the space pointer) live in
  `Runtime.staticStorage` blocks: the global holding a block is a folded constant (a fixed address), and
  the values inside are written once at boot through `RawPtr`, so each read is one load, as with the C
  globals today.
- Why: every access stays in one module, where the module summary sees it; no form allows a data race or
  an initialization-order hazard. A store into a global is already a cross-fiber escape sink in inference
  (`../../internals/inference.md`).

## Design

1. **Syntax and sema.** `[private|internal] let name [: Type] = expr` at the top level. A global is a name
   function bodies resolve after locals; a global named like a function is an error. NOIR gains a global
   declaration and a global-read expression.
2. **Constant evaluation.** A small evaluator folds literals, arithmetic on them, string literals,
   `RawPtr.null`, struct and enum literals of constants, and reads of other folded globals. A folded global
   is an LLVM `constant` with an initializer.
3. **Startup globals.** Zero-filled storage written once by the module's init function. Each module emits
   an init function that first calls its direct dependencies' init functions, then runs its own
   initializers in the proven order; a done-flag makes it run once, so a module needs to know only its
   imports. Reads are invariant loads.
3a. **The ordering analysis** runs on the interprocedural fixpoint engine (task 168,
   `src/inference/sources/FixpointSolver.swift`; `../../internals/inference.md` "Scope-agnostic engine"),
   which condenses a call graph into strongly connected components and solves callees first. The fact is
   the set of startup globals a function may read, directly or through its callees (join: union; the
   lattice's height is the number of globals, so it terminates). Nodes are the module's functions and its
   startup initializers. Edges: direct calls; an interface method call to every implementation of that
   method in the module; a closure or function-value call to every closure and function value the module
   creates; a call into another module that passes it a closure or an interface value, to every one of
   those. Each initializer depends on the globals in its summary; a topological sort orders them, and a
   cycle is reported with its globals. The runtime module's init runs from C's `main` before the scheduler boots, under the runtime
   subset; the entry module's init (reaching every user module) runs at the top of `main`'s body on the
   main fiber, so user initializers may allocate.
4. **Linkage.** A global is emitted under its mangled symbol with non-internal linkage. A generic body
   shipped to another module for instantiation (the `.bir` closure) refers to that one symbol; unlike a
   private function's body, a global's storage is never duplicated.

## Open questions

### 1. A global that holds a GC-managed reference

An actor reference, or a `String` computed at startup, is a pointer into the moving GC heap. What the
collector does with the global's slot, and with the object it points to, is undecided.

**What other languages do:**

- **Go.** Package-level variables are initialized eagerly in dependency order before `main` (the rule
  Nomu adopted). They are precise GC roots: the linker emits pointer bitmaps for the data and bss
  segments, and the collector scans them every cycle. Go's collector does not move objects, so the slots
  are never updated.
- **Swift.** Globals initialize lazily on first access through a once-guard (`swift_once`), except a
  `main.swift` top level, which runs eagerly in order. Memory is reference-counted: a global holds a
  strong reference, so there is nothing to scan. Swift 6 requires a global to be a `Sendable` `let`,
  isolated to a global actor, or marked `nonisolated(unsafe)`.
- **Rust.** A `static`'s initializer must evaluate at compile time; it cannot allocate on the heap.
  Values computed at run time go behind `LazyLock` / `OnceLock` (a once-check on each access) and live
  forever. A static must be `Sync`; mutation goes through a `Mutex` or atomics inside it.
- **Zig.** Container-level initializers are evaluated at compile time. There is no run-time initializer
  and no collector; a value computed at run time is assigned to a `var` global from `main`.
- **Moving collectors elsewhere.** The JVM and .NET treat static fields as roots, report them to the
  collector, and update them when objects move. JikesRVM (MMTk's original host) puts its boot-image
  objects in an immortal, non-moving space and traces them as roots for their outgoing pointers.

**Decided for now: C.** It covers every global the runtime needs, and lifting it later (A or B) breaks no
program written under it. A or B is chosen when user code needs an actor reference or a computed `String`
in a global.

**Options:**

- **A. A precise root table** (Go, JVM, .NET). Codegen emits each module's managed global slots into a
  table, like the stack maps; the collector scans it as a root source each collection and updates slots
  when it moves their objects. A `let` global never changes after startup, so once every referent has
  been promoted a minor collection can skip the table. Cost: a scan of the managed global slots per major
  collection (and per LXR epoch, where roots are counted each epoch).
- **B. Immortal referents** (JikesRVM's boot image, MMTk's immortal space). A global's referent lives
  forever anyway, since the global never changes. At the end of startup the objects globals point to
  move once into a non-moving, never-freed space inside the barrier's range; the global slots then never
  change and need no table. Those objects behave as mature for the write barrier (an actor's state still
  changes) and are traced as roots for their outgoing pointers. Cost: a new kind of space in the
  collector, and the one move at the end of startup.
- **C. No managed references in globals** (Rust's and Zig's static data). Globals hold numbers, `Bool`,
  string literals and structs of those. Simplest; it drops the actor-reference form, so user state that
  changes after startup is passed explicitly.

Inference treats a global's referent as reachable from every fiber either way.

### 2. Ordering startup initializers within a module (decided)

Options weighed: trace the initializers' calls at compile time (Go); declaration order with no check (a
read reaching a later global through a call silently sees zero); or a once-flag per startup global (Swift's
and Rust's `LazyLock` check). Measured with clang `-O2` on arm64: a once-check inlined at a read in a loop
reloads the global every iteration, branches, saves registers around the possible initializer call, and
stops the loop from unrolling or vectorizing; Swift's remedy (an address accessor declared free of side
effects, so LLVM hoists it) restores the loop but leaves one call per non-inlined function. **Decided:
trace the calls (Go's rule).** Reads are then final and cost nothing beyond the load, the analysis reuses
the task-168 engine, and Go shows the compile-time cost is small. A true cycle is a compile error. For a
correct program the two approaches behave the same, so the choice is a codegen choice, not a language
one.

## Work

- **224.1** Syntax, the rules in sema, NOIR's global declaration and read. **Built.** The parser takes
  `[visibility] let|var name [: Type] = expr` at the top level (`GlobalDecl`; a `var` parses so sema can
  report it). Sema registers globals with the other declarations and checks every initializer before any
  function body, each in a scope of its own; reading a global not yet checked checks it first, so
  initializers name globals in any order, and a global reaching its own value is an error. A name
  resolves to a local, then a global, then a function. Errors: top-level `var`; `package` or `public` on
  a global; a type holding a reference (classes, actors, arrays, closures, existentials, generic types;
  `RawPtr` outside the runtime tier); assigning to a global or a field of one; a global named like a
  function (DuplicateCheck). NOIR has `NOIRDecl.globalDecl(NOIRGlobal)` and `ExprKind.globalRef`; the
  mid-end passes carry them, a shipped generic body keys a global by its origin and never ships it, and
  SSAIR lowering reports `global '…' is not lowered yet` until 224.2–224.3. Tests: two parser and ten
  sema unit tests.
- **224.2** Constant evaluation and static data. **Built.** Sema marks a global constant (`NOIRGlobal.isConstant`)
  when its initializer is built from literals, arithmetic and comparisons, a struct value or a
  payload-free enum case of those, `RawPtr.null`, and constant globals, whose folded values it substitutes
  in; `&&`/`||` (lowered to branches) and any call make a startup global. A non-constant global holding a
  `String` is an error (a computed string is a GC reference). SSAIR gains `globalRead` and
  `SSAModule.globals`; each global's initializer becomes a parameterless function (`global:<name>`). The
  egress folds a constant global's function by lowering its instructions in a scratch block, where LLVM's
  builder turns them into constants and inserts nothing (a poison or undefined result, such as a division
  by zero, is an error), then emits a read-only global under `Mangle.global` (`_RNv<module><name>`;
  `nomu_g_<name>` for the runtime, weak-ODR) and never emits the function. A read in the defining module
  uses the folded value directly; a read from another module (a shipped generic body) loads the producer's
  symbol, so storage is never copied. A payload-free enum value is now a constant aggregate everywhere.
  Startup globals still stop at SSAIR lowering until 224.3. Tests: `Mangle.global` unit tests, two sema
  tests (classification and substitution; a computed `String`), and suite cases `globals-const` (debug
  and release), `module-generic-global` (erased and `mono_all`, where the consumer holds an undefined
  reference to the producer's one global) and `global-string-computed`.
- **224.3** Startup globals: the ordering analysis (design 3a), per-module init functions, invariant-load
  reads, the runtime's init from C's `main` and the entry's from `main`'s body. **Built.** SSAIR lowering
  keeps a startup global's `global:<name>` function, and `orderStartupGlobals` (`ssairgen/StartupOrder.swift`)
  solves the reads on the task-168 engine and reorders `SSAModule.globals` into the proven order; a cycle is
  an SSAIR error naming each global in it. Edges as in 3a, plus a spawn to its routine and an actor send to
  every handler of that name (either may run before startup ends); a cross-module call passing a closure,
  an interface value or residual type arguments reaches every closure and method in the module. The egress
  gives a startup global zero-filled writable storage under its `Mangle.global` symbol, emits its
  `global:<name>` function (`<global>::init`) `noinline`, and reads it with an `!invariant.load` load. Every
  module defines an init function (`Mangle.moduleInit`, `_RNi<module>4init`), always, so a dependent can call
  it without knowing whether it has startup globals: a done-flag, then its direct imports' init functions,
  then its stores in order. `main` calls its module's on entry. The `runtime` package always defines
  `nomu_runtime_init` instead, called first in C's `main`; a `test.runtime_prelude` module leaves the
  runtime's globals (shared weak-ODR storage) to it. The init functions are `noinline`, so no function holds
  both a global's store and its invariant loads. Found on the way: a witness thunk built lazily while a
  shaped-root bundle was pending took the caller's bundle (`beginThunk` now sets it aside). Tests:
  `StartupOrderTests` (six), `Mangle` init and initializer symbols, and suite cases `globals-startup` (debug
  and release: order through a direct, an interface and a closure call), `globals-startup-modules` (a
  diamond; the shared module initializes once), `global-init-cycle` and `global-init-self-cycle`. No runtime
  global is a startup global yet, so `nomu_runtime_init` is empty until 223.1 adds one.
- **224.4** Globals holding managed references (open question 1, option A or B), when user code needs them.
- Tests with each: parser and sema unit tests; suite fixtures for folded constants, startup values ordered
  through function calls, order across modules, and each compile error.

[223](223-retire-the-c-floor.md).1 needs 224.1–224.3: the runtime's globals hold only numbers and `RawPtr`.

## Refs

`../../language/modules.md` (Initialization & entry point; Visibility), `../../internals/inference.md`,
`../../internals/c-types.md` §3, `../../internals/runtime-subset.md` §5. `Parser.parseTopDecl`,
`NOIRGen` identifier resolution, `NOIRDecl` (`src/frontend/noir/sources/NOIR.swift`). [222](222-public-compile-time-constants.md),
[223](223-retire-the-c-floor.md), [127](127-lxr-collector.md), [158](158-gc-packaging.md).

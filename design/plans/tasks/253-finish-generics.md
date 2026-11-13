# Finish generics

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · ready-to-build` · **Size:** XL ·
**Status:** open; 253.1 in progress, in [251](251-erased-generic-objects.md) · **Source:** a probe of bounded generics
found the open work spread across 171, 170, 118, 232 and 251, with no task owning the whole

## What

One home for everything generics still lack. Parts may break out into tasks of their own when they are built.

**Done means:** any valid generic program compiles and behaves the same specialized and compiled once, debug and
release, in one module or across several, and compiled-once code has its own benchmarks. Both modes are first-class.

## Why

The core works, and the suite passes, but each probe outside what the fixtures cover has found a gap. A library needs
all of this to be ordinary: `Channel<T>`, a map with `K: Hashable`, a conformance declared beside its type.

## Steps

- **253.1** Compiled-once objects. Owned by [251](251-erased-generic-objects.md): 251.3 class construction, 251.2.4 thunks,
  closures and fibers. This is what [250](250-fiber-task-surface.md) waits on.
- **253.2** `Array<T>` in compiled-once bodies. Building an array of `T` there crashes at runtime: `arrayBufTypeId` is
  asked for a descriptor of a bare `T`, and the element's size is unknown. It needs the buffer's descriptor from the
  dictionary (`arrayBuffer` in the recipes) and element sizes from the dictionary in every array operation. Until
  then it should be a compile error. `[T]` as a field type does not parse; that is frontend sugar and can wait.
- **253.3** Bounded generics. Compile errors today, across a module boundary unless noted; debug and release unless
  noted.
  - **253.3.1** A bound on a generic class, `class Cell<T: Num>`, dispatching on a field: LLVM verification fails
    ([171](171-modules-cleanup.md) 171.1).
  - **253.3.2** A type conforming in its own library, used by a consumer: "does not conform". It needs conformances
    across the `.nmi` and witness tables the producer exports (171.2.3).
  - **253.3.3** A generic type as a conformer, `struct G<T>: Num`: "does not conform", within one module's declaration.
  - **253.3.4** Two bounds on a forwarded parameter failed LLVM verification in release. **Done.** The bounds were
    fine: a body specialized from a `.bir` has no source position, and a call needs a debug location. Calls there now
    get line 0. Test: `module-generic-two-bounds`.
  - **253.3.5** Actor conformers, rejected on purpose (171.2.1).
  - **253.3.6** Requirements returning `Self`, rejected on purpose (171.2.2).
  - **253.3.7** A computed property satisfying a requirement on an imported type (171.5.2).
  - **253.3.8** A `String` property read through a bound: `examples/generics` fails LLVM verification
    ([232](232-generic-string-property-concat.md)).
- **253.4** What specialized code can reach. In release a consumer specializes a dependency's generic from the `.bir`.
  - **253.4.1** A body reaching a private non-generic class fails with "cannot construct": the `.bir` ships private
    callees but not private types. A private type a recipe names now arrives through its layout, without methods.
  - **253.4.2** A body calling a generic in a module the consumer does not import fails with "unknown call target":
    with `main` importing `mid` and `mid` importing `base`, `mid`'s shipped body calls `base`'s generic, and only visible
    dependencies' templates load. `module_generic_composed_args` is the test, once this works `--config=mono_all`.
  - **253.4.3** Methods on generic types do not ship in the `.bir` (only generic functions do, `BodyExport.swift`), so
    a consumer never specializes them, even with `--config=mono_all`. The prelude's `Channel<T>` is therefore always
    called compiled once from user code. Then: a fixed-size copy for a specialized `T` by inlining the channel core's
    fast path ([102](102-channels.md) 102.5).
- **253.5** GC corners. A composite that flows through a phi past its construction iteration is registered only in
  that iteration (171.3.1). An enum payload holding a managed enum is rejected (176.3b). `NOMU_SCHED` configurations
  without a shadow walk have no typed roots (171.3.3); check whether that configuration still exists.
- **253.6** Diagnostics. A mutating call on a `let` receiver of an imported generic is not rejected (171.5.1). Anything
  unsupported should be a compile error, never a crash at runtime.
- **253.7** Compiled-once performance, a goal of its own. Sizes are dictionary words read at entry (251.2.2). Remaining:
  precomputed field offsets and enum layouts in the dictionary; reusing buffers, since a copy in a loop allocates stack
  on every iteration, and hoisting its stack check; skipping the barrier by the witness's POD flag; a compiled-once benchmark set, bounded generics included.
- **253.8** Test every mode. Run the generic fixtures debug, compiled once and optimized, and specialized, with moving
  collections, as a suite dimension. Most gaps here passed unnoticed because a fixture ran in one mode.
- **253.9** Trim erased output: emit a generic type's erased methods only when public (171.6).
- **253.10** Language features, needing design and agreement before they are built: a method's own type parameters
  ([170](170-method-level-generics.md)), associated types and where-clauses ([118](118-associated-types.md)), operators
  as interface requirements (`generics.md` §10: generic code cannot yet compare or hash a `T`), static type-argument
  inference ([151](151-generic-type-methods.md)), and mutating calls on a class's struct field, rejected today
  ([249](249-barrier-through-mutating-self.md)).

## Dependencies & triggers

- **Needs:** 253.1 before 253.2 and 253.7; 253.3.2 before a library can ship conformances.
- **Feeds:** [124](124-generic-hashmap.md), [120](120-stdlib-core.md), the benchmark
  against Go and Swift.

## Refs

`generics.md`; `backend.md` §4; [251](251-erased-generic-objects.md); [171](171-modules-cleanup.md).

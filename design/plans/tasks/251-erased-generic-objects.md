# Generic classes and enums in compiled-once bodies

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · ready-to-build` · **Size:** L ·
**Status:** 251.1, 251.4, 251.5, 251.6, 251.9, 251.10 and 251.11 done; 251.2 next · **Source:** found building [250](250-fiber-task-surface.md) 250.2

## What

A public generic is compiled once, with `T` unknown, and values of `T` travel by buffer with a value witness
table. That body can move a `T` and construct a generic struct or enum, but it cannot construct a generic
class, because a heap object needs a type descriptor that depends on `T`. Finish this, so a public generic class
such as `Channel<T>` works.

## Why

`Channel<T>` and `Task<T>` are stdlib generic classes (`concurrency.md` §8), and any library collection
needs the same thing.

## Steps

- **251.1** Size the work. **Done.** Probes across a module boundary show generic classes are closer than they
  looked. Fixed: a concrete field in a generic class's compiled-once body read as its address and failed LLVM
  verification (`module-generic-class-fields`). Working already: `T` fields, and constructing, storing, reading
  and matching `Option<T>`; the "enums pending" text in the lowering error is out of date. The remaining gaps
  are the steps below.
- **251.2** Dictionaries: a compiled-once body takes a hidden dictionary, beside the value and protocol witness
  parameters it takes today. It holds the type descriptors the body needs and sub-dictionaries for the generics
  it calls. Whoever knows the concrete type emits `Node<Int>`'s descriptor as a weak static, as every descriptor
  is today, and builds the dictionary. Reaching it through `any` and witness calls is the intricate part.
- **251.3** Construct generic classes in compiled-once bodies, reading the descriptor from the dictionary.
- **251.4** The generational barrier for a non-POD write into a heap object ([171](171-modules-cleanup.md)
  171.4). **Done.** The sized copy of `T` logged nothing, so a minor collection lost young values: 1,999 of 2,000
  checks failed in `module-generic-old-write`. The copy now runs, then the barrier's object-remembering half logs
  the object. POD `T`s take the same call; skipping it by the witness's POD flag belongs to 251.8.
- **251.5** Calls and writes in compiled-once bodies. **Done.** A generic class is a reference there, one managed
  pointer like `self`, rather than a buffer: `Option<Node<T>>` has a size, and a class field stores and returns
  directly. Fields read and write on any generic value (`module-generic-class-nodes`). A binding or assignment of a
  buffer-held value owns a copy: `let old = seed; seed = v` used to change `old`, because a read yields the
  field's address. The copy is a typed root, and an enum's roots follow its active case, which closes 171.3.2.
  Compiled-once code calls compiled-once code and forwards its own witnesses (171.7.2,
  `module-generic-erased-calls`). A private generic gets an erased body when an erased body calls it (171.7.1). A
  composed type argument mentioning `T`, such as `f<Option<T>>`, is an error until dictionaries (251.2).
- **251.6** Inference at construction. **Done.** `Q<String>(...)` resolves imported names as `Q(...)` does. An
  annotated type seeds inference. A field argument sees what is already inferred, and a leading-dot enum argument
  waits for the other fields, so `Q(slot: .none, seed: "s")` binds `T` from `seed`
  (`module-generic-construct-infer`).
- **251.7** Array fields of `T`. `[T]` does not parse as a field type.
- **251.8** Precomputed sizes and offsets in the dictionary, with benchmarks of compiled-once against
  specialized code. Reuse buffers: a copy in a loop allocates stack on every iteration.
- **251.9** Stack checks for buffers sized at runtime. **Done.** A compiled-once body's `T` is a runtime `alloca`,
  which neither the entry check nor the frame table covers. With a `T` of 4,000 words read from a heap object, a
  caller's small frame left no room and the fiber ran off its stack; `nomuSchedStackCheck` also returns quietly once
  the SP is outside the stack, so a later check did not catch it. Each such buffer now compares the SP less its size
  with the stack limit, and asks `__nomu_stack_slow` for that size when short (`runtimeSizedBuffer`). The slow path
  moves the stack and never collects, and these addresses were already tracked. Test: `erased_large` in the stack-move
  matrix, about 4,000 words of nested structs with an array; with only this check off, 12 of its 36 legs fail. It
  costs a load and a compare per buffer, which 251.8's buffer reuse can hoist out of loops.
- **251.10** The write barrier for a store into a struct inside a class. **Done.** `b.v.s = x` had none: the assignment
  took a struct field store for a stack write, though `structAddr` can reach through a class pointer. An old object
  then lost a young array at a minor collection, in debug and release, with no generics involved. `structAddr` now
  reports the heap object it passed through (`addrOwner`), and the store takes that object's barrier, for concrete
  and residual generic bases. Test: `nested_field_store`, which fails 6 of 18 legs without it. A mutating call on a
  class's struct field, [249](249-barrier-through-mutating-self.md)'s case, is rejected by the compiler today.
- **251.11** Roots of ready fibers. **Done.** `nomuSchedWalkRoots` walked parked and stopped fibers and skipped ready
  ones, so a fiber woken from a sleep and waiting for a carrier had its whole stack ignored. A major collection then
  moved or freed what only that fiber held. Any program with fibers could reach this. Ready fibers are now walked; one
  that never ran has no anchor. Test: `ready_fiber`, which fails 6 of 18 legs without it.

## Design

Go's approach, with static descriptors passed in dictionaries, over Swift's descriptors built at runtime.
Polymorphic recursion is rejected, so a program's instantiations are finite and known at build time. The
collector and the runtime do not change, and a compiled-once allocation costs one load.

Compiled-once code and specialized code are both first-class: a program may run mostly either way, so
compiled-once performance is a goal of its own. A field offset or a size that depends on `T` is computed today
from witness sizes at each access. A dictionary is per instantiation, so it also holds these precomputed,
making each one a load. Enum layout gets the same treatment.

Swift's runtime metadata exists so a library binary can be replaced without recompiling its users. Nomu
distributes source only, like Rust, with no shared-object path, so that has no value here. A consumer depends
only on the producer's `.nmi` and `.bir`. A generic's body is in the `.bir`, so a dictionary that depends on the
body adds no recompilation that changing the body does not already cause.

## Dependencies & triggers

- **Feeds:** [250](250-fiber-task-surface.md) 250.2 and later.
- **Interacts with:** [171](171-modules-cleanup.md) (cross-module generics residuals), `generics.md` §6,
  `backend.md` §4 (value witnesses).

## Open

Classes have no `init` and no field defaults, so a class with internal fields has no constructor that hides
them. A static factory, `Channel<Int>.make(capacity: 8)`, needs no new syntax and works once 251.3 lets its
body construct the class. `init` is a separate language design, and needs agreement.

## Refs

`FunctionLowerer.swift` `lowerConstruct`; `generics.md` §6; `concurrency.md` §4, §8.

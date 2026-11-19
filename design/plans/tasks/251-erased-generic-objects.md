# Generic classes and enums in compiled-once bodies

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · ready-to-build` · **Size:** L ·
**Status:** done · **Source:** found building [250](250-fiber-task-surface.md) 250.2

Part of [253](253-finish-generics.md), which owns everything else generics lack. This task covers what `Channel<T>`
needs. Its former steps 251.7, 251.8, 251.13 and 251.14 are now 253.2, 253.7, 253.4 and 253.3.

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
- **251.2** Dictionaries: a compiled-once body gets a static table for its instantiation, holding the witnesses and
  descriptors it needs and sub-dictionaries for the generics it calls. Whoever knows the concrete types emits it as a
  weak constant, as descriptors are today, and an inner body takes its sub-dictionaries from its own.
  - **251.2.1** Compute each generic's needs from its body. **Done.** The producer scans each compiled-once body and
    writes a recipe into the `.nmi`, in its own type parameters: `object`, `arrayBuffer`, `box` and `callee` needs,
    with the layouts they reach, so a recipe can name private types and private callees
    (`DictionaryRecipes.swift`, `ModuleInterface.dictionaries`). Over shipping bodies in the `.bir`, this runs the scan
    once, and an edit that changes no needs rebuilds nothing downstream. Nothing reads the recipes yet.
    A callee in a third module is not expanded yet: 251.2.3 must copy its recipe in. A closure's environment
    is not a need yet: 251.2.4.
  - **251.2.2** Pass the dictionary. **Done.** One pointer replaced the witness parameters; the body reads its words
    at entry. A caller with concrete types passes a shared constant, a compiled-once caller its own when the words
    match, else one built in its frame (the pointer is tracked, since a wrapper's check can move the stack before
    the body reads it). Those loads are not invariant yet: an inlined callee could otherwise read a stack dictionary
    before the store. 251.2.3 removes stack dictionaries and can mark them.

    Measured in optimized compiled-once code, against witness parameters, best of 7, 40M calls. A witness-only
    dictionary cost `method` +20 to 32% from one extra load on an address chain, so each type parameter's size is a
    dictionary word too, read once at entry:

    | Case | Change |
    |---:|---|
    | `pick` (Int) | +0.1% |
    | `pick` (struct) | -1.6% |
    | forwarding `T` | -0.6% |
    | a stack dictionary | -0.5% |
    | a method, field reads | -0.6%, and -0.7 to -4.8% at five of six code placements |

    The bounded case was not measured. One pointer is at least even in everything measured and leaves
    argument registers free, so it stays.
  - **251.2.3** Sub-dictionaries. **Done.** Every compiled-once generic now has a recipe, with its bounds, and a
    recipe a module reaches from a dependency is copied into its `.nmi`, so a caller only reads what it imports. At a
    concrete call the monomorphizer expands the recipe into dictionary instances (`requestDictionary`), and types
    go through `resolveType`, so a composed or private type is specialized like any other; a recipe's layouts become
    templates. The backend emits the instances as constants, which may reach themselves for recursion. A compiled-once
    body takes every generic callee's dictionary from its own, so stack dictionaries and their tracked pointer are
    gone, and dictionary loads are invariant. The "needs a dictionary" error is gone. Test:
    `module-generic-composed-args`, through three modules: a composed argument, swapped and renamed parameters, a
    concrete argument, a private generic type, a private recursive generic.

    A generic function is no longer inlined by SSAIR's inliner, as `generics.md` now records as a decision. This also
    closed a latent bug: the inliner did not rename type parameters, so an inlined body worked only when the names
    matched. Forwarding stayed even with witness parameters, at +0.2%.
  - **251.2.4** Closures and fibers. **Done.** Before this, a closure capturing a `T`, a closure returned over one,
    and `fiber f(x)` or `task f(x)` with `x: T` failed to compile with "no size for type parameter 'T'" (250.3.3), and
    calling a concrete closure passed in as `(T) -> T` crashed in debug: the caller passed a buffer where the body
    expected the closure, and the body called it with a buffer where the closure expected a value.

    Decided over Swift-style reabstraction at each boundary, and over one by-address convention for every closure: a
    function value always has its concrete type's calling convention, the one specialized code uses, and only
    compiled-once code pays. The recipe gains a `callValue` need per function type a body calls, whose word is a call
    adapter taking every argument and the result by address, and a `closureEntry` need per closure it makes, whose
    word is an entry adapter with the concrete convention. Reabstraction would also allocate a thunk at each crossing
    and convert function values held in containers; with adapters nothing converts.

    The environment of a closure or fiber in a compiled-once body is a class generic over the body's type
    parameters, with captures inline: one allocation, over boxing each captured `T`. Its first field is the
    dictionary, its second a closure body's code address; its descriptor is an `object` need. These needs come from
    closure conversion, so the driver appends them to the recipes after SSAIR generation, after the scan's, and the
    `.nmi` carries the environment's layout. The lifted body reads the dictionary from its environment, takes its
    result and arguments by address, and lowers as compiled-once code. ABI: `backend.md` §4, function values.

    Also fixed on the way: a function value whose type mentions `T` is now passed directly, as a generic class
    reference is, where the consumer had passed it by buffer and the producer expected the closure; and an erased
    call of a prelude generic type's method (`Task.join`) named the function symbol instead of the method's. And a
    call through a loaded code pointer read function attributes from the load when shaped roots were live across it
    (`isGCLeafFn`), which crashed the compiler now and then; it only happened on cold builds, where the stack-move
    matrix compiled this fixture's configurations back to back.

    Test: `erased_closures` in the stack-move matrix, through the call adapter, the entry adapter, both in turn, a
    closure returning a closure, a closure in a generic class's method, a bounded `T` captured, a generic call inside a
    lifted body, `Void` closures both ways, `task` and `fiber`, over heap strings and objects, on all 48 legs.
    It failed to compile before this; with the call adapter's frame addresses left unmarked, the stack-move-check
    legs crash. Witness thunks for a generic type as a conformer belong to 253.3.3.
- **251.3** Construct generic classes in compiled-once bodies. **Done.** `Node(...)` with `Node` generic allocates the
  header plus the fields' sizes from the dictionary, writes the descriptor word the dictionary holds for that
  instantiation into the header, and stores each field at its derived offset (`lowerErasedAlloc`). A recipe records
  every generic class it constructs, concrete arguments included, so the body never names a descriptor itself; a
  caller fills the word with its instantiation's descriptor. The SSAIR verifier now accepts an allocation of a
  `.generic` type, and stack promotion leaves one alone. Test: `erased_queue` in the stack-move matrix, a queue in
  the shape of a channel, whose methods and a free function allocate both classes, with arrays in `T`, on all 36
  legs; it fails to compile before this. A static factory, `Chan<Int>.make(capacity: 8)`, works in all three modes.
- **251.4** The generational barrier for a non-POD write into a heap object ([171](171-modules-cleanup.md)
  171.4). **Done.** The sized copy of `T` logged nothing, so a minor collection lost young values: 1,999 of 2,000
  checks failed in `module-generic-old-write`. The copy now runs, then the barrier's object-remembering half logs
  the object. POD `T`s take the same call; skipping it by the witness's POD flag belongs to 253.7.
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
- **251.9** Stack checks for buffers sized at runtime. **Done.** A compiled-once body's `T` is a runtime `alloca`,
  which neither the entry check nor the frame table covers. With a `T` of 4,000 words read from a heap object, a
  caller's small frame left no room and the fiber ran off its stack; `nomuSchedStackCheck` also returns quietly once
  the SP is outside the stack, so a later check did not catch it. Each such buffer now compares the SP less its size
  with the stack limit, and asks `__nomu_stack_slow` for that size when short (`runtimeSizedBuffer`). The slow path
  moves the stack and never collects, and these addresses were already tracked. Test: `erased_large` in the stack-move
  matrix, about 4,000 words of nested structs with an array; with only this check off, 12 of its 36 legs fail. It
  costs a load and a compare per buffer, which 253.7's buffer reuse can hoist out of loops.
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
- **251.12** A `T` field passed straight to a call. **Done.** `helper(value)` in a compiled-once body passed the heap
  address where a buffer pointer belongs, which failed LLVM verification. An address into an object also would not
  survive a moving collection, so a call now passes a copy (`lowerArg`). Test: `erased_field_arg`.

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

A public class's fields are all visible, and a field's type may be no less visible than the class, so a `Channel<T>`
cannot keep its node type private. Field visibility is a language change and needs agreement.


Classes have no `init` and no field defaults, so a class with internal fields has no constructor that hides
them. A static factory, `Channel<Int>.make(capacity: 8)`, needs no new syntax and works once 251.3 lets its
body construct the class. `init` is a separate language design, and needs agreement.

## Refs

`FunctionLowerer.swift` `lowerConstruct`; `generics.md` §6; `concurrency.md` §4, §8.

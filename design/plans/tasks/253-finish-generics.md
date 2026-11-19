# Finish generics

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · ready-to-build` · **Size:** XL ·
**Status:** done; 253.7 and 253.10 moved to [268](268-compiled-once-performance.md) and
[269](269-generic-language-features.md) · **Source:** a probe of bounded generics
found the open work spread across 171, 170, 118, 232 and 251, with no task owning the whole

## What

One home for everything generics still lack. Parts may break out into tasks of their own when they are built.

**Done means:** any valid generic program compiles and behaves the same specialized and compiled once, debug and
release, in one module or across several, and compiled-once code has its own benchmarks. Both modes are first-class.
The benchmarks moved with compiled-once performance to [268](268-compiled-once-performance.md).

## Why

The core works, and the suite passes, but each probe outside what the fixtures cover has found a gap. A library needs
all of this to be ordinary: `Channel<T>`, a map with `K: Hashable`, a conformance declared beside its type.

## Steps

- **253.1** Compiled-once objects. **Done**, in [251](251-erased-generic-objects.md): 251.3 class construction, 251.2.4
  closures, fibers and tasks. This is what [250](250-fiber-task-surface.md) waited on. Also fixed: `Void` in an
  imported signature, `(Int) -> Void` included, named the prelude's `Void` struct, so the argument did not match;
  a name `resolve` maps to a builtin is no longer a foreign type (`builtinTypeNames`).
- **253.2** `Array<T>` in compiled-once bodies. **Done.** Two faults. Reading was silently wrong: the caller passed an
  `Array<T>` by buffer, a pointer to a stack copy of the handle, while the compiled-once body took the handle, so
  `xs.count` read the stack. An array is now a reference in the erased ABI, as a generic class and a function value
  are. Building crashed: the element buffer's descriptor and the element stride were asked of a bare `T`. Literals,
  `append`, element reads and writes now take the stride from the dictionary's sizes and the buffer's descriptor from
  its `arrayBuffer` word, which the dictionary now fills; element writes copy and remember the buffer. The scan missed
  `append` without a literal, since `append` reaches it as a call of `__arrayAppend`. An array or function value held
  inside a struct buffer is now registered as a typed root. Test: `stack_move_matrix/erased_arrays` (literals, `append`,
  writes, arrays of `String`, of a generic struct, a generic class, a generic enum and of arrays, a bounded element,
  arrays passed between compiled-once bodies, held in a generic struct and captured by a closure), and a unit test
  for the `append` need. `[T]` as a field type does not parse; that is frontend sugar and can wait.
- **253.3** Bounded generics. **Done.** Test:
  `stack_move_matrix/erased_bounds` (every 253.3 case, conformers from the library and from the consumer, called
  compiled once and specialized and boxed as `any`, across the collector matrix and with `mono_all` and `mono_none`),
  `stack_move_matrix/erased_self` (253.3.6 the same way), `stack_move_matrix/erased_actor` (253.3.5, also on several
  carriers), `stack_move_matrix/erased_defaults` (253.3.9), `stack_move_matrix/erased_boxes` (253.3.10), and `generic-conformer-default`, `generic-conformer-wrong-signature`, `generic-array-field-infer`,
  `actor-conformer-*`.
  - **253.3.1** A bound on a generic class, `class Cell<T: Num>`, dispatching on a field. **Done.** The receiver was
    the field's address inside the object, where the witness slot takes a frame buffer. A requirement takes `self` and
    its arguments read-only, so a `T` read from an object is passed as a copy, registered as a typed root
    ([171](171-modules-cleanup.md) 171.1).
  - **253.3.2** A type conforming in its own library, used by a consumer. **Done.** The `.nmi` carried conformances,
    but reading it back dropped them, and Sema checked only the module's own types. An imported type's conformances
    are now recorded as an own type's are, and its witness tables are built in the consumer: each thunk declares
    the producer's method from the requirement it satisfies, whose signature conformance checking matched, and a
    stored field read through a requirement is a field read, since the producer has no accessor for it. An
    imported generic conformer (`Pair<Coin>`) calls the producer's compiled-once methods, and Monomorphize now
    requests the dictionary of every compiled-once method of an imported generic type it instantiates, since a bound
    reaches them with no call naming them (171.2.3). Also: an imported interface's requirement types were never
    qualified, so a requirement returning `String` failed to resolve.
  - **253.3.3** A generic type as a conformer, `struct G<T>: Num`. **Done.** Sema skipped generic types' conformances
    entirely. They are checked on the template, with the type parameters in scope; an application of the type
    satisfies a bound and boxes as `any I`, and its witness table is built per instantiation from the specialized
    methods. A generic type must implement each requirement itself: a default is synthesized as a concrete method
    (253.3.9). Also fixed: construction inferring `T` through an array literal for an `Array<T>` field passed
    `<error>` as the expected element type.
  - **253.3.4** Two bounds on a forwarded parameter failed LLVM verification in release. **Done.** The bounds were
    fine: a body specialized from a `.bir` has no source position, and a call needs a debug location. Calls there now
    get line 0. Test: `module-generic-two-bounds`.
  - **253.3.5** Actor conformers (171.2.1). **Done.** An actor conforms through its handlers: each requirement is a
    method with no result, satisfied by the handler of the same name and parameter types, and a call through a bound
    or `any I` sends the message (`interfaces.md` §2, with the alternatives weighed in §9). The requirement's
    parameters must be shareable; a property, a result, a static requirement and an inherited default are errors. The
    thunks send in both tables. Also fixed:
    - devirtualizing a call through a boxed actor called the handler directly, on the caller's fiber, ahead of
      messages already queued; it is now a send;
    - a program with an actor and any indirect call, a closure call included, failed the link's stack check
      ("unchecked recursion: nomu_actor_drain -> nomu_actor_drain"), since an indirect call counted the drain as a
      target; the drain is now an entry, called only from a mailbox fiber.
    A struct holding an actor crashed the compiler in debug (an LLVM statepoint assertion on an aggregate) three
    times while this was built, then stopped reproducing, with every module compiled fresh; the cause was not found.
    `erased_actor` keeps such a struct. An actor declared in another module cannot be used yet (171.9), so actor
    conformers are the consumer's own, called from its code and from a library's compiled-once generics.
  - **253.3.6** Requirements that mention `Self`, called through a bound in compiled-once code (171.2.2). **Done.**
    Compiled once, the library failed to build: the witness tables for compiled-once code were laid out from the
    `any I` surface, where `Self` is `any I`, and an interface with `Self` in a parameter or a static requirement had
    none. Every interface now has one, with `Self` passed as a type parameter would be: a value buffer, a result in a
    result buffer, `Self` inside a value type (`Option<Self>`) by buffer and inside an array, a function type or a
    generic class as that reference. Static requirements (`T.zero()`) dispatch through the bound's table with no
    receiver. Also fixed:
    - witness slots were in declaration order in the declaring module and in name order in one reading the `.nmi`,
      so a cross-module requirement call could reach the wrong method; slots are now ordered by name everywhere;
    - a static requirement on a generic conformer named a function that did not exist (`Loc<Int>.zero`), specialized
      too; it is now the specialization of the type's static function;
    - an imported generic conformer boxed as `any I` with a requirement returning `Self` called a specialized method
      the producer never emits; it now calls the compiled-once method and boxes its result.
  - **253.3.7** A computed property satisfying a requirement on an imported type (171.5.2). **Done** with 253.3.2.
  - **253.3.8** A `String` property read through a bound: `examples/generics` failed LLVM verification
    ([232](232-generic-string-property-concat.md)). **Done.** The conformer has one field, a `String`, so it lowers
    to the string itself, and the stored-field getter took the string's first word as the field. It now returns the
    value, as `extractField` does for a single-field wrapper.
  - **253.3.9** A generic type inheriting an interface default. **Done.** The default is synthesized on the template,
    with `self` the template applied to its own parameters, and specialized with the type's other methods; a call
    on an applied generic type finds it. Also fixed, older: a type conforming to an interface from another module
    and inheriting one of its defaults trapped when the default ran. The `.nmi` carries only that a default exists, so
    the consumer synthesized an empty method; a concrete imported conformer escaped only when the link kept the
    producer's copy of the same weak symbol. An exported interface's defaults are now compiled once in its module,
    as generic functions over the conformer, and a consumer's conformer calls those; an imported conformer's
    default is its producer's method, a generic one's compiled once on the template. An imported interface now
    records its module (`InterfaceDecl.origin`). The `any` thunk calling an imported generic conformer's method
    checks its stack, since its buffers made it too large to run unchecked.
  - **253.3.10** A generic conformer boxed as a composition, `any A & B`. **Done.** Specialized, Sema only had to
    allow it: the composition's table is built per instantiation where the box is made. Compiled once, a box of a
    value whose type mentions a type parameter failed to build ("cannot box non-nominal value") for a single interface
    as well. The recipe's `box` need now names the interfaces, and its dictionary word is the instantiation's table;
    the value is copied into a payload object sized from the dictionary and stamped with the descriptor that every
    `any` table of a value type now carries in its `type_witness` slot. Also fixed:
    - a `.bir` body named an interface by its origin while a consumer knows an imported interface by its bare name,
      so a body boxing as `any I` failed to specialize; interface names stay bare in the `.bir`;
    - a buffer built in compiled-once code registered only its `T`-components as roots, so a concrete managed field
      (a `String` beside a `T`) went stale when a collection ran before it was read. Its concrete components are now
      registered too, and a generic struct whose only managed field is concrete turns registration on.
- **253.4** What specialized code can reach. In release a consumer specializes a dependency's generic from the `.bir`.
  **Done.**
  - **253.4.1** A body reaching a private type. **Done.** The `.bir` shipped private callees but not private types, so
    a body constructing or reading a private class failed ("cannot construct", or "field access on a non-aggregate").
    A private struct, class or enum a shipped body reaches now ships whole, its methods included, and closes like a
    callee: a reference counts the types a body's signatures, fields, cases and expressions name. The consumer
    injects it under its origin key, as it does a private callee. Tests: `module-generic-reach`,
    `module-generic-composed-args` (a private generic struct).
  - **253.4.2** A body calling into a module the consumer does not import. **Done.** With `main` importing `mid` and
    `mid` importing `base`, `mid`'s shipped body called `base`'s generic and failed with "unknown call target": only
    visible dependencies loaded. Specializing, a module now follows the origin keys in the templates it reads to the
    modules they reach, and loads those as it loads a visible one: the surface origin-keyed and out of scope for its
    source, exported declarations admitted whatever the package, and the templates, recipes, results and mutating
    methods. Tests: `module-generic-reach` (a generic, a non-generic function, a type with a mutating method, a
    private class, debug, edge, all and release) and `module-generic-composed-args` specialized and in release.
  - **253.4.3** Methods on generic types. **Done.** Only generic functions shipped, so a consumer called an imported
    generic type's methods compiled once even specialized. An exported generic type now ships whole, with its methods
    and its static functions (`Box.make`), and the consumer replaces the layout-only decl Sema lowered from the `.nmi`
    with it, so `Monomorphize` specializes the methods it calls. The erased methods stay the producer's: an imported
    type's template is emitted without them, and the consumer's own compiled-once bodies still call them. Under `edge`
    an exported type the consumer names directly is selected with its static functions. The prelude's
    `Channel<T>` is specialized from user code in release now. Also fixed: devirtualizing a call on a local `any I`
    box called the conformer's method directly even when the requirement mentions `Self`, where the call takes or
    returns the existential and the method the concrete type; it failed LLVM verification once the method existed
    locally (`erased_self` in release). The call stays a witness call unless the signatures match. Test:
    `specialized_type_methods` (matrix).
  - **253.4.4** A fixed-size copy for a specialized `T` in channel operations, moved from [102](102-channels.md) 102.5.
    **Done.** The specialized `send` and `receive` passed a constant VWT, but still reached `rtChanSend` through the
    scheduler forwarder, which reads the size from the VWT and copies with `copyBytes`. A send or receive whose
    value type is concrete now takes the common case inline: it takes the channel's lock with one CAS, and a send
    to an open channel with no receiver waiting and room in the buffer stores the value at its constant size, with
    the remember barrier only for a value holding references; a receive with a value buffered and no sender parked
    takes it, zeroing a slot that holds references. It then unlocks. Every other case calls `rtChanSend` or
    `rtChanReceive` with a `held` flag saying whether the lock is held already, from one call site. A handoff to a
    waiting peer stays in the runtime, where the wake costs most. The ring index wraps with a compare in place of
    `%`, which divided. The function holding the operation, the channel's thin `send` or `receive`, is always
    inlined: left as a call, its frame and stack check made the unbuffered ping-pong 12% slower than before.
    Release, ns per value or hop, best of 11, before → after:

    | | 1 carrier | 2 | 4 | 8 |
    |---|---:|---:|---:|---:|
    | `stream_channel` | 10.5 → 6.6 | 11.1 → 6.9 | 12.1 → 7.6 | 17.4 → 10.6 |
    | `fanin_channel` | 10.5 → 6.4 | 173.1 → 118.8 | 42.3 → 25.3 | 61.6 → 44.8 |
    | `pingpong_channel` | 45.0 → 39.5 | 46.1 → 40.1 | 49.3 → 43.3 | 69.0 → 59.7 |

    The default build calls the prelude's compiled-once methods and is unchanged. Tests:
    `channel-send-closed-release`, `channel-send-closed-parked-release`, the release legs of the `channel_values`
    matrix fixture, and `channel_local`, whose own channel type takes the inline path in every build.
- **253.5** GC corners. **Done.**
  - A composite that flows through a phi past its construction iteration was registered only in that iteration
    (171.3.1). **No fault today:** SSAIR keeps every buffer-held local in an entry-block slot, registered for the
    whole frame, and an assignment copies into it, so no phi carries a buffer; a back edge clears only the
    iteration's temporaries, and an outer back edge also clears what an inner loop's `break` left. Probed with a
    value reassigned from a construction, a call, a switch payload and a bare `T`, two locals swapped each
    iteration, and an inner loop left by `break`, under stress collections, mixed majors and moved stacks. Kept
    as the matrix fixture `erased_loop_carried`.
  - An enum payload holding a managed enum was rejected (176.3b) when both enums have a tag (`Outer.one(e:
    Inner)`, each with two payload cases); `Option<…>` over extra inhabitants and enums whose case lives in
    spare bits were never affected. The rejection guarded a shared scratch the enumerator once recursed
    through; the runtime's enumerator (`runtime/descriptors.nomu`) keeps no scratch and recurses into a case's
    sub-descriptors, so the rejection is gone and the inner enum is a sub-descriptor. Test: `enum_layout_matrix/
    nested` (locals, array elements, class and struct fields, a closure capture and actor messages, with an
    enum holding a reference in every case beside one holding a `String` in some).
  - `NOMU_SCHED` configurations without a shadow walk (171.3.3). **Gone:** the shadow walk runs for every
    stopped fiber, and the setting no longer exists.
- **253.6** Diagnostics. A mutating call on a `let` receiver of an imported generic is not rejected (171.5.1). Anything
  unsupported should be a compile error, never a crash at runtime. **Done: already rejected.** A `let`, a `let`
  with explicit type arguments, a `Box<String>` and a function parameter are each an error, debug and release, and
  were before 253.4. Test: `module-generic-let-mutating`.
- **253.7** Compiled-once performance. **Moved to [268](268-compiled-once-performance.md).**
- **253.8** Test every mode. Run the generic fixtures debug, compiled once and optimized, and specialized, with moving
  collections, as a suite dimension. Most gaps here passed unnoticed because a fixture ran in one mode. **Done.**
  The `pipeline` dimension gains `release-erased` (optimized, `mono: none`) and `edge` (`mono: edge`), full tier, so
  every matrix group runs debug, release, compiled once and optimized, and edge, across the collector legs; a
  `mono` compile setting selects `mono_<value>`. All 1,462 new legs pass. The harness takes `--compile-setting`
  (as `--run-setting`), and the whole fast tier was swept with it: compiled once and optimized, edge and all, and
  the generic and channel cases again under stress collections. What it found, besides failures by design (the
  `stack-*` cases need recursion `-O2` turns into loops; three `module-generic-*` cases count the erased path's
  roots; the cross-workspace cases see no root configs): `sched-mixed-load` in an optimized build (253.14).
- **253.9** Trim erased output: emit a generic type's erased methods only when public (171.6). **Done.** Public alone
  would drop methods a compiled-once body needs: an exported generic's erased body may use a non-public generic type
  with `T` and call its methods. A type's erased methods are emitted when it is exported, or when an erased body
  emitted here names it with a type parameter in its arguments, found on the worklist that already emits the
  private generic functions erased bodies call. `monomorphize` takes the module's non-public type names from the
  driver (NOIR types carry no visibility). A type used only at concrete types has its specializations alone. Test:
  `erased-type-methods-kept` (debug, and optimized compiled once).
- **253.11** Existentials met while testing 253.3: an array literal does not box its elements, so
  `let xs: Array<any I> = [a, b]` fails with "array element has type"; each element must be bound to an `any I` first.
  **Done.** An array literal whose element type is known coerces each element to it, so an existential or a
  composition boxes them as a `let x: any I` does; an element that does not conform has one error, from the
  boxing. Test: `existential-array-literal` (an annotation, a parameter, a return type, a composition, a nested
  literal and `append`, with structs, classes and a generic conformer; plain, under stress collections, and in
  release) and `existential-array-literal-mismatch`.
- **253.12** Concrete instantiations inside a compiled-once body. `Monomorphize` emits an erased body as written, so
  a concrete `Option<Node>` there stays `.generic`, and codegen holds every `.generic` value by buffer. A value of
  that type from a concrete source is a plain value, so the two disagree. Seen in a library generic compiled once:
  switching on a class field of type `Option<Node>` reads the tag through the field's pointer and crashes on `.none`;
  switching on a call returning `Option<Int>` fails SSAIR verification after inlining (`Option<Int>` ≠
  `Option<Int>`, named against generic). **Done.** An erased body, an exported generic's, a private one it calls,
  and a generic type's template, fields and methods, is now rewritten as a concrete body is, keeping what mentions a
  type parameter: a concrete instance becomes its specialization, held by value, and is specialized here. A call or
  static call whose type arguments mention a type parameter stays erased and requests no dictionary. A concrete
  instance in an exported signature is by value on both sides: the consumer maps it in the imported signature to
  its own specialization (`Type.specializedName`, shared with `Monomorphize`). Test: `erased_concrete` (matrix, and
  `erased-concrete-edge`), with an `Option<Node>` field, `Option<Int>` from a call and a closure, `Option<String>`
  in a signature, and a generic class's method walking its `Option<Node>` field.
- **253.13** An implicit member passed to an imported function's parameter: `pick(i, .some(value: 1))`, where `pick`
  takes an `Option<Int>`, fails with "cannot infer enum type for '.some' here". Binding the argument to a typed `let`
  first works. **Done.** Any generic call, local or imported, checked its arguments with no expected type, which a
  leading-dot argument needs. A generic call now checks each argument against its parameter as far as it is known,
  with the type parameters the other arguments bound and a hole for the rest, and a leading-dot argument whose
  parameter still has holes waits for the other arguments and then the call's expected type, as a generic
  construction's fields do. Test: `generic-implicit-member` (a concrete `Option<Int>`, an `Option<T>` a later
  argument binds, and one the expected type binds; local and imported; debug and release).
- **253.14** `sched-mixed-load` fails in any optimized build, specialized or compiled once: a segfault in a minor
  collection's stack-root scan on 8 carriers, or a hang (`-nursery`). It failed the same before 253.4, so it is
  older than this task's work; its suite cases run debug only. **Moved to [267](267-vector-references-unrooted.md)
  and done:** no generics fault, a vector of two references rooted by its first lane only.
- **253.15** An aggregate holding a managed pointer live across a statepoint. **Done: no fault.** A compiler built
  with LLVM's assertions (the default, non-`opt` bazel build) stops in `RewriteStatepointsForGC` ("support for FCA
  unimplemented") on `sched_mixed_load` and `benchmarks/binary_tree`. The assertion is in the pass's liveness walk
  and fires on any operand whose type is an aggregate holding a managed pointer, live across a statepoint or not,
  so it rejects nearly every Nomu program: a `String` is such an aggregate. Relocation stays sound through
  `nomu-split-reference-aggregates` (`src/llvmpasses`), which gives every use a stop may separate from the
  definition the pointer as its own value; no aggregate use is left across a stop in either program. An
  assertion-enabled compiler cannot check this, so the suite stays on the `opt` build.
- **253.16** A non-public generic type boxed as an existential in an exported generic's compiled-once body failed to
  link in a compiled-once consumer: `let s: any Sized = Boxed(v: x, n: n)` in `package fun sized<T>`, with `Boxed`
  internal. The consumer builds the witness table for `Boxed<String>`, and its thunk calls the producer's erased
  method only when it knows the method's signature, which the `.nmi` gives only for a declared type; for `Boxed` it
  called a specialized `Boxed<String>.size` nothing defined ("stack use is not known"). **Done.** A method's
  dictionary recipe, which the `.nmi` already carries for every compiled-once generic, records the method's
  signature (`RecipeSignature`, `self` first), qualified with the rest of the recipe and optional in the encoding;
  the consumer registers the signature of each imported method recipe its interface does not declare. Test:
  `erased_private_box` (matrix: debug, release, compiled once and optimized, edge, every collector leg).
- **253.10** Language features. **Moved to [269](269-generic-language-features.md).**

## Dependencies & triggers

- **Needs:** 253.1 before 253.2 and 268; 253.3.2 before a library can ship conformances.
- **Feeds:** [124](124-generic-hashmap.md), [120](120-stdlib-core.md), the benchmark
  against Go and Swift.

## Refs

`generics.md`; `backend.md` §4; [251](251-erased-generic-objects.md); [171](171-modules-cleanup.md).

# Enum layout — extra inhabitants, and recursive enums without a keyword

**Avenue:** Risk (perf, footprint) · **Type/Lifecycle:** `compiler · layout · gc` · **Size:** L ·
**Status:** **done** — Swift's layout: extra inhabitants for every type, the value witness table carrying
them for erased code; recursive enums boxed automatically; several payload cases under the moved tag, plus
spare bits where every payload case shares a reference word. 260.9 (a box on the stack) moved to
[148](148-ssair-optimizer-tier.md).1; the collector gaps found to [262](262-collector-gaps.md) ·
**Source:** the binary-trees investigation after [230](230-heap-sizing.md): a node is 40 bytes against Go's
16, and decoding its enum fields is most of the collector's time.

## Today

Every enum lowers to `{ i64 tag, [P x i64] payload }`, P the largest case's slot count (`enumType`,
`llvmgen/LLVMGenLayout.swift`), and every field is a whole 8-byte slot (`ShapeEnv.size`, `midend/ssair/sources/Layout.swift`,
`midend/ssair/sources/Shape.swift`). Nothing depends on the payload's type: `Option<SomeClass>` is two
words, a tag and a pointer, and a payload-free case is a tag over a zeroed payload.

Payload words are `i64`, so a reference in a payload is *conditional content* in the shape model:

- the collector finds it by decoding the enum's case from its type map, per object visited (kind-2 maps,
  `rtShapedCase` in `runtime/descriptors.nomu`);
- a frame value holding one needs a frame home and volatile reloads, since the statepoint rewrite cannot
  relocate an `i64`.

Measured on binary-trees (`TreeNode` holds two `Option<TreeNode>`): a node is 40 bytes (header and two
16-byte enums), Go's is 16. Before the offset list (260.2), looking up the enums' pointer offsets was about
80% of the collector's samples; after it, decoding is still about 70%.

The `{tag, payload}` layout is also assumed by:

- the erased-generics path: an enum's size at run time is 8 + the largest payload, a payload field's offset
  is 8 + the sizes before it (`erasedTypeSize`, `erasedEnumPayloadOffset`, `llvmgen/SSAIRToLLVM.swift`);
- channel receive and `select`: they receive into the payload of a zeroed `Option<T>`, then set its tag;
- the runtime's channel code, which stores what a receive delivers.

**Recursive value types crashed the compiler** (fixed by 260.1). Recursion through a class works
(`TreeNode` above).

**Value types may hold references** (since 260.1). A frontend rule used to forbid a reference field in a
struct or enum, but it read declared field types only, so every generic instance (`Option<TreeNode>`)
bypassed it, and the compiler and collector handled the result correctly; it was removed.

## What

Swift's enum layout, then whatever improves on it.

*Extra inhabitants* (Swift's term) are the bit patterns a type's storage can hold but no valid value uses: a
reference is never 0 or any address in the unmapped zero page, a `Bool` only uses 0 and 1, a three-case
enum's tag only 0 to 2; an `Int` uses every pattern and has none. An enum can store its payload-free cases
in its payload's extra inhabitants and needs no tag: `Option<SomeClass>` is one word, `none` being 0.

- every type reports its **extra inhabitants**;
- an enum with one payload case keeps its other cases in the payload's extra inhabitants, so
  `Option<SomeClass>` is one word with null for `none`, an ordinary relocatable pointer the collector
  traces as a plain field;
- generic code learns a type's extra inhabitants from its value witness table, so specialized and erased
  code agree on every value's layout;
- recursive enums work, with no `indirect` keyword.

## Design questions

- **The layout model — decided: Swift's.** Swift's rules, as a reference:
  - *Extra inhabitants.* A class reference has null and every address below the lowest valid pointer (the
    zero page). `Bool` has its unused byte values. A struct or tuple takes those of one field. An enum
    passes on what its encoding leaves unused. `Int` has none.
  - *No payloads:* a tag only, in the smallest integer that fits.
  - *One payload case:* the other cases take the payload's extra inhabitants; when it has too few, a tag
    is appended (`Optional<Int>` is 9 bytes, stride 16). `Optional<Optional<SomeClass>>` stays 8 bytes:
    the inner `none` is 0, the outer the next spare value.
  - *Several payload cases:* the tag goes in spare bits every payload leaves unused (pointer bits), else in
    appended tag bytes. Generic code uses tag bytes only, since spare bits cannot be derived from metadata.
  - *Generic code:* the value witness table carries an extra-inhabitant count and two witnesses, get the
    tag of a single-payload enum and store it; the runtime lays out a generic enum instance from its type
    arguments' metadata.
- **The slot model — decided: [196](196-dense-value-layout.md) first.** Nomu lays every value out in whole
  8-byte slots (restored on purpose by [176](176-shaped-gc-roots.md).5.2, after `Bool` and `UInt8` storage
  diverged from the collector's maps); 196 measures a dense layout and decides. 196 runs before 260.4, so
  enum layout is built once, on the layout 196 settles. The design here is written in terms of each type's
  extra inhabitants, size and alignment, so it holds under either outcome: under slots, a `Bool` slot or
  an enum tag word has nearly 2^64 spare values and an appended tag costs a slot; under a dense layout the
  counts and costs are Swift's. 196 adopted the dense layout, so the counts and costs here are Swift's;
  sizes and alignments come from 196's layout function, which keeps the enum tag word until 260.4.
- **Which types report extra inhabitants — decided: all of them, in one pass (260.4).** References (class,
  actor, array, closure, existential, and the boxes of 260.6), enum tags, `Bool`, `UInt8` where its storage
  is wider than a byte, `StringBase`'s unused tag values (`Option<String>` without a tag word), and structs,
  which take one field's (Swift takes the field with the most). `Int` and `Double` have none. Each type
  says how many it has and how to write and recognize the k-th.
- **A reference's extra inhabitants — decided: the whole zero page.** Null and every address below the
  lowest valid page, as in Swift, so `Option<Option<SomeClass>>` and an enum with several empty cases over
  a reference stay one word. Every reader of a managed word (the collector's scans, the frame-record walk,
  the statepoint relocation, the heap verifier) treats a value below the bound as "not an object", a
  compare in place of the null test; the write barrier's heap-range check already skips them. The bound
  is per platform (4 GiB on 64-bit darwin, whose zero page is that large; the first page or
  `mmap_min_addr` on Linux).
- **Recursive enums — decided: no `indirect` keyword; boxed automatically.** Swift requires the keyword to
  make the allocation visible, to keep layout stable under library evolution, and to choose which edge to
  box. The first conflicts with Nomu's inferred placement, there is no library-evolution model, and a rule
  can choose the edge. The rule:
  - build the graph of value types (structs, enums) with an edge for each inline field and payload;
    references end an edge;
  - a strongly connected component of that graph is a recursive group; each enum case with a payload field
    whose type is in its enum's group is boxed, its whole payload in one immutable heap box (Swift's
    `indirect case` granularity);
  - a box is a never-null reference, so it has extra inhabitants: `enum Tree { case leaf; case node(left:
    Tree, right: Tree) }` becomes one word per value, null for `leaf`, and a node is one two-word box;
  - enum values are immutable, so a box is shared on copy without copy-on-write;
  - a cycle through structs only, with no enum payload to box, is an error, as in Swift.

  Settled by 260.3:
  - *Groups spanning several enums:* every case with an in-group payload field is boxed. Per case halves
    the allocations and the value size of per-field boxing (`Tree` above would be two words, with two boxes
    a node). Boxing the fewest cases that break every cycle is a feedback-arc-set problem (NP-hard), needs a
    heuristic, and lets an edit to one enum move another's boxes; the rule is deterministic and matches what
    a Swift programmer marks `indirect` for a self-recursive enum.
  - *Recursion through a generic's type parameter* (`struct Node { next: Option<Node> }`) is an error, as
    in Swift. Boxing per instance would give `Option<Node>` and `Option<Int>` different layouts and put a
    per-instance boxed flag in the value witness table.
  - *Module interfaces:* imports are acyclic (`design/language/modules.md`), so every concrete type in a
    recursive group is in one module, and a dependent that sees an enum sees its whole group (it needs every
    member to lay the enum out). Each module therefore derives the boxing from the declarations, its own and
    imported ones alike, and producer and consumer agree with nothing recorded in the interface.
  - *The box* is a compiler-made immutable class: it reuses descriptors, shapes and allocation, escape
    analysis can stack-promote it, and shareability is structural, so a box is shareable when its contents
    are. Swift's box is likewise an ordinary heap object.
- **The value-type rule — decided: removed.** A struct or enum may hold references, as in Swift: copies
  share the referenced objects, and the shareability pass decides what crosses fibers, as it already did
  for generic instances. The extra-inhabitant layout therefore applies to concrete enums as well as
  generic ones.
- **Several payload cases — decided: build two layouts, keep one or both by measurement.**
  - *A moved tag,* for every multi-payload enum: the tag is the smallest integer that fits, placed after
    the payload (an enum of `Bool`s goes from 16 bytes to 2). The shape model reads a word that holds a
    reference in every case as a plain pointer, which ends its decoding, keeps it relocatable by statepoints
    and removes its frame home. An all-reference enum stays two words. Enums with an `Int` or `Double` case,
    and erased code, need this layout in any case.
  - *Spare bits under a fixed mask,* for enums whose payloads are all references: the tag goes in bits no
    reference uses, so the value is one word. The collector strips the same mask from every word of a new
    shape kind, *tagged reference* (fixed per offset like a plain reference, no case lookup), and restores
    it on relocation: one AND and one OR per word. Swift also uses spare bits, but decoding them per type,
    as our collector would through the enum's type map, is the cost 260.2 measured. Start with the low 3
    bits (alignment): a tagged value is a derived pointer, base plus a small offset, which `gc.relocate`
    handles, and the payload-free cases sit below the "not an object" bound. High bits are more numerous,
    and arm64's top-byte-ignore could skip the mask on loads (whether macOS enables it for user data
    pointers is unchecked). It touches every reader of a managed word: the scans, the frame walk, the heap
    verifier, the write barrier's range check.

  A word that holds a reference in one case and an integer in another stays conditional under both.
  Neither is known to win: the moved tag costs a word per value, spare bits cost a mask per word in the
  collector and the engineering above. 260.7 builds both and measures them.
- **The collector.** An enum laid out in a reference's extra inhabitants is `managed` in the shape model, a
  plain pointer field. In an enum that keeps a tag, a word that is a reference in every case is a plain
  pointer too; a word whose kind varies by case stays conditional, at 260.2's decoding cost.

## Dependencies

- Builds on [196](196-dense-value-layout.md)'s layout function (`midend/ssair/sources/Layout.swift`,
  196.6–196.7), which is in place. 260.4, 260.5 and 260.7 are in turn a dependency of 196, which owns dense
  layout for every type; its 196.9 re-measures once they land.

## Work

- **260.1** Recursive value types are an error — done. The Typechecker finds cycles among structs and
  enums before any pass walks field types (`checkRecursiveValueTypes`): an edge for each field or payload
  held inline, through a generic's argument only where the generic holds that parameter inline, so
  `Array<Node>` in `Node` is fine and `Pair<S>` in `S` is a cycle; Tarjan's components, each reported once
  with its path ("value type 'A' contains itself: A.b → B.a → A"). Until 260.6, recursive enums are errors
  too. Cases `recursive-enum`, `recursive-struct-mutual`, `recursive-generic-struct`,
  `recursive-generic-enum`, `value-type-nesting`.
  - *Imported generics.* The check first read only the program's own declarations, so a cycle through an
    imported generic passed it (`struct Node { let next: Option<Node> }`, which has no finite size, went on
    to layout: the `bazel-bin` compiler failed there with an internal size mismatch, and the opt compiler
    built it). It now takes the imported structs and enums (by per-origin identity) for their inline
    parameters, and resolves a bare or qualified type name in its file as Sema does. Cases
    `recursive-imported-generic` (`Option` from `std`), `recursive-qualified-generic` (`box.Box<S>`), and
    `value-type-nesting-imported` (imported generics that hold a type through an array, or nest finitely).
  - *The value-type rule is gone.* `Typechecker.checkPOD`, which rejected a reference field in a struct or
    enum ("use a class") and whose unguarded recursion was the crash, is removed: the rule read declared
    types only, every generic instance bypassed it, and the shape model and collector handled the result.
    Shape-matrix fixture `value_ref_fields` (a class in a struct field, an enum payload and a struct holding
    that enum, as locals, array elements, class fields, parameters and results) passes on all 24
    pipeline × GC legs, the heap verifier's included.
  - *Checked after the removal:* escape analysis treats a value placed in a struct or enum as escaping
    (`makeStruct`, `makeEnum`), so its object stays on the heap; shareability is structural, so a struct
    holding a mutable class is rejected at a `task` as the class is. New suite group `value-refs`
    (`tests/fixtures/value_ref_matrix/*`, every pipeline and GC leg, escape analysis on): `escape`,
    `barrier` (stores into mature objects' struct and enum fields and array elements), `stack_fields`.
  - *A stack-promotion bug the checks found, fixed.* A class instance escape analysis placed on the stack
    had its `String` and enum fields unrooted: `recordedSlots` judged the slot by the class type, whose
    shape is one reference, so it never saw the body's conditional words, and a moving collection left them
    stale (a stack object with a heap `String` field read 3,242 wrong values under stress; reachable before
    the rule's removal too). The slot's content is now the object's body (`ShapeEnv.objectShape`), and
    its frame record uses the class's own descriptor (`shapeOrdinal`). An escaped class slot was also
    recorded before, with a descriptor that read the header word as a pointer; it now gets the object's.
    `stack_fields` fails without the fix (6,314 wrong reads) and passes with it. Full tier 1921 passed.
  - *Found, outside 260:* actor message arguments are not checked for shareability (a mutable class goes
    to a handler unchallenged), though `concurrency.md` names an actor message as a task boundary;
    [261](261-actor-follow-ups.md).1.
- **260.2** The collector decodes each enum field once — built, not committed. `rtOffsetsList`
  (`runtime/descriptors.nomu`) lists a fixed-size object's live offsets in one pass, decoding each enum
  field once, where `rtLiveCount` and `rtLiveOffsetAt` decoded every field again for each index. Used by
  the evacuate-mark, unmark, unmark-and-unlog and minor-scan walks. binary-trees depth 19 1.27 s → 1.13 s,
  depth 21 7.22 s → 6.38 s; the `immix` plan at depth 19 3.12 s → 2.60 s. Full tier 1820 passed.
- **260.3** Settle the open design questions above — done: per-case boxing of every in-group case,
  recursion through a type parameter an error, boxing recorded in the defining module's interface, the box
  a compiler-made class; several payload cases built two ways and chosen by measurement (260.7).
  260.4 and 260.5 split by generic and non-generic enums. The default build (`opt.mono: none`) calls
  imported generics erased, and erased code builds and reads `Option<T>` with the tag-word layout from
  `T`'s size; specialized and erased code must agree on every generic enum instance's layout, so a generic
  enum's layout can change only together with the erased path. A non-generic enum reaches erased code only
  as an opaque `T`, copied by its witness table's size, so its layout can change alone.
- **260.4** Extra inhabitants for every type, and the new layout for **non-generic** enums. Generic enum
  instances (named with `<`, as the egress already tests) keep the tag word until 260.5.
  - **260.4.1** Layout and shapes. Each type reports its extra inhabitants: a count and a place (byte
    offset and the scalar there). References report one, null, until 260.4.3; `Bool` 254; a tag-only enum
    its unused tag values; a tag-word enum the tag word's unused values; a struct its field with the most
    (ties to the first). A non-generic enum is laid out by kind: no payloads, a tag in the smallest integer
    that fits; one payload case, the payload in declared order with the other cases in its extra
    inhabitants (the payload zeroed, then the k-th extra inhabitant written), or, with too few, a tag after
    the payload (a word when the payload is word-aligned, so the tag fills the padding and the collector
    reads it whole; else the smallest integer); several payload cases, the tag word as today. An enum over
    its payload's extra inhabitants takes its payload's shape: the zeroed payload holds no object, and the
    payload's own decoding (a leaf's tag, a nested enum's tag) reads an extra inhabitant as holding none. An
    enum shape records its tag's offset. `ShapeTests`.
    — done: `ExtraInhabitants` (offset, width, shift, first unused value, count; counts capped at
    `Int32.max`), `EnumLayout` (`tagOnly`, `overExtraInhabitants`, `appendedTag`, `tagWord`) and
    `ShapeEnv.enumLayout`/`extraInhabitants` in `Layout.swift`; `String` has 13 (its tag nibble's values 3
    to 15). `ShapeEntryKind.enumCases` carries `tagOffset`. `ShapeTests.testEnumLayouts`,
    `testExtraInhabitants`.
  - **260.4.2** Codegen: the LLVM type per kind, construction, the tag read (decoding an extra inhabitant
    to its case), the payload read, the layout check, the GC maps' tag offset. Suite fixtures over the
    pipeline and GC legs.
    — done: `enumType` per kind; `makeEnum` writes a payload-free case's extra inhabitant into the zeroed
    payload; `enumTag` decodes it (the k-th payload-free case is case k, or k + 1 past the payload case);
    `extractPayload` reads the payload case's fields as the enum's first elements; `checkLayout` checks each
    kind's size, payload offsets and appended tag. The frame reload's word path now ends at a pointer as
    well as an `i64` (an enum's payload reference ahead of an appended tag word is a conditional word), and
    sizes 2- and 4-byte integers by width. Group `enum-layouts` (`tests/fixtures/enum_layout_matrix/kinds`:
    every kind in locals, arrays and class fields, overwritten in mature holders, under churn) passes on all
    24 pipeline × GC legs; with the over-null shape emptied it fails on all 24. Full tier 1957 passed.
  - **260.4.3** References' extra inhabitants to the bound: every address below it is "not an object"
    (4096 on every platform: the first page is unmapped on darwin and Linux, and 4096 values cover any
    enum's empty cases). The collector's scans, the frame walk, the statepoint relocation, the heap verifier
    and the write barrier test the bound where they test null today.
    — done: `rtNotObject` (`runtime/descriptors.nomu`, bound `rtNotObjectBound`, the same as
    `ShapeEnv.referenceExtraInhabitants`) replaces the null test on every managed word the runtime reads: the
    major and minor traces and their root loops (`collect.nomu`, `immix.nomu`), the unmark walks, the frame
    and shadow-stack root walks (`stackwalk.nomu`), the verifiers (`verify.nomu`, `gcverify.nomu`) and the
    leak walk (31 sites). The write barrier remembers the stored-into object and never reads the stored
    value, so it is unchanged. `enum Three { case none; case one(box: Box); case gone }` is one word,
    `gone` the address 1. The `enum-layouts` fixture holds such values in frames, arrays and class fields;
    with `rtNotObject` narrowed to null its 15 stress legs fail. Full tier 1957 passed.
  - **260.4.4** Measure: non-generic enum sizes, and the array of a payload-free enum that 196 measured
    at 67 MB.
    — done. Apple M3 Max, release, best of 5. 196's `Array<Color>` (4 cases, 4M, built 5 times, scanned 20)
    takes 10 MB, as its hand-packed byte twin (it took 67); build 58 ms against the twin's 46, scan 91
    against 91 (Go: 18, 71, 19 MB). An array of 2M enums over a class reference, two in three holding a
    fresh object (`practice/gen/enum260/`): the non-generic `Slot { empty, full(box) }`, one word, takes
    81 MB; `Option<Box>`, still the tag word until 260.5, 104 MB. Build (316 against 311 ms, allocation
    bound), scan (29 ms each) and collection time (281 against 283 ms) are equal.
  — 260.4 done.
- **260.5** Generic enums, specialized and erased together: the value witness table's extra-inhabitant
  count and tag witnesses, the erased layout through them, channel receive and `select`.
  `Option<SomeClass>` becomes one word, and `Option<String>` loses its tag word.
  — done. A generic enum's instances follow the non-generic rules (the `<` exception is gone).
  - *The value witness table* carries the type's extra inhabitants as data, four `i32`s after the three
    pointers: count, offset, first unused value, and width with shift (`width | shift << 8`). Erased code
    decodes and writes them inline, so the table needs no tag witnesses (Swift's
    `getEnumTagSinglePayload`/`storeEnumTagSinglePayload`).
  - *The erased layout* (`DynEnumLayout`, `erasedEnumLayout`, `SSAIRToLLVM.swift`): `ShapeEnv.enumLayout`'s
    rules over the arguments' witnesses. Which cases have payloads fixes the kind; over one payload case,
    whether the other cases fit its extra inhabitants is a run-time `i1`, and the size, alignment, tag place
    and the enum's own extra inhabitants are selects on it. With no type parameter among the arguments it
    folds to the static layout's constants (`staticAlign` reads it so). The tag read (`loadEnumCase`) and
    write (`storeEnumCase`) pick a byte offset from the buffer, never between two pointers, and a width that
    is not a constant goes through `__nomu_uint_load`/`__nomu_uint_store` (a switch on 1, 2, 4, 8; one per
    address space). A named enum's static layout takes the same form (`namedEnumLayout`), so channel
    receive and `select` write the `Option` case through one function for both.
  - *GC components:* an erased enum with one payload case registers the payload's components whatever its
    case, since a payload-free case is the zeroed payload with an extra inhabitant written in, which holds
    no object. Enums with several payload cases keep the per-case registration on the tag word.
  - *Tests:* fixture `enum_layout_matrix/generic` (a library's generic bodies build and match `Option<T>`,
    `Option<Option<T>>`, a generic enum with two payload-free cases, one with a `Bool` beside its `T`, one
    over a generic struct, one in a generic class field; the caller builds and checks the same for `T` a
    class, `Int`, `Bool`, `UInt8`, `String`, a payload-free enum and a non-generic enum over a class) passes
    on all 24 pipeline × GC legs and under `release,mono_none`; with the erased layout forced to an appended
    tag its 16 debug and noinline legs fail. `mark-verify` and `mark-verify-arr` list one type fewer (a
    descriptor no longer needed). Full tier 1981 passed.
  - *binary-trees* (`practice/binary_trees`, M3 Max, release, best of 3): a `TreeNode` is 24 bytes (40).
    Depth 19 0.89 s, 110 MB (1.13 s after 260.2); depth 21 3.9–4.2 s, 445 MB (6.38 s), against Go's 5.27 s,
    205 MB (12.2 s on one core). At depth 21 the collector takes 1.73 s over 365 cycles and minors promote
    983 MB (2.6 GB before).
- **260.6** Recursive enums, boxed automatically: per case, by recursive group, recorded in the interface;
  recursion through a type parameter an error (260.1's check reports it, imported generics included).
  — done.
  - *The check* (`Typechecker.checkRecursiveValueTypes`) now finds each recursive group, removes the edges of
    every enum case holding a member of its own group, and reports what cycles remain: through struct fields
    only, or through a generic's type parameter ("value type 'Node' contains itself: Node.o → Node; a value
    type cannot hold itself except through an enum case; …").
  - *The boxing* (`midend/sources/BoxRecursiveCases.swift`) is a NOIR rewrite before monomorphization, on the
    module with any injected templates: the same graph over NOIR types, and for each boxed case a class
    `Enum$case` (generic over the enum's parameters) holding the payload, the case holding one `box` field of
    it. Construction becomes `Enum.case(box: Enum$case(fields…))`; a `switch` arm on the case binds the box and
    then each payload field from it. Monomorphization specializes a generic enum's box with the enum, and
    erased code allocates it through the generic-class path. As an ordinary allocation it is visible to
    escape analysis and to the safepoint analysis (a box allocated inside codegen's enum construction would
    hide a safepoint from SSAIR's liveness). `Tree { leaf, node(left, right) }` is one word over the box,
    null for `leaf`.
  - *Tests:* `recursive-enum` and `recursive-generic-enum` now compile and run; new error case
    `recursive-through-type-parameter`. Fixture `enum_layout_matrix/recursive` (a tree; an expression tree
    with two boxed cases beside an unboxed `Int`; two mutually recursive enums; a group through a struct; a
    cycle through `Option`; the library's generic `List<T>` built and read on both sides over an `Int`, a
    class and a `String`) passes on all 24 pipeline × GC legs and under `release,mono_none` with GC stress;
    with the rewrite disabled it fails to compile. Full tier 2006 passed.
  - *Not done:* escape analysis could keep a box on the stack when the enum does not escape; it treats a
    value placed in an enum as escaping today.
- **260.7** Several payload cases.
  - **260.7.1** The moved tag: smallest integer, after the payload, specialized and erased code; the shape
    model reads a word that is a reference in every case as a plain pointer.
    — done. `EnumLayout.tagged(tagOffset:width:)` replaces both the appended tag and the tag word: every
    payload from byte 0, the tag after the largest (a word over word-aligned payloads, else the smallest
    integer), a payload-free case zeroing the region. `enum Small { flag(Bool), byte(UInt8, Bool), none }` is
    3 bytes (it was 16). A word holding a reference in every payload case is in the enum's plain `managed`
    list and typed a pointer in its LLVM type (`{ region words…, iN tag }`, a pointer where shared, `i64`
    elsewhere), so the statepoint rewrite relocates it and the collector reads it with no decoding; the rest
    of each case is keyed by the tag at its offset. Erased code computes the same layout (`DynEnumLayout`'s
    `multi` kind) and zeroes every constructed enum's buffer. Fixture `enum_layout_matrix/multi` (an
    all-reference `Shape`, a mixed `Value` of `Int`, `String`, a class and a pair, a byte-sized `Small`, the
    library's generic `Either<A, B>` over classes, `Int`/`String` and `Bool`/`UInt8`) passes on all 24 legs
    and under `release,mono_none`; with the shared words typed `i64` its 15 moving-collector legs fail. Full
    tier 2030 passed.
    - *What spare bits could add.* With the moved tag an all-reference enum is already a plain pointer, so
      spare bits save only its second word. An array of 2M such enums (`practice/gen/enum260/two`, two
      reference cases, 16 bytes) against the same with one reference case (`one`, 8 bytes, the size spare
      bits would give): 104 MB against 81, scan 32 ms against 28. Build time is 176 ms against 311, the wrong
      way round: the 8-byte arrays (16 MB) are copied by minors where the 16-byte ones (32 MB) go to the
      large-object space, a collector policy outside 260 (the `Slot`/`Option<Box>` pair in 260.4.4 showed
      the same; [262](262-collector-gaps.md)).
  - **260.7.2** Spare bits under a fixed mask for all-reference enums: the tagged-reference shape kind, the
    collector's mask and restore, derived-pointer relocation (check the frame-record walk handles it), the
    heap verifier and the write barrier. Low bits first.
    — built. `EnumLayout.spareBits(payloadCases:)`: two to eight payload cases, each exactly one reference
    declared as one (a field mentioning a type parameter never qualifies, so erased code decides from the
    template's types what a specialized instance's marks record). Payload case `j` is the address plus `j`;
    payload-free case `k` is `k << 3`; the rest of the first page is the enum's extra inhabitants (shift 3).
    Codegen tags and untags by a GEP of ±`j`, so a tagged value is a pointer derived from its object and the
    statepoint rewrite relocates it; the case is read from a plain `ptrtoint` (the low bits and the
    below-the-first-page test survive a move). The collector masks every managed word in place of a separate
    shape kind: `rtRefTag`/`rtUntag` (`runtime/descriptors.nomu`) at every load the runtime makes of one, the
    write-backs restoring the tag (the trace's fields and header pointers, the root slots, the minor's
    forward), the verifiers and the leak walk untagging. The write barrier is unchanged. `measure.no_spare_bits`
    keeps the moved tag, for 260.7.3. The `multi` fixture gained `Pet` (three reference cases, two
    payload-free) and `Node` (an expression tree whose boxed cases are all references); with the mask removed
    every leg fails. Full tier 2030 passed, three rounds.
  - **260.7.3** Measure the two on an array of an all-reference enum and an interpreter-style tree walk:
    size, run time, the collector's time per word. Keep one or both.
    — measured (M3 Max, release, best of 5; `practice/gen/enum260/two` and `tree`). Under the default
    generational plan the array pair also differs in where the collector puts the array (the 16 MB spare-bit
    array is copied by minors with its boxes, the 32 MB moved-tag one goes to the large-object space), so the
    reads are compared under `gc_immix`, which does not copy on minors:

    | program | spare bits | moved tag |
    |---|---|---|
    | array of 2M, build / scan / RSS | 138 ms / 49 ms / 73 MB | 148 ms / 29 ms / 104 MB |
    | tree walk, build / eval / RSS | 287 ms / 81 ms / 105 MB | 258 ms / 69 ms / 147 MB |
    | (generational) array, build / scan / RSS | 313 ms / 60 ms / 81 MB | 174 ms / 32 ms / 104 MB |

    Spare bits take about 30% less memory and read 17% (tree) to 70% (array scan) slower: the case is decoded
    from the word (a mask, a page compare, selects) before the payload load, which depends on it. The
    collector's mask costs nothing measurable where no word is tagged: binary-trees depth 21 runs 3.89–3.92 s
    with it and 3.91–3.92 s without.

    *A cheaper decode, then measured again.* The disassembly showed where the reads lost. In the array scan the
    moved tag's two payload arms read the same field and merge into one path; the spare-bit arms could not,
    since each untagged by its own constant. In the tree walk the decode (a mask, a page compare, a select)
    sat before the first branch, where the moved tag's case arrives in a register. Three changes:
    - the tag is the case index: payload case `c` is the address plus `c`, payload-free case `c` is `c << 3`
      (the payload cases must be among the first eight), so the case is `word >> 3` below the first page and
      `word & 7` above, with no lookup;
    - every case untags the same way, the word less its own low bits (`spareBitUntag`), so arms that do the
      same work merge;
    - with no payload-free case the case is `word & 7` alone.

    | program | spare bits | moved tag |
    |---|---|---|
    | array, `gc_immix`: build / scan / RSS | 141 ms / 33 ms / 73 MB | 150 ms / 29 ms / 104 MB |
    | array, generational: build / scan / RSS | 311 ms / 39 ms / 81 MB | 173 ms / 33 ms / 104 MB |
    | tree, `gc_immix`: build / eval / RSS | 289 ms / 75 ms / 105 MB | 240 ms / 73 ms / 147 MB |
    | tree, generational: build / eval / RSS | 449 ms / 72 ms / 159 MB | 507 ms / 66 ms / 207 MB |

    Reads are now 3–18% slower with spare bits (from 17–70%), memory 23–30% lower. Builds go both ways and
    follow the collector, not the encoding: the generational array build is the large-object-space effect
    (260.7.1); the `gc_immix` tree build spends 240 ms collecting against 185 over the same 35 cycles with
    half the peak heap, while under the generational plan spare bits collect less (413 ms against 466,
    promoting 250 MB against 381). Full tier 2030 passed. Both build effects are explained in 260.7.4.
  - **260.7.4** The collector effects behind the build times — done. Neither comes from the encoding.
    - *Heap sizing counts bytes, a cycle's cost counts objects.* After each major the limit becomes live +
      (live + stacks) × r (`NOMU_GC_PERCENT`, Go's GOGC shape). One tree kept live while garbage drives
      collections (`practice/gen/enum260/live`, `gc_immix`): spare bits leave 82 blocks live and a 165-block
      heap, the moved tag 114 and 229; a cycle traces the same objects in either (1.06 ms against 1.09) but
      the smaller heap collects more often (80 cycles against 59). The same percent therefore compares two
      points on the memory–time curve. At matched memory spare bits win on time: the tree benchmark under
      `gc_immix` takes 304 ms and 147 MB with the moved tag at 100%, and with spare bits 351 ms at 100%, 257
      at 150%, 203 at 200%, all at 105 MB; under the generational plan 539 ms and 211 MB against 410–504 ms
      and 122–159 MB at every percent tried. (The times are not monotonic in the percent: when a collection
      lands against each tree build shifts with the heap size.)
    - *Large objects decide between majors and minors.* Objects over 32 KiB go to the large-object space and
      count toward mature space. In the array benchmark the moved tag's 32 MB arrays trigger majors only (29,
      151 ms, nothing copied); the spare-bit 16 MB arrays leave room for 10 minors (147 ms) beside 24 majors
      (138 ms), and the minors promote 70 MB of boxes that the next round's array leaves dead. That is the
      promote-all cost [262](262-collector-gaps.md) lists.

    *Richards* (the Are-We-Fast-Yet scheduler, ported to `practice/gen/richards` and its Go twin
    `practice/go/richards`; the four task kinds are an enum over a class each, which the scheduler switches on
    at every task run; 1000 runs, best of 7):

    | | generational | `gc_immix` |
    |---|---|---|
    | spare bits | 592 ms, 3 MB | 482 ms, 3 MB |
    | moved tag | 597 ms, 4 MB | 482 ms, 3 MB |
    | Go | 477 ms, 5 MB (473 on one core) | |

    The layouts tie: the enum is read once per task run and the live data is a few objects. The run collects
    nothing, so the generational plan's 23% is the write barrier, always on, on every store into an object
    ([262](262-collector-gaps.md)).

    Both effects are explained. The choice was never between two layouts: the moved tag stays the layout of
    every tagged enum that does not qualify (scalar or multi-field payloads, byte payloads, a single payload
    with too few extra inhabitants), so it was the moved tag alone against the moved tag plus spare bits for
    the enums that qualify — Swift's combination, which uses spare bits wherever every payload leaves them and
    tag bytes otherwise.

    *Decided: the moved tag plus spare bits.* The encoding fixes every value's size and with it the memory
    downstream, while the read cost (3–18% in tight loops, none in Richards) and the collector's policies can
    still be tuned. Adding spare bits leaves moved-tag enums' code unchanged; the one shared cost, the
    collector's mask on every managed word, measured at nothing. The cost is maintenance: every runtime reader
    of a managed word must mask it (`runtime/README.md`). Under LXR the mask moves to the reference-count
    increments and decrements, whose side tables are indexed by address shifted past the tag bits, so it is
    expected to stay small; to be measured there. `measure.no_spare_bits` keeps the moved tag for comparison.
    The two collector findings are in [262](262-collector-gaps.md).
  - **260.7.5** Spare bits in a shared reference word, Swift's wider rule in part: the tag goes in the low
    bits of a reference every payload case holds at the same offset, so multi-field payloads qualify
    (`Shape { circle(c: Circle), rect(r: Rect, scale: Int) }`, 24 bytes to 16). Every other word must be a
    reference in every payload case or in none, since with no tag word the collector cannot decode per-case
    content; no field may come from a type parameter. High pointer bits, spare bits in non-pointer fields and
    generic payloads stay out: masking on every dereference off arm64, a shaped leaf's tag bits read by the
    collector, and value witness masks, each for a small gain.
    — done. `EnumLayout.spareBits(payloadCases:tagOffset:)`; `ShapeEnv.spareBitWord` finds the first offset
    holding a reference field in every payload case, and requires every payload case's managed words to be the
    same, none conditional. The enum is its payload region's words, a pointer where shared; construction tags
    the shared word, the case is read from it, and only the field lying there is untagged. Erased code takes a
    qualifying template's static layout (its payload fields mention no type parameter). The `multi` fixture's
    `Shape` now takes this path, and `Duo` (two shared references, an `Int`, two payload-free cases) joins it;
    with the shared word read untagged it fails. Full tier 2030 passed. An array of 2M such enums
    (`practice/gen/enum260/shape`, 16 bytes against 24): generational build / scan / RSS 172 ms / 50 ms /
    104 MB against 177 / 57 / 136; `gc_immix` 150 / 50 / 104 against 156 / 50 / 135.
  — 260.7 done.
- **260.8** Measure: binary-trees size and time, the collector's decoding share, frame homes removed.
  — done. Against the committed build before 260.4 (`git archive HEAD`, the tag-word layout with 260.2's
  offset list), `practice/binary_trees`, M3 Max, release, best of 3; profiles from `sample` over the whole
  depth-21 run, idle threads left out:

  | | before 260.4 | now |
  |---|---|---|
  | `TreeNode` | 40 bytes | 24 |
  | depth 19 | 1.12 s, 203 MB | 0.89 s, 110 MB |
  | depth 21 | 6.38 s, 551 MB | 3.89 s, 445 MB (Go 5.27 s, 205 MB) |
  | runtime's share of busy samples | 56% | 40% |
  | offset listing (`rtOffsetsInto`, `rtOffsetListed`, stubs) | 29% of busy, 51% of the runtime's | 9%, 22% |
  | volatile loads in the program's IR | 15 | 1 |

  The listing now decodes nothing (`Option<TreeNode>` is a plain pointer); what is left of it is copying two
  fixed offsets per object into the list and reading them back through calls, which an object with no
  conditional field does not need ([262](262-collector-gaps.md)). Minors promote 983 MB at depth 21 where they promoted 2.6 GB
  (260.5). No value of the program has a shaped home in either build: the enum words were reloaded from
  recorded frame slots, the 14 volatile loads now gone.
- **260.9** A recursive enum's box on the stack: escape analysis treats a value placed in an enum as escaping
  (`makeEnum`), so a box (260.6) is always on the heap, even for an enum that never leaves its frame.
  — moved to [148](148-ssair-optimizer-tier.md).1's stored-into-local promotion. It is that tail's case for
  aggregates: [166](166-points-to-graph.md).4's precise query relaxes containment for a local class object's
  field and could relax it for a struct or enum value the same way, but promoting any object stored into a
  field is blocked at the transform (I4: an `addrspace(1)` field pointing at a stack slot), which 148 owns.
  Nothing in it is specific to boxes or to enum layout.

**260 is done.**

The collector gaps the measurements here found (the offset list, the write barrier, heap sizing by bytes,
promotion, the unmark walk, marking on the program's thread, stubs) are [262](262-collector-gaps.md).

## Refs

`llvmgen/LLVMGenLayout.swift` (`enumType`, `caseStructType`), `midend/ssair/sources/Shape.swift`
(`Layout.swift`'s `size`/`enumCaseLayout`, `shape`), `llvmgen/SSAIRToLLVM.swift` (`erasedTypeSize`, `erasedEnumPayloadOffset`,
the channel and `select` receive), `runtime/descriptors.nomu`; Swift's `GenEnum.cpp` (IRGen) and its
runtime's enum metadata.

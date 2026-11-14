# Enum layout — extra inhabitants, and recursive enums without a keyword

**Avenue:** Risk (perf, footprint) · **Type/Lifecycle:** `compiler · layout · gc` · **Size:** L ·
**Status:** direction decided (Swift's layout, recursive enums boxed automatically); 260.1 done; 260.3 (design) in progress; 260.4 onward waits on [196](196-dense-value-layout.md) ·
**Source:** the binary-trees investigation after [230](230-heap-sizing.md): a node is 40 bytes against Go's
16, and decoding its enum fields is most of the collector's time.

## Today

Every enum lowers to `{ i64 tag, [P x i64] payload }`, P the largest case's slot count (`enumType`,
`llvmgen/LLVMGenLayout.swift`), and every field is a whole 8-byte slot (`ShapeEnv.slots`,
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
  counts and costs are Swift's.
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
  - a strongly connected component of that graph is a recursive group; each enum payload field whose type is
    in its enum's group is stored as a reference to an immutable heap box;
  - a box is a never-null reference, so it has extra inhabitants: `enum Tree { case leaf; case node(left:
    Tree, right: Tree) }` becomes one word per value, null for `leaf`;
  - enum values are immutable, so a box is shared on copy without copy-on-write;
  - a cycle through structs only, with no enum payload to box, is an error, as in Swift.

  Open: a group spanning several enums (box every in-group payload, or the fewest edges); how the boxing
  decision is recorded in module interfaces (a change in another module can close a cycle and change a
  layout, which rebuilds dependents); whether a box is its own object kind or a compiler-made class.
- **The value-type rule — decided: removed.** A struct or enum may hold references, as in Swift: copies
  share the referenced objects, and the shareability pass decides what crosses fibers, as it already did
  for generic instances. The extra-inhabitant layout therefore applies to concrete enums as well as
  generic ones.
- **Several payload cases — open.** Spare pointer bits (one word for an enum of references, but its words
  stay conditional and keep frame homes and decoding) or a tag word as today.
- **The collector.** An enum laid out in a reference's extra inhabitants is `managed` in the shape model, a
  plain pointer field. Enums that keep a tag stay conditional; their decoding cost is 260.2's.

## Dependencies

- [196](196-dense-value-layout.md) (dense value layout) before 260.4: the layout enums are built on.

## Work

- **260.1** Recursive value types are an error — done. The Typechecker finds cycles among structs and
  enums before any pass walks field types (`checkRecursiveValueTypes`): an edge for each field or payload
  held inline, through a generic's argument only where the generic holds that parameter inline, so
  `Array<Node>` in `Node` is fine and `Pair<S>` in `S` is a cycle; Tarjan's components, each reported once
  with its path ("value type 'A' contains itself: A.b → B.a → A"). Until 260.6, recursive enums are errors
  too. Cases `recursive-enum`, `recursive-struct-mutual`, `recursive-generic-struct`,
  `recursive-generic-enum`, `value-type-nesting`. A cycle through an imported generic is not seen (its
  fields are not in the program).
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
- **260.3** Settle the open design questions above.
- **260.4** Extra inhabitants for every type, and single-payload enums over them, in specialized code:
  layout, construction, tag test, payload read, shapes; the collector's "not an object" bound for
  references. `Option<SomeClass>` becomes one word, and `Option<String>` loses its tag word.
- **260.5** Erased generics: the value witness table's extra-inhabitant count and tag witnesses; channel
  receive and `select` through them.
- **260.6** Recursive enums, boxed automatically.
- **260.7** Several payload cases, as 260.3 decides.
- **260.8** Measure: binary-trees size and time, the collector's decoding share, frame homes removed.
- **260.9** binary-trees against Go, last: re-measure with enum layout in, then investigate the gaps
  outside it.
  - *Nursery promotion:* minors promote 2.6 GB at depth 21, nearly all of it garbage soon after, which
    costs the copying and drives the majors; options are a variable nursery, aging, or a parallel minor
    (in-place promotion is the route the Immix line mostly left, for fragmentation).
  - *The unmark walk:* a second full trace in every major (about 1.2 s at depth 21); flipping mark states
    or a side mark table cleared in bulk removes it, with log bits set in the trace.
  - *The collector on the program's thread:* Go marks on its spare cores, which is most of its lead on all
    cores; parallel marking in the pause, or concurrent marking.
  - *The minor's second pass:* clearing mark bits and setting log bits over the promoted objects after
    copying (0.27 s at depth 21) could happen at copy time.
  - *Stubs on runtime calls:* runtime functions are exported weak symbols, so each call goes through a
    stub; hidden visibility saved 2–4%.

## Refs

`llvmgen/LLVMGenLayout.swift` (`enumType`, `caseStructType`), `midend/ssair/sources/Shape.swift`
(`ShapeEnv.slots`, `shape`), `llvmgen/SSAIRToLLVM.swift` (`erasedTypeSize`, `erasedEnumPayloadOffset`,
the channel and `select` receive), `runtime/descriptors.nomu`; Swift's `GenEnum.cpp` (IRGen) and its
runtime's enum metadata.

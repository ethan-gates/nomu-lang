# Enum layout — extra inhabitants, and recursive enums without a keyword

**Avenue:** Risk (perf, footprint) · **Type/Lifecycle:** `compiler · layout · gc` · **Size:** L ·
**Status:** direction decided (Swift's layout, recursive enums boxed automatically); 260.1 next ·
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

**Recursive value types crash the compiler.** An enum whose payload holds itself, or a struct whose field
does, ends the compiler with `SIGBUS` (exit 138, a stack overflow): `ShapeEnv.slots` recurses with no cycle
guard. Recursion through a class works (`TreeNode` above).

## What

Swift's enum layout, then whatever improves on it:

- every type reports its **extra inhabitants**, the bit patterns it never uses;
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
- **The slot model — open.** Nomu lays every value out in whole 8-byte slots; Swift is byte-precise with
  alignment. Keeping slots keeps every consumer of `slots` (GC maps, array strides, erased offsets) as it
  is, and gives more extra inhabitants than Swift has (every enum tag word and `Bool` slot has nearly 2^64
  spare values); an appended tag costs a whole slot. Byte-precise layout saves memory for small payloads
  and changes every consumer. Proposed: keep slots now.
- **Which types report extra inhabitants first — open.** References (class, actor, array, closure,
  existential) are the case that matters most. Then enum tag words, `Bool`, `StringBase`'s unused tag
  values (`Option<String>` without a tag word), and structs, taking a field's (Swift takes the field with
  the most).
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
- **Several payload cases — open.** Spare pointer bits (one word for an enum of references, but its words
  stay conditional and keep frame homes and decoding) or a tag word as today.
- **The collector.** An enum laid out in a reference's extra inhabitants is `managed` in the shape model, a
  plain pointer field. Enums that keep a tag stay conditional; their decoding cost is 260.2's.

## Work

- **260.1** Recursive value types: report an error naming the cycle, in place of the compiler's stack
  overflow. Until 260.6, recursive enums are errors too.
- **260.2** The collector decodes each enum field once — built, not committed. `rtOffsetsList`
  (`runtime/descriptors.nomu`) lists a fixed-size object's live offsets in one pass, decoding each enum
  field once, where `rtLiveCount` and `rtLiveOffsetAt` decoded every field again for each index. Used by
  the evacuate-mark, unmark, unmark-and-unlog and minor-scan walks. binary-trees depth 19 1.27 s → 1.13 s,
  depth 21 7.22 s → 6.38 s; the `immix` plan at depth 19 3.12 s → 2.60 s. Full tier 1820 passed.
- **260.3** Settle the open design questions above.
- **260.4** Extra inhabitants for references, and single-payload enums over them, in specialized code:
  layout, construction, tag test, payload read, shapes. `Option<SomeClass>` becomes one word.
- **260.5** Erased generics: the value witness table's extra-inhabitant count and tag witnesses; channel
  receive and `select` through them.
- **260.6** Recursive enums, boxed automatically.
- **260.7** Wider extra inhabitants: enum tag words, `Bool`, `StringBase`, structs.
- **260.8** Several payload cases, as 260.3 decides.
- **260.9** Measure: binary-trees size and time, the collector's decoding share, frame homes removed.
- **260.10** binary-trees against Go, last: re-measure with enum layout in, then investigate the gaps
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

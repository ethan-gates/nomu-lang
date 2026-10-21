# shape_matrix

Coverage matrix for one shape per type (task 176.5): a heap `String`, held in each position a program can
hold one, read back across collections that reuse moved-from memory. Each case prints `bad N`, the count of
reads that saw wrong bytes; correct is `bad 0`. The suite's `shape` group runs every case across the
`pipeline` and `gc` dimensions (`tests/README.md`, "Dimensions and groups"):
`compiler-test tests/suite.json --enable 'shape/*'`, with `--tier full` for the release and no-inline
pipelines and the major-collection leg. A case needs no manifest edit: add a directory here.

- `layout_*` hold `Bool` fields before a managed field, where the descriptor's 8-byte-slot offsets and the
  LLVM struct layout disagree. `layout_control` (one `Bool`) is the passing control.
- `*_fresh` variants hold no `String` local in the caller, isolating the callee's frame.
- `xmod_*` put the callee in another module (`lib/`); `xmod_erased*` call an erased generic. The erased
  layout cases, which allocate nothing, are the `layout` group (`tests/fixtures/layout_matrix/`).
- `enum_array_local`, `struct_array_*` hold a plain managed pointer (an `Array`) inside a value: an enum's
  payload words are `i64`s the statepoint rewrite cannot see, a struct's field is a `ptr` it can.
- `array_pair_append` builds `Array<Pair>` by `append`; `array_pair` (a literal) needs aggregate temporaries.
- `mature_field_store` stores young `String`s into a class object made mature first; the store must take the
  write barrier.

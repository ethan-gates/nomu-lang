# shape_matrix

Coverage matrix for one shape per type (task 176.5): a heap `String`, held in each position a program can
hold one, read back across collections that reuse moved-from memory. Each case prints `bad N`, the count of
reads that saw wrong bytes; correct is `bad 0`. `run.sh` builds and runs every case (or the ones named) on the
Nomu collector four ways: default, minor collections every 64 nursery blocks, a minor every 4 KiB allocated
(`NOMU_GC_STRESS`), and a defrag major every 4 KiB allocated. Not yet wired into `tests/suite.json`; the
176.5 tests phase does that once the cases pass.

- `layout_*` hold `Bool` fields before a managed field, where the descriptor's 8-byte-slot offsets and the
  LLVM struct layout disagree. `layout_control` (one `Bool`) is the passing control.
- `*_fresh` variants hold no `String` local in the caller, isolating the callee's frame.
- `xmod_*` put the callee in another module (`lib/`); `xmod_erased*` call an erased generic.
- `enum_array_local`, `struct_array_*` hold a plain managed pointer (an `Array`) inside a value: an enum's
  payload words are `i64`s the statepoint rewrite cannot see, a struct's field is a `ptr` it can.
- `array_pair_append` builds `Array<Pair>` by `append`; `array_pair` (a literal) needs aggregate temporaries.

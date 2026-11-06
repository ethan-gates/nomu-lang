# Frame table: per-function frame descriptions that survive the link

**Avenue:** Risk · **Type/Lifecycle:** `correctness · needs-design` (driver link step + codegen + both
stack walkers) · **Size:** L · **Status:** not started; implementation child of
[194](194-gc-frame-metadata.md) · **Source:** 194's decision (F2 in `internals/frames-designs.md`)

## Deliverable

The frame table F2 in production: one entry per function, in its own section atom so the linker drops it
with its function, found from a return address through a sorted index, built from LLVM's stack maps by a
link-time step. It replaces [195](195-link-time-gc-frame-index.md)'s index over the concatenated
`__llvm_stackmaps` blobs. The runtime's readers (the collector's walk and the copier's) read only it.

## What it must meet

From the contract (`internals/frames-contract.md`):

- **T1.** An entry is dropped with its function when the function is dead-stripped or folded away, and is
  found from its code address. Today every function with statepoints ships, and folded duplicates keep
  records bound to the kept copy (240, problems 16–18).
- **T2.** Lookup costs no setup at launch or first collection, within 195's budget (under 1 ms of setup
  for a 2M-line program).
- **T3.** Each image carries its own table, found from a code address.
- **R3.** Shapes are named with their locations and resolve across separately compiled objects, retiring
  the per-compile shape ordinals and their side tables.
- **R8, only if the stack check moves into the prologue.** Each function's entry would name the kinds of its
  arguments in registers. [104](104-fiber-stack-strategy.md)'s check runs after the prologue, so it needs
  none today.

## Questions to settle

- **Entry layout:** the locations per stop, their kinds and shapes; size per record
  against LLVM's ~68 bytes.
- **Producing per-function atoms from per-object stack maps:** split each object's `__llvm_stackmaps`
  into per-function entries before the link (a step after codegen, per object), or after it.
- **Dead stripping and folding:** whether a per-function section with `S_ATTR_LIVE_SUPPORT` is dropped by
  ld64 with its function, as `eh_frame` is, and whether ld64 also drops the entry of a folded-away copy
  (untested).
- **Lookup:** the sorted index built at link time, as 195 does today.

## Dependencies

- Replaces 195's index (195 is done; its suite cases and build test carry over).
- A prologue stack check (104, "Considered") would need R8's argument kinds from this table.

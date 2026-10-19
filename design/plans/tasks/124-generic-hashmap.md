# Generic hash map

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · blocked` · **Size:** M ·
**Status:** blocked (D6 spill) · **Source:** deferred.md (2026-08 session)

## What

No hash map exists today; the earlier hand-written benchmark map (concrete keys, built on C builtins)
was removed in favor of a real `std` one. The
real generic map recreates the **category-3 FCA** case in two ways:
- a generic value type,
- reading a whole array element by value (`let e = a[i]` mixing values + refs).

## Blocked on

The **D6 spill** (`c-types.md` §3.4) — whole-aggregate value reads. Same blocker as
[tuples](109-tuples.md).

## Open (beyond the blocker)

The eventual map's algorithm (swiss-table or otherwise) and whether it lives in the C `core` floor or
in Nomu is undecided — see [SIMD](126-simd.md) (swiss-table control-byte scan) and
[stdlib-core](120-stdlib-core.md).

## Refs

deferred.md "Generic hash map / whole-aggregate element reads"; `c-types.md` §3.4 (D6 spill).

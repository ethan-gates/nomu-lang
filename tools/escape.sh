#!/bin/zsh
# 6.5.2 — escape analysis stack-allocates a non-escaping, managed-free class instance.
#
# The only heap candidate in examples/escape.nomu is `p`, a leaf `Point` used solely through field
# reads. With the pass on, the emitted object references no `rt_alloc` (the allocation is stack-
# promoted); with NOMU_NO_ESCAPE=1 the object references `rt_alloc` (heap). Output is identical either
# way — best-effort: precision affects speed only, never correctness.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/escape.nomu
OBJ=$ROOT/build/examples/escape.o
BIN=$ROOT/build/examples/escape
fail() { echo "FAIL: $1"; exit 1; }

# Pass on: the leaf Point is stack-allocated, so no heap allocator call survives.
"$NOMUC" "$SRC" >/dev/null 2>&1 || fail "compile (escape on)"
on_out=$("$BIN") || fail "run (escape on)"
nm "$OBJ" | grep -q '_rt_alloc' && fail "escape on: object still references rt_alloc (not stack-promoted)"

# Pass off: the same site heap-allocates, so the allocator call reappears.
NOMU_NO_ESCAPE=1 "$NOMUC" "$SRC" >/dev/null 2>&1 || fail "compile (escape off)"
off_out=$("$BIN") || fail "run (escape off)"
nm "$OBJ" | grep -q '_rt_alloc' || fail "escape off: expected a heap allocation (rt_alloc) but found none"

[[ "$on_out" == "$off_out" ]] || fail "output differs on/off: '$on_out' vs '$off_out'"
echo "PASS: escape — non-escaping leaf Point stack-allocated (no rt_alloc with pass on; heap with NOMU_NO_ESCAPE=1); output '$on_out' identical either way"

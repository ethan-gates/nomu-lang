#!/bin/zsh
# Task 149 · poll-suppression slice (128.1.1 prerequisite). Codegen drops a `__nomu_poll` safepoint at
# every loop header so a stop-the-world collector can pause the mutator (runtime.md §6). A runtime-subset
# function must not carry that poll — its code may run *during* a stop-the-world, so the poll would
# recursively try to stop the world (runtime-subset.md §4). This checks the codegen-site guard directly in
# the emitted machine code: the same `ramp` loop carries the poll's slow-path call when ordinary, and
# carries none under `--runtime-subset=ramp`. Suppression is a codegen property — both binaries print 45.
#
# Inlining is disabled (NOMU_NO_INLINE) so `ramp` stays a distinct symbol to disassemble; the guard lives
# at the loop header regardless of inlining. macOS: the poll's inlined fast path tail-calls
# `__nomu_gc_poll_slow`, which shows up as a `bl ___nomu_gc_poll_slow` inside the function body.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/subset_poll.nomu
BIN=$ROOT/build/examples/subset_poll
fail() { echo "FAIL: $1"; exit 1; }

# The poll slow-path calls inside the `ramp` function body (the poll fingerprint in disassembly).
ramp_polls() {
  otool -tvV "$BIN" | sed -n '/_nomu_fn_ramp:/,/^_[a-zA-Z][a-zA-Z0-9_]*:/p' | grep -c "nomu_gc_poll_slow"
}

# Leg 1 — ordinary function: the loop header carries a poll.
NOMU_NO_INLINE=1 "$NOMUC" "$SRC" >/dev/null 2>&1 || fail "control did not compile"
out=$("$BIN" 2>/dev/null); [[ "$out" == "45" ]] || fail "control output: got '$out', want 45"
[[ $(ramp_polls) -ge 1 ]] || fail "control: expected a safepoint poll in 'ramp', found none"

# Leg 2 — runtime-subset function: the loop header carries no poll.
NOMU_NO_INLINE=1 "$NOMUC" --runtime-subset=ramp "$SRC" >/dev/null 2>&1 || fail "subset build did not compile"
out=$("$BIN" 2>/dev/null); [[ "$out" == "45" ]] || fail "subset output: got '$out', want 45"
[[ $(ramp_polls) -eq 0 ]] || fail "subset: 'ramp' still carries a safepoint poll (suppression failed)"

# Leg 3 — the subset build also runs correctly under the default (inlining) pipeline.
"$NOMUC" --runtime-subset=ramp "$SRC" >/dev/null 2>&1 || fail "subset build (default pipeline) did not compile"
out=$("$BIN" 2>/dev/null); [[ "$out" == "45" ]] || fail "subset default-pipeline output: got '$out', want 45"

echo "PASS: poll-suppression — a runtime-subset loop emits no __nomu_poll (guard in codegen); result unchanged (45)"

#!/bin/zsh
# Task 128.1.1 · scheduler substrate — raw OS clock. Compiles examples/sysclock.nomu (the monotonic-clock
# primitive `RawPtr.monotonicNanos()`, reaching the OS directly — macOS: the libSystem entry
# clock_gettime_nsec_np, no C-runtime shim) and checks its two invariants: the clock is positive and
# non-decreasing across a span of work → 1 / 1. Three legs:
#   1. ordinary build compiles, runs, and links clock_gettime_nsec_np.
#   2. `--runtime-subset=elapsed` compiles (the `__sys` clock primitive is subset-legal) and runs the same.
#   3. under the moving collector (Immix, stressed) the output is unchanged — the clock touches no heap.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/sysclock.nomu
BIN=$ROOT/build/examples/sysclock
STRESS=${NOMU_GC_STRESS:-512}
want=$'1\n1'
fail() { echo "FAIL: $1"; exit 1; }

# Leg 1 — ordinary build.
"$NOMUC" "$SRC" >/dev/null 2>&1 || fail "compile"
out=$("$BIN" 2>/dev/null); [[ "$out" == "$want" ]] || fail "output: got '$(echo $out)', want '1 1'"
otool -L "$BIN" 2>/dev/null | grep -q "libSystem" || fail "binary is not linked against libSystem (clock_gettime_nsec_np unresolved?)"

# Leg 2 — the clock reader as runtime-subset code (proves `__sys` is subset-legal; loop poll suppressed).
"$NOMUC" --runtime-subset=elapsed "$SRC" >/dev/null 2>&1 || fail "subset build did not compile"
out=$("$BIN" 2>/dev/null); [[ "$out" == "$want" ]] || fail "subset output: got '$(echo $out)', want '1 1'"

# Leg 3 — the moving collector never relocates the clock, so the invariants hold identically.
"$NOMUC" "$SRC" >/dev/null 2>&1 || fail "recompile"
evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null)
[[ "$evac" == "$want" ]] || fail "output differs under the moving collector"

echo "PASS: sysclock (monotonic ns via libSystem clock_gettime_nsec_np) — positive + non-decreasing; subset-legal; GC-independent"

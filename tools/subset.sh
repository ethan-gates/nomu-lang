#!/bin/zsh
# Task 149 · slice 1 — the runtime-subset check (interim `--runtime-subset=<names>` designation). Three
# legs:
#   1. examples/subset_ok.nomu under `--runtime-subset=carve,advance` compiles clean and runs (a subset
#      function that allocates only off-heap via RawPtr, and calls another subset function) → 42.
#   2. examples/subset_bad.nomu under `--runtime-subset=bad` is rejected with exactly the two expected
#      violations (a class allocation; a call to a non-subset function).
#   3. examples/subset_bad.nomu WITHOUT the flag compiles clean — the rules apply only to designated code.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
fail() { echo "FAIL: $1"; exit 1; }

# Leg 1 — legal subset code compiles and runs.
$NOMUC --runtime-subset=carve,advance "$ROOT/examples/subset_ok.nomu" >/dev/null 2>&1 || fail "legal subset code did not compile"
out=$("$ROOT/build/examples/subset_ok" 2>/dev/null)
[[ "$out" == "42" ]] || fail "subset_ok output: got '$out', want 42"

# Leg 2 — illegal subset code is rejected with both violations.
errs=$($NOMUC --runtime-subset=bad "$ROOT/examples/subset_bad.nomu" 2>&1)
echo "$errs" | grep -q "may not allocate a 'Box'" || fail "missing the class-allocation violation"
echo "$errs" | grep -q "may not call 'helper'"     || fail "missing the non-subset-call violation"

# Leg 3 — the same file without the designation compiles clean.
$NOMUC "$ROOT/examples/subset_bad.nomu" >/dev/null 2>&1 || fail "subset_bad should compile without the flag (rules are designation-scoped)"

echo "PASS: runtime-subset check — legal subset code compiles + runs (subset→subset calls allowed); illegal code rejected (heap alloc + non-subset call); undesignated code unaffected"

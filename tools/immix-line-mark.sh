#!/bin/zsh
# Task 150 · rung 3 (Immix), increment 150.3.4 — line marking (diagnostic checkpoint). The tracer marks the
# live set (header bit 32, rung 2) and additionally marks each live in-heap object's lines
# (selfhosted-gc.md §10.4); no reclaim, no move. rtLineMarkCheck independently re-derives the line set and
# confirms completeness (every live object on marked lines) + soundness (no line marked beyond the live
# footprint). Runs under NOMU_GC_PLAN=nomu (line marking is a self-hosted-heap concept). Object marking +
# the address-independent fingerprint are the same logic mark-verify.sh already checks cross-plan.
# Checks:
#   1. examples/immix_line_mark.nomu compiles clean (prelude auto-subset, task 149).
#   2. Output is TOTAL 52 / LINECHECK 0 / LINES>0 1 — 52 live objects, line set complete + sound, lines set.
#   3. Deterministic across runs.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/immix_line_mark
fail() { echo "FAIL: $1"; exit 1; }

# 1 — compiles clean (and produces the binary).
errs=$($NOMUC "$ROOT/examples/immix_line_mark.nomu" 2>&1)
echo "$errs" | grep -qiE "error|runtime-subset function" && fail "immix_line_mark not clean:\n$errs"

want="TOTAL 52
LINECHECK 0
LINES>0 1"
# 2 — correct under the self-hosted heap.
got=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$got" == "$want" ]] || fail "output: got '$(echo $got)', want '$(echo $want)'"
# 3 — deterministic.
got2=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$got2" == "$got" ]] || fail "non-deterministic across runs"
echo "PASS: Immix line marking (150.3.4) — 52 live objects, line set complete + sound (LINECHECK 0), diagnostic checkpoint before reclamation"

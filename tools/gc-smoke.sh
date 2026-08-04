#!/bin/zsh
# M8.4.3 smoke: prove the stack-map parser + single-stack root walk recover the EXACT *live* GC-root
# set at a forced safepoint — including precision (a dead-but-still-on-stack object is NOT reported).
# Compiles examples/gc_smoke.nomu and runs it under NOMU_GC_SMOKE=1; the runtime walks the stack at
# the `sleep` statepoint and reports each recovered root's offset-8 field on stderr.
#
# Expected across two frames + two managed kinds (class + heap-boxed closure): the live objects
# 111, 222, 333, 444 (111 twice — same object referenced in both frames). The dead object 999 must
# NOT appear, and no unexpected value may appear.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
"$NOMUC" "$ROOT/examples/gc_smoke.nomu" >/dev/null || { echo "FAIL: compile"; exit 1; }
out=$(NOMU_GC_SMOKE=1 "$ROOT/build/examples/gc_smoke" 2>&1 1>/dev/null)
echo "$out"

fail() { echo "FAIL: $1"; exit 1; }
# Precision: the dead object must be excluded.
echo "$out" | grep -q 'v=999' && fail "reported dead object 999 (not precise)"
# Coverage: every live object found (multi-frame, class + closure).
for want in 111 222 333 444; do
  echo "$out" | grep -q "v=$want" || fail "missing live root $want"
done
# No unexpected roots: every recovered value must be one of the known live objects.
bad=$(echo "$out" | grep -oE 'v=-?[0-9]+' | grep -vE 'v=(111|222|333|444)$' || true)
[[ -n "$bad" ]] && fail "unexpected root value(s): $bad"
echo "PASS: recovered exactly the live set {111,222,333,444} across 2 frames; dead 999 excluded"

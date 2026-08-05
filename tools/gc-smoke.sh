#!/bin/zsh
# M8.4.3 smoke: prove the stack-map parser + single-stack root walk recover the EXACT *live* GC-root
# set at a forced safepoint — including precision (a dead-but-still-on-stack object is NOT reported).
# Compiles examples/gc_smoke.nomu and runs it under NOMU_GC_SMOKE=1; the runtime walks the stack at
# the `sleep` statepoint and reports each recovered root's offset-8 field on stderr.
#
# Expected across two frames + two managed kinds (class + heap-boxed closure): 5 live roots — the
# class objects 111 (twice: a in main, x in inner), 222, 333 (each decoded by its offset-8 Int),
# plus the heap-boxed closure, whose offset 8 is its `fn` code pointer (6.1.3 header shift) so it is
# checked as a recovered root, not by value. The dead object 999 must NOT appear.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
"$NOMUC" "$ROOT/examples/gc_smoke.nomu" >/dev/null || { echo "FAIL: compile"; exit 1; }
out=$(NOMU_GC_SMOKE=1 "$ROOT/build/examples/gc_smoke" 2>&1 1>/dev/null)
echo "$out"

fail() { echo "FAIL: $1"; exit 1; }
vals=$(echo "$out" | grep -oE 'v=-?[0-9]+' | sed 's/v=//' | sort)
# Exactly 5 roots recovered (both frames, class + closure).
[[ $(echo "$vals" | grep -c .) -eq 5 ]] || fail "expected 5 roots, got: $(echo $vals)"
# Precision: the dead object must be excluded.
echo "$vals" | grep -qx 999 && fail "reported dead object 999 (not precise)"
# Coverage: the class roots decode to their Int — 111 seen in both frames, 222 and 333 once each.
[[ $(echo "$vals" | grep -cx 111) -eq 2 ]] || fail "expected class 111 twice (both frames)"
[[ $(echo "$vals" | grep -cx 222) -eq 1 ]] || fail "missing class root 222"
[[ $(echo "$vals" | grep -cx 333) -eq 1 ]] || fail "missing class root 333"
# The remaining root is the heap-boxed closure (offset 8 = its fn pointer, not a class value).
closure=$(echo "$vals" | grep -vxE '111|222|333')
[[ $(echo "$closure" | grep -c .) -eq 1 ]] || fail "expected exactly one closure root, got: $(echo $closure)"
echo "PASS: recovered the 5 live roots {111×2, 222, 333, closure} across 2 frames; dead 999 excluded"

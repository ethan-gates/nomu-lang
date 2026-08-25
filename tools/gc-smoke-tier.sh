#!/bin/zsh
# M7 · T4 — root-set introspection with the optimizer tier ON (§7.0.5). The strongest GC-precision
# oracle: assert the walker recovers the *exact* live-root set under ssair + escape analysis, so a
# dropped or spurious root is a failed assertion rather than silent, non-deterministic relocation
# corruption. Companion to tools/gc-smoke.sh (which pins EA OFF); this is the tier-ON refinement.
#
# Runs examples/gc_smoke.nomu under (EA on) + NOMU_GC_SMOKE=1; the runtime walks the
# stack at the `sleep` safepoint and reports each recovered root's offset-8 field on stderr.
#
# Expected: the EA-off 5-root set {111×2, 222, 333, closure} refines to **3 roots {111, 111, 444}**,
# every change individually licensed by escape analysis (the master property, pointwise):
#   - 111 (×2) stays — `a` escapes (passed into `inner`), so both its roots (main's `a`, inner's param
#     `x`) remain heap roots.
#   - 222 (`b`) and 333 (`c`) drop — non-escaping leaf `Box`es, stack-promoted then SROA-scalarized, so
#     they are no longer heap allocations and carry no managed field to root.
#   - the closure root shifts from the closure *object* (EA off: offset-8 = its `fn` code pointer) to
#     its heap **env** (offset-8 = the captured `k` = 444): the closure object is stack-promoted, so
#     its still-heap env becomes the tracked root.
#   - 999 (`dead`) stays absent — precision.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc

"$NOMUC" "$ROOT/examples/gc_smoke.nomu" >/dev/null || { echo "FAIL: compile"; exit 1; }
out=$(NOMU_GC_SMOKE=1 "$ROOT/build/examples/gc_smoke" 2>&1 1>/dev/null)
echo "$out"

fail() { echo "FAIL: $1"; exit 1; }
vals=$(echo "$out" | grep -oE 'v=-?[0-9]+' | sed 's/v=//' | sort)

# Exactly 3 roots — the tier-ON refinement of the 5-root EA-off set.
[[ $(echo "$vals" | grep -c .) -eq 3 ]] || fail "expected 3 roots (tier-on refinement), got: $(echo $vals)"
# The escaping object 111 survives in both frames (main's `a`, inner's param `x`).
[[ $(echo "$vals" | grep -cx 111) -eq 2 ]] || fail "expected escaping 111 twice (both frames), got: $(echo $vals)"
# The promoted leaf Boxes must be GONE (justified drops — not silently dropped *live* roots).
echo "$vals" | grep -qx 222 && fail "222 (b) still a heap root — should be stack-promoted away"
echo "$vals" | grep -qx 333 && fail "333 (c) still a heap root — should be stack-promoted away"
# Precision: the dead object stays excluded.
echo "$vals" | grep -qx 999 && fail "reported dead object 999 (not precise)"
# The third root is the promoted closure's heap env, decoding to the captured k=444.
env=$(echo "$vals" | grep -vx 111)
[[ $(echo "$env" | grep -c .) -eq 1 && "$env" == "444" ]] || fail "expected the closure env root (k=444), got: $(echo $env)"

echo "PASS: tier-on root set {111×2, env=444} — 222/333 promoted away, closure→env, dead 999 excluded (T4)"

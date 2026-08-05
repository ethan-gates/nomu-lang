#!/bin/zsh
# M6 · 6.2.2 parked-fiber smoke (Q8, the highest-risk item): prove the live-fiber registry + the
# parked-stack walk recover a *parked* fiber's exact live GC-root set from its saved `ucontext` — not
# from the running stack. Compiles examples/gc_smoke_parked.nomu and runs it under
# NOMU_GC_SMOKE_PARKED=1; `main`'s sleep safepoint waits for `worker` to park, then walks worker's
# saved context via the registry and reports each recovered root's offset-8 Int on stderr.
#
# Expected: exactly 2 roots — the class objects 111 and 222, both live across worker's park. The dead
# object 999 (last used before the park) must NOT appear. Normal run prints 999 then 333.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
"$NOMUC" "$ROOT/examples/gc_smoke_parked.nomu" >/dev/null || { echo "FAIL: compile"; exit 1; }
out=$(NOMU_GC_SMOKE_PARKED=1 "$ROOT/build/examples/gc_smoke_parked" 2>&1 1>/dev/null)
echo "$out"

fail() { echo "FAIL: $1"; exit 1; }
vals=$(echo "$out" | grep -oE 'v=-?[0-9]+' | sed 's/v=//' | sort)
# Exactly 2 roots recovered from the parked fiber.
[[ $(echo "$vals" | grep -c .) -eq 2 ]] || fail "expected 2 parked roots, got: $(echo $vals)"
# Precision: the dead object must be excluded.
echo "$vals" | grep -qx 999 && fail "reported dead object 999 (not precise)"
# Coverage: both live class roots recovered across the park.
echo "$vals" | grep -qx 111 || fail "missing parked root 111"
echo "$vals" | grep -qx 222 || fail "missing parked root 222"
echo "PASS: recovered the parked fiber's live set {111, 222} from its saved ucontext; dead 999 excluded"

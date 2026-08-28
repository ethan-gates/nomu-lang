#!/bin/zsh
# Task 150 · rung 2 — real-root discovery (the pcsp stack walk) feeding the mark-verify tracer, end to end
# and self-hosted. examples/walk_mark.nomu: rtCollectRoots walks the current stack via the pcsp route
# (parse __llvm_stackmaps, track SP, step by per-function frame size) to recover the live roots — here the
# handle of an Array<Box> held live across the walk — then hands each to the tracer, which marks the
# transitive live set (handle + buffer + 2 Boxes = 4) and folds an address-independent fingerprint.
# The fingerprint is identical across the two GC plans (MMTk and the self-hosted allocator, different
# address ranges): a stale or garbage root would fault or diverge, so matching fingerprints prove the walk
# recovered a real, correct root and the whole self-hosted chain — walk → tracer → fingerprint — is sound.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
fail() { echo "FAIL: $1"; exit 1; }

$NOMUC "$ROOT/examples/walk_mark.nomu" >/dev/null 2>&1 || fail "compile walk_mark"
fp_nogc=""
fp_nomu=""
for plan in nogc nomu; do
  got=$(NOMU_GC_PLAN=$plan "$ROOT/build/examples/walk_mark" 2>/dev/null) || fail "walk_mark under $plan nonzero exit"
  echo "$got" | grep -q '^nroots [1-9][0-9]* total 4$' || { echo "FAIL: walk_mark roots/total under $plan"; echo "$got"; exit 1; }
  fp=$(echo "$got" | grep '^FP ' | sed 's/^FP //')
  [[ -n "$fp" && "$fp" != "0" ]] || fail "walk_mark missing/trivial fingerprint under $plan"
  if [[ $plan == nogc ]]; then fp_nogc=$fp; else fp_nomu=$fp; fi
done
[[ "$fp_nogc" == "$fp_nomu" ]] || { echo "FAIL: walk_mark fingerprint differs across plans — a bad root leaked in ($fp_nogc vs $fp_nomu)"; exit 1; }
echo "PASS: self-hosted pcsp stack walk recovers real roots → tracer marks the live set (total 4) → address-independent fingerprint ($fp_nogc) identical across MMTk and self-hosted alloc"

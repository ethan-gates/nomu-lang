#!/bin/zsh
# Task 150 · rung 2 (mark-verify) increments 2–4 — the Nomu tracer marks the transitive live set from a
# seed root (no reclaim, no move) and emits an address-independent content fingerprint of that set.
#
# Two fixtures:
#   mark_verify      — a fixed-object graph: reachability, a shared child counted once (the header mark
#                      bit), and a dead heap object excluded. Live from root {root, leaf}: TOTAL 2.
#   mark_verify_arr  — a variable-size graph: seeding from an Array<Box> handle, the tracer follows the
#                      handle's bufptr into the kind=1 buffer and scans each element slot. TOTAL 5
#                      (handle + buffer + 3 Boxes) tests the array-scanning path.
#
# The fingerprint (per-object type-id + scalar field words, summed) excludes every pointer, so it is
# identical no matter where objects are allocated. Checking it equal across the two GC plans — MMTk and the
# self-hosted allocator, which use different address ranges — is a sharp test that no address leaked in,
# the precondition for the MMTk cross-run diff (next increment). The live-set oracle here is still each
# fixture's analytically-known set.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
fail() { echo "FAIL: $1"; exit 1; }

# check <fixture> <expected-head-lines>: run under both GC plans, assert the head matches and the
# address-independent fingerprint is non-trivial and identical across plans.
check() {
  local ex=$1 head=$2 nlines=$3
  $NOMUC "$ROOT/examples/$ex.nomu" >/dev/null 2>&1 || fail "compile $ex"
  local fp_nogc="" fp_nomu=""
  for plan in nogc nomu; do
    local got=$(NOMU_GC_PLAN=$plan "$ROOT/build/examples/$ex" 2>/dev/null)
    [[ $? -eq 0 ]] || fail "$ex under $plan nonzero exit"
    local gotHead=$(echo "$got" | head -$nlines)
    [[ "$gotHead" == "$head" ]] || { echo "FAIL: $ex live set under $plan"; echo "  expected: $(echo $head)"; echo "  got:      $(echo $gotHead)"; exit 1; }
    local fp=$(echo "$got" | grep '^FP ' | sed 's/^FP //')
    [[ -n "$fp" && "$fp" != "0" ]] || fail "$ex: missing/trivial fingerprint under $plan"
    if [[ $plan == nogc ]]; then fp_nogc=$fp; else fp_nomu=$fp; fi
  done
  [[ "$fp_nogc" == "$fp_nomu" ]] || { echo "FAIL: $ex fingerprint differs across GC plans — an address leaked in ($fp_nogc vs $fp_nomu)"; exit 1; }
  echo "  $ex: live set matches, fingerprint $fp_nogc identical across MMTk and self-hosted alloc"
}

check mark_verify $'99\nTOTAL 2\nLIVE 0 1\nLIVE 1 1' 4
check mark_verify_arr $'TOTAL 5\nLIVE 0 1\nLIVE 1 1\nLIVE 2 3' 4
echo "PASS: Nomu tracer marks the live set (fixed + array objects, shared child once, dead excluded) and emits an address-independent fingerprint identical across MMTk and self-hosted alloc"

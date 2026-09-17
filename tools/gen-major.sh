#!/bin/zsh
# Task 150 · rung 4 (GenImmix), increment 150.4.4 — minor/major interplay + trigger policy. A small nursery
# reserve fires frequent minor GCs; a mature-pressure floor (NOMU_MATURE_FLOOR) makes a nursery-full trigger
# escalate to a full defrag major once free mature blocks run low (rtImmixRefill → rtSelfhostOom → the STW
# coordinator runs the generational defrag major). A minor never reclaims dead mature objects, so promote-all
# leaks mature garbage every cycle and the major reclaims it — the two collectors interleave (selfhosted-gc.md
# §11.4). The major re-establishes the log-bit invariant (every survivor unlogged, freed regions logged), so a
# cross-generation pointer created AFTER a major still survives the next minor.
# Checks:
#   1. examples/gen_major.nomu compiles clean (prelude auto-subset, task 149).
#   2. Self-hosted minor+major collection is checksum-identical to the MMTk GenImmix oracle: 77 / 4242 / 94950.
#      The second store `h.item = Box(v: 77)` happens after majors have fired; if the post-major log bits were
#      wrong the young Box(77) (reachable only through mature `h`) would be dropped and the output would differ.
#   3. Both collection kinds actually fire (a run with only minors or only majors proves nothing about the
#      interplay). Confirmed via NOMU_GC_DEBUG_PRESSURE.
#   4. Deterministic across runs (the tiny reserve + floor fire collections on allocation count, not wall clock).
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/gen_major
fail() { echo "FAIL: $1"; exit 1; }

errs=$($NOMUC "$ROOT/examples/gen_major.nomu" 2>&1)
echo "$errs" | grep -qiE "error|runtime-subset function" && fail "gen_major not clean:\n$errs"

# MMTk GenImmix oracle (ignores the nursery/floor env; drives its own generational collection).
want=$(NOMU_GC_HEAP=8000000 "$BIN" 2>/dev/null)
[[ "$want" == "77
4242
94950" ]] || fail "MMTk GenImmix oracle output unexpected: '$(echo $want)'"

SELF="NOMU_RUNTIME=selfhost NOMU_GC_PLAN=nomu NOMU_SCHED=nomu NOMU_NURSERY_RESERVE=8 NOMU_MATURE_FLOOR=8176"

# Self-hosted minor+major interplay — the floor forces majors to interleave with minors.
got=$(env $(echo $SELF) NOMU_GC_DEBUG_PRESSURE=1 "$BIN" 2>/tmp/gen_major.err)
[[ "$got" == "$want" ]] || { cat /tmp/gen_major.err; fail "self-hosted interplay != MMTk oracle: got '$(echo $got)', want '$(echo $want)'"; }
nminor=$(grep -c "(minor)" /tmp/gen_major.err)
nmajor=$(grep -c "(major)" /tmp/gen_major.err)
[[ $nminor -ge 10 ]] || { cat /tmp/gen_major.err; fail "only $nminor minor GC(s) — the nursery-full trigger is not driving minors"; }
[[ $nmajor -ge 2 ]]  || { cat /tmp/gen_major.err; fail "only $nmajor major GC(s) — the mature-pressure floor is not escalating to a major"; }

# Deterministic across runs (single-carrier STW on allocation count).
for i in 1 2 3 4 5; do
  g=$(env $(echo $SELF) "$BIN" 2>/dev/null)
  [[ "$g" == "$want" ]] || fail "non-deterministic across runs: run $i got '$(echo $g)'"
done
echo "PASS: minor/major interplay (150.4.4) — nursery-full drives $nminor minor GCs; mature pressure escalates to $nmajor major GCs that reclaim mature garbage and re-arm the log bits; a post-major cross-generation pointer survives, checksum-identical to MMTk GenImmix"

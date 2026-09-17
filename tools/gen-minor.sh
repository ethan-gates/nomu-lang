#!/bin/zsh
# Task 150 · rung 4 (GenImmix), increment 150.4.3 — minor (generational) collection. The nursery fills to its
# reserve and a minor GC fires at the STW: the nursery is promoted into mature Immix using the stack roots plus
# the drained write-barrier remembered set (selfhosted-gc.md §11.4). The mature space is never scanned, so a
# mature→young pointer (created after promotion) survives only because the barrier remembered it and the minor
# GC drained the remembered set — the generational-correctness proof.
# Checks:
#   1. examples/gen_minor.nomu compiles clean (prelude auto-subset, task 149).
#   2. Self-hosted minor collection is checksum-identical to the MMTk GenImmix oracle: both print 42 / 4242.
#      Without the remembered set the young Box (reachable only from mature `h`) would be lost → wrong output.
#   3. Deterministic across runs (the tiny nursery reserve fires minor GCs on allocation count, not wall clock).
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/gen_minor
fail() { echo "FAIL: $1"; exit 1; }

errs=$($NOMUC "$ROOT/examples/gen_minor.nomu" 2>&1)
echo "$errs" | grep -qiE "error|runtime-subset function" && fail "gen_minor not clean:\n$errs"

# MMTk GenImmix oracle (ignores NOMU_NURSERY_RESERVE; drives its own generational collection).
want=$(NOMU_GC_HEAP=4000000 "$BIN" 2>/dev/null)
[[ "$want" == "42
4242
94950" ]] || fail "MMTk GenImmix oracle output unexpected: '$(echo $want)'"

# Self-hosted minor collection — a tiny nursery reserve forces frequent, deterministic minor GCs.
got=$(NOMU_RUNTIME=selfhost NOMU_GC_PLAN=nomu NOMU_SCHED=nomu NOMU_NURSERY_RESERVE=8 "$BIN" 2>/dev/null)
[[ "$got" == "$want" ]] || fail "self-hosted minor != MMTk oracle: got '$(echo $got)', want '$(echo $want)'"
for i in 1 2 3 4 5; do
  g=$(NOMU_RUNTIME=selfhost NOMU_GC_PLAN=nomu NOMU_SCHED=nomu NOMU_NURSERY_RESERVE=8 "$BIN" 2>/dev/null)
  [[ "$g" == "$want" ]] || fail "non-deterministic across runs: run $i got '$(echo $g)'"
done
echo "PASS: minor collection (150.4.3) — nursery-full STW promotes the nursery via stack roots + drained remembered set; cross-generation young object survives, checksum-identical to MMTk GenImmix"

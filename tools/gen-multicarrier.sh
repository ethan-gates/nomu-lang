#!/bin/zsh
# Task 150 · rung 4 (GenImmix), increment 150.4.5.2 — multi-carrier remembered-set correctness. The full
# generational collector (nursery-full → minor, mature-pressure/OOM → major) run under 1/2/4/8 carriers with
# the trigger forced on (NOMU_NURSERY_RESERVE). Each carrier owns a write-barrier mod-buffer; the STW
# coordinator drains every carrier's buffer as the minor GC's remembered set, so a mature→young pointer created
# on any carrier survives. The per-carrier mod-buffer append is lock-free (each carrier writes only its own
# buffer); the log-bit clear is conservative under races (a lost clear only keeps an object remembered-eligible,
# and a remembered object is rescanned in full regardless of which carrier logged it), so no store's remembering
# is lost.
# Checks:
#   1. gc_actor_mc: 2000 actors' queued messages survive frequent minors on N carriers. Correctness is
#      self-checked inside each actor (report prints only on a WRONG sum), so the pass condition is EMPTY
#      output — robust to the stdout interleaving that multiple carriers' concurrent `print`s produce (the
#      per-actor prints in gc_actor garble line structure under >1 carrier, an output artifact, not a GC fault).
#   2. gc_concurrent: four fibers over-allocating 384 MiB on a 256 MiB heap survive, output-identical to MMTk
#      (a single reduced checksum, interleaving-safe).
#   3. gc_anybox / gc_string: single-fiber object-type fixtures correct with extra idle carriers.
# All under NOMU_GC_PLAN=nomu + NOMU_SCHED=nomu. Deterministic across runs (allocation-count triggers).
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
ITERS=${GEN_MC_ITERS:-3}
fail() { echo "FAIL: $1"; exit 1; }
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 120; waitpid($p,0); exit($?>>8)' "$@"; }

for f in gc_actor_mc gc_concurrent gc_anybox gc_string; do
  "$NOMUC" "$ROOT/examples/$f.nomu" >/dev/null 2>&1 || fail "compile $f"
done

# Oracles (MMTk NoGC / GenImmix, no GC knob) — computed with a clean env before the self-hosted vars are set.
# gc_actor_mc under the oracle must also self-check clean (empty output).
[[ -z "$(run "$ROOT/build/examples/gc_actor_mc" 2>/dev/null)" ]] || fail "gc_actor_mc oracle reported a wrong sum"
conc_want=$(run "$ROOT/build/examples/gc_concurrent" 2>/dev/null)
anybox_want=$(run "$ROOT/build/examples/gc_anybox" 2>/dev/null)
string_want=$(run "$ROOT/build/examples/gc_string" 2>/dev/null)

# The constant generational-plan env (only NOMU_CARRIERS varies per run, as a literal prefix below). Exported
# rather than passed via `env`, which cannot invoke the `run` shell function.
export NOMU_RUNTIME=selfhost NOMU_GC_PLAN=nomu NOMU_SCHED=nomu NOMU_NURSERY_RESERVE=64

for c in 1 2 4 8; do
  for i in $(seq 1 $ITERS); do
    a=$(NOMU_CARRIERS=$c run "$ROOT/build/examples/gc_actor_mc" 2>/dev/null)
    [[ -z "$a" ]] || fail "gc_actor_mc carriers=$c run $i: an actor's sum was wrong — a cross-generation message was lost: $(echo "$a" | head -1)"
    g=$(NOMU_CARRIERS=$c run "$ROOT/build/examples/gc_concurrent" 2>/dev/null)
    [[ "$g" == "$conc_want" ]] || fail "gc_concurrent carriers=$c run $i: '$g' != oracle '$conc_want'"
  done
done

# Single-fiber object-type fixtures with idle extra carriers.
for c in 2 4; do
  [[ "$(NOMU_CARRIERS=$c run "$ROOT/build/examples/gc_anybox" 2>/dev/null)" == "$anybox_want" ]] || fail "gc_anybox carriers=$c != '$anybox_want'"
  [[ "$(NOMU_CARRIERS=$c run "$ROOT/build/examples/gc_string" 2>/dev/null)" == "$string_want" ]] || fail "gc_string carriers=$c != '$string_want'"
done

echo "PASS: multi-carrier remembered-set correctness (150.4.5.2) — the generational collector runs the actor (self-checked) + concurrent + object-type fixtures at 1/2/4/8 carriers under NOMU_NURSERY_RESERVE, every carrier's remembered set drained at the minor STW, no cross-generation message lost across $ITERS runs each"

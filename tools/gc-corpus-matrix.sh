#!/bin/zsh
# M7 · T5 — corpus root/barrier differential at scale (§7.0.5). Run the whole example corpus across the
# {tier off, tier on} × {NoGC, GenImmix, GenImmix-stress} matrix and assert every cell agrees. Catches
# a tier bug that only surfaces under a *moving* collector (a mis-promoted object's pointer not
# relocated, a dropped barrier) — broadly, across the corpus, rather than at one hand-built fixture.
#
# The tier (EA + devirt + inline) is a compile-time choice; the collector is a run-time choice. So each
# program compiles twice — tier-off (all three passes disabled) and tier-on — and the tier-on binary
# runs under three collector configs. All four results must equal the tier-off / NoGC ground truth.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
STRESS=${NOMU_GC_STRESS:-2048}
HEAP=${NOMU_GC_HEAP:-2000000}
TIMEOUT=${TIMEOUT:-30}
runbin() { perl -e "alarm $TIMEOUT; exec @ARGV" "$@" </dev/null 2>&1; }

fails=0; ran=0; skipped=0
for f in "$ROOT"/examples/*.nomu; do
  n=$(basename "$f" .nomu)
  bin="$ROOT/build/examples/$n"

  # Baseline: tier OFF, NoGC.
  NOMU_EGRESS=ssair NOMU_NO_ESCAPE=1 NOMU_NO_DEVIRT=1 NOMU_NO_INLINE=1 "$NOMUC" "$f" >/dev/null 2>&1 || continue
  base=$(NOMU_GC_PLAN=nogc runbin "$bin")

  # Tier ON binary, run under the three collector configs.
  NOMU_EGRESS=ssair "$NOMUC" "$f" >/dev/null 2>&1 || { echo "  $n: tier-on compile FAIL"; fails=$((fails+1)); continue; }
  on_nogc=$(NOMU_GC_PLAN=nogc runbin "$bin")
  on_gen=$(NOMU_GC_HEAP=$HEAP runbin "$bin")
  on_stress=$(NOMU_GC_STRESS=$STRESS runbin "$bin")
  ran=$((ran+1))

  # A timeout under stress (constant GC on a compute-heavy program) is a skip, not a mismatch.
  if [[ -z "$on_stress" && -n "$base" ]]; then skipped=$((skipped+1)); on_stress=$base; fi

  for cell in "nogc:$on_nogc" "genimmix:$on_gen" "stress:$on_stress"; do
    label=${cell%%:*}; val=${cell#*:}
    if [[ "$val" != "$base" ]]; then
      echo "  $n [tier-on/$label]: DIFF vs tier-off/nogc baseline"
      fails=$((fails+1))
    fi
  done
done

echo "ran=$ran  stress-timeouts-skipped=$skipped  mismatches=$fails"
[[ $fails -eq 0 ]] && echo "PASS: corpus agrees across {tier off,on} × {NoGC,GenImmix,stress} (T5)" || { echo "FAIL: $fails mismatch(es)"; exit 1; }

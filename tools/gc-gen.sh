#!/bin/zsh
# M6 · 6.3.1 generational write-barrier test. Compiles examples/gc_gen.nomu and runs it under many
# real nursery GCs (NOMU_GC_HEAP shrinks the heap so allocation drives collection). A mature object is
# mutated to point at a freshly-allocated (nursery) object; the write barrier must remember the mature
# object so the young reference survives the following nursery collections. Output matching the NoGC
# baseline proves the barrier tracks post-promotion cross-generation stores and relocates the young
# objects. This is the generational counterpart to gc-stress.sh (Immix evacuation).
#
# Expected (both runs): 42 then 4242.
set -u
# 6.5.2: pin escape analysis off so leaf heap roots this collector test relies on are not stack-promoted.
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/gc_gen
# A modest fixed heap: the fixture allocates ~6 MB of Boxes over its two churn loops, so a 2 MB heap
# forces several real nursery GCs (promotion + the barriered store + relocation) — comfortably above
# MMTk's viable-heap floor (sub-megabyte heaps livelock in page accounting; see m6-spec.md 6.3).
HEAP=${NOMU_GC_HEAP:-2000000}

"$NOMUC" "$ROOT/examples/gc_gen.nomu" >/dev/null || { echo "FAIL: compile"; exit 1; }

base=$(NOMU_GC_PLAN=nogc "$BIN" 2>/dev/null)
gen=$(NOMU_GC_HEAP=$HEAP "$BIN" 2>/dev/null)
rc=$?

fail() { echo "FAIL: $1"; echo "  baseline: $(echo $base)"; echo "  genimmix: $(echo $gen)"; exit 1; }
[[ $rc -eq 0 ]] || fail "genimmix run exited $rc"
[[ "$base" == "42
4242" ]] || fail "baseline output unexpected"
[[ "$gen" == "$base" ]] || fail "genimmix output differs from baseline (write-barrier bug)"
echo "PASS: gc_gen byte-identical under NoGC and GenImmix (heap=$HEAP) — post-promotion cross-generation store remembered + relocated"

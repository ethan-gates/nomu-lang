#!/bin/zsh
# Task 150 · rung 1 slice B — the self-hosted allocator as a selectable plan. Under NOMU_GC_PLAN=nomu the
# codegen alloc seam routes every managed allocation at the Nomu bump allocator (runtime prelude), producing
# the addrspace(1) object via ptrtoint->inttoptr; MMTk is initialized NoGC and idle as the diff oracle.
# The check is the differential: the same program under NOMU_GC_PLAN=nogc (MMTk) and NOMU_GC_PLAN=nomu
# (self-hosted) must produce byte-identical output. Fixtures span class objects, closures, arrays, and a
# heavy allocation loop.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
fail() { echo "FAIL: $1"; exit 1; }

fixtures=(selfhost_gc gc_smoke arr_gc gc_stress)
for ex in $fixtures; do
  $NOMUC "$ROOT/examples/$ex.nomu" >/dev/null 2>&1 || fail "compile $ex"
  base=$(NOMU_GC_PLAN=nogc "$ROOT/build/examples/$ex" 2>/dev/null)
  self=$(NOMU_GC_PLAN=nomu "$ROOT/build/examples/$ex" 2>/dev/null)
  rc=$?
  [[ $rc -eq 0 ]] || fail "$ex under self-hosted plan exited $rc"
  [[ -n "$base" ]] || fail "$ex produced no baseline output"
  [[ "$self" == "$base" ]] || { echo "FAIL: $ex differs"; echo "  nogc: $(echo $base)"; echo "  nomu: $(echo $self)"; exit 1; }
done
echo "PASS: self-hosted allocator (NOMU_GC_PLAN=nomu) byte-identical to MMTk NoGC across ${#fixtures} fixtures (classes, closures, arrays, heavy alloc) — managed objects handed out by the Nomu allocator via ptrtoint->inttoptr"

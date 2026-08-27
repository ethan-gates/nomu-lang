#!/bin/zsh
# Task 125 · slice 2 — Ptr<T> typed pointer. Compiles examples/typed_ptr.nomu (typed element access at
# natural stride, advanced by whole elements, RawPtr<->Ptr<T> reinterpret, a packed Ptr<UInt8>) and
# checks its output. A second leg runs under the moving collector: Ptr<T> is unmanaged addrspace(0)
# memory the collector never relocates, so output must be byte-identical.
#
# Expected (both legs): 10 / 20 / 30 / 30 / 7.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/typed_ptr
STRESS=${NOMU_GC_STRESS:-512}

"$NOMUC" "$ROOT/examples/typed_ptr.nomu" >/dev/null || { echo "FAIL: compile"; exit 1; }

want="10
20
30
30
7"
base=$(NOMU_GC_PLAN=nogc "$BIN" 2>/dev/null)
evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null)
rc=$?

fail() { echo "FAIL: $1"; echo "  want: $(echo $want)"; echo "  base: $(echo $base)"; echo "  evac: $(echo $evac)"; exit 1; }
[[ $rc -eq 0 ]] || fail "moving-collector run exited $rc"
[[ "$base" == "$want" ]] || fail "baseline output unexpected"
[[ "$evac" == "$base" ]] || fail "output differs under the moving collector (typed pointer should be untouched by GC)"
echo "PASS: Ptr<T> typed access (alloc/load/store/advanced/asRaw/free, natural stride) — byte-identical under NoGC and Immix-evacuation (stress=$STRESS)"

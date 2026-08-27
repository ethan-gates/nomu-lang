#!/bin/zsh
# Task 150 · rung 2 (mark-verify) increment 1 — side-table reachability from Nomu. The Nomu tracer must
# read the codegen-emitted per-type-id side tables (object size + managed-pointer map, c-types.md §1/§3.2).
# examples/mark_types.nomu dumps those tables via the RawPtr.gcType* accessors (pure gc-leaf reads that
# reach the same tables the MMTk binding reads — no new runtime C). The check is the differential: that
# Nomu-side dump (stdout, "TYPE id size nptr off…") must match the C-side NOMU_GC_TYPEMAPS dump (stderr),
# since both read the same tables in one process.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
fail() { echo "FAIL: $1"; exit 1; }

$NOMUC "$ROOT/examples/mark_types.nomu" >/dev/null 2>&1 || fail "compile mark_types"

out=$(NOMU_GC_TYPEMAPS=1 "$ROOT/build/examples/mark_types" 2>/tmp/mark_types.cdump)
rc=$?
[[ $rc -eq 0 ]] || fail "mark_types exited $rc"

# Nomu dump: strip the "TYPE " prefix, trim trailing space → "id size nptr off…".
nomu=$(echo "$out" | grep '^TYPE ' | sed -E 's/^TYPE //' | sed -E 's/ +$//')
# C dump: "  type <id>: <size> bytes, <n> managed [<offs>]" → "id size nptr offs".
cdump=$(grep '^  type ' /tmp/mark_types.cdump \
  | sed -E 's/^  type ([0-9]+): ([0-9]+) bytes, ([0-9]+) managed \[(.*)\]/\1 \2 \3 \4/' \
  | sed -E 's/ +$//')

[[ -n "$nomu" ]] || fail "Nomu produced no type dump"
[[ -n "$cdump" ]] || fail "C produced no type dump"
if [[ "$nomu" != "$cdump" ]]; then
  echo "FAIL: Nomu type-table reads differ from the C tables"
  echo "  nomu:"; echo "$nomu" | sed 's/^/    /'
  echo "  c:";    echo "$cdump" | sed 's/^/    /'
  exit 1
fi

ntypes=$(echo "$nomu" | wc -l | tr -d ' ')
echo "PASS: Nomu reads the codegen type tables byte-identical to the C side across $ntypes type-ids (size + managed-pointer map) — side-table reachability, no new runtime C"

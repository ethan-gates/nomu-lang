#!/bin/zsh
# Task 150 · rung 2 (pcsp root walk) — reach and parse the `__llvm_stackmaps` (v3) section from Nomu,
# libc-free. Section base+size come through the linker section-bracket symbols (RawPtr.gcStackmapBase /
# gcStackmapSize) — no getsectiondata, no libc, no new runtime C. examples/stackmap_probe.nomu then parses
# the whole structure in Nomu and self-checks: the version byte is 3, and stepping every variable-length
# record lands the cursor exactly on the section size (PARSE-OK) — validating the record-size arithmetic
# with no external oracle. This is the parsing foundation for the pcsp stack walk (real roots) next.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
fail() { echo "FAIL: $1"; exit 1; }

$NOMUC "$ROOT/examples/stackmap_probe.nomu" >/dev/null 2>&1 || fail "compile stackmap_probe"
out=$("$ROOT/build/examples/stackmap_probe" 2>/dev/null) || fail "stackmap_probe nonzero exit"

echo "$out" | grep -q '^version 3$'   || { echo "FAIL: stackmap version not 3"; echo "$out"; exit 1; }
echo "$out" | grep -q '^PARSE-OK$'    || { echo "FAIL: parser did not land on section size"; echo "$out"; exit 1; }
nrecs=$(echo "$out" | grep '^nrecs ' | sed 's/^nrecs //')
[[ -n "$nrecs" && "$nrecs" -gt 0 ]]  || fail "no statepoint records parsed"
echo "PASS: Nomu reaches __llvm_stackmaps libc-free (linker section symbols) and parses all $nrecs v3 records — cursor lands exactly on the section size (structural self-check)"

#!/bin/sh
# Task 243, claim 1: does the statepoint rewrite accept stack addresses as tracked values, and what do the
# arm64 code and its stack-map record do with them? Needs the pinned LLVM's tools:
#   bazel build -c opt @llvm-project//llvm:opt @llvm-project//llvm:llc @llvm-project//llvm:llvm-readobj
# Case a2 is a with its opaque call replaced by the cast it stands for, after the rewrite.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
bin="$root/bazel-out/darwin_arm64-opt/bin/external/+llvm_configure+llvm-project/llvm"
out=$(mktemp -d)
for c in a_call b_inttoptr c_alloca1 d_derived; do
  echo "== $c"
  if ! "$bin/opt" -passes=rewrite-statepoints-for-gc -S "$here/$c.ll" -o "$out/$c.rs.ll" 2>/dev/null; then
    echo "rewrite-statepoints-for-gc failed"; continue
  fi
  if [ "$c" = a_call ]; then
    sed -E 's/%p = call ptr addrspace\(1\) @nomu.frame.addr\(ptr %slot\)( #[0-9]+)?/%p = addrspacecast ptr %slot to ptr addrspace(1)/' \
      "$out/$c.rs.ll" > "$out/a2_cast.rs.ll"
  fi
done
for c in a_call a2_cast b_inttoptr d_derived; do
  [ -f "$out/$c.rs.ll" ] || continue
  echo "== $c: code around the stop, then the records"
  "$bin/llc" -O2 "$out/$c.rs.ll" -o - | awk '/^_f:/{p=1} p&&/^Lfunc_end/{exit} p' | grep -v -E '^\s*(\.cfi|;)'
  "$bin/llc" -O2 -filetype=obj "$out/$c.rs.ll" -o "$out/$c.o"
  "$bin/llvm-readobj" --stackmap "$out/$c.o" | grep -E 'Record|#[0-9]+:'
done
rm -rf "$out"

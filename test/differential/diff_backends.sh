#!/usr/bin/env bash
# M8.1 · 8.1.5 — the differential-harness seed. Compile each program with both backends and
# assert identical stdout + exit. The C backend is the oracle; this guards that the LLVM path
# stays behavior-equivalent as 8.2 grows it. Extend by adding .nomu files to the sh_test's args.
#
# Usage: diff_backends.sh <nomuc> <prog1.nomu> [prog2.nomu ...]
set -euo pipefail

nomuc="$1"; shift

# A private, writable workspace: nomuc emits build artifacts next to the source, so we copy each
# program somewhere writable (the runfiles tree is read-only).
work="${TEST_TMPDIR:-$(mktemp -d)}/diff"
mkdir -p "$work"

# Compile `$1` with backend `$2`, run the binary, and echo "<exit>\n<stdout>".
build_and_run() {
    local src="$1" backend="$2" bin out rc
    bin="$("$nomuc" --backend="$backend" "$src")"
    set +e; out="$("$bin")"; rc=$?; set -e
    printf '%s\n%s' "$rc" "$out"
}

status=0
for prog in "$@"; do
    name="$(basename "$prog")"
    src="$work/$name"
    cp "$prog" "$src"

    llvm="$(build_and_run "$src" llvm)"
    c="$(build_and_run "$src" c)"

    if [ "$llvm" = "$c" ]; then
        echo "ok: $name — llvm and c agree (exit+stdout)"
    else
        echo "FAIL: $name — backends differ" >&2
        echo "  llvm: $llvm" >&2
        echo "  c:    $c" >&2
        status=1
    fi
done
exit "$status"

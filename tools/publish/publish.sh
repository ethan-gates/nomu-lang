#!/bin/bash
# Keeps the `nomu` Bazel just built as a toolchain snapshot: `tools/snapshot.py publish`, run in the workspace,
# given the binary. Bazel passes the binary's runfiles path first; the rest are the caller's arguments.
set -euo pipefail
if [ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
  echo "publish: run it as \`bazel run -c opt //:publish -- [--label NAME] [--memo TEXT]\`" >&2
  exit 1
fi
rel=$1
shift
bin=""
for c in "$PWD/$rel" "${RUNFILES_DIR:-}/_main/$rel" "${RUNFILES_DIR:-}/$rel"; do
  if [ -f "$c" ]; then bin=$c; break; fi
done
if [ -z "$bin" ]; then
  echo "publish: could not find the nomu binary ($rel) in the runfiles" >&2
  exit 1
fi
cd "$BUILD_WORKSPACE_DIRECTORY"
exec python3 tools/snapshot.py publish --binary "$bin" "$@"

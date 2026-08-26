# MLIR consideration

**Avenue:** Infra · **Type/Lifecycle:** `refactor · evaluate` · **Size:** S (the evaluation) ·
**Status:** ongoing consideration · **Source:** `backend.md` (MLIR vs. plain LLVM)

## What

Evaluate whether MLIR belongs in the backend stack — as an alternative or complement to the current
SSAIR → LLVM path. A standing consideration, not a committed
direction.

## Notes

SSAIR (M7) is now the sole backend egress and covers the language-aware optimization tier LLVM can't
supply. An MLIR evaluation would weigh whether its dialect infrastructure earns its keep over the
hand-rolled SSAIR, given the tier already exists.

## Refs

`backend.md` (MLIR vs. plain LLVM); `ssair.md`.

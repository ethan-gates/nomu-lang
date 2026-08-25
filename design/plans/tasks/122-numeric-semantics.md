# Numeric semantics + overflow

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** M ·
**Status:** needs-design (high-stakes, permanent contract) · **Source:** deferred.md (stdlib track)

## What

The numeric-type contract — a high-stakes decision pulled out of the [stdlib track](120-stdlib-core.md):
- fixed-width integer types (`Int` / `Int8…64` / `UInt*`),
- **overflow behavior** — trap-in-debug / wrap-in-release (Swift), always-checked, or always-wrap,
- `Float` / `Double`,
- conversions (`.double` / `.int` exist, `double_core.nomu`).

## Current state

Arithmetic is raw wrapping today (no panics), decided 2026-08-20 for the operator surface. Whether
that becomes the permanent policy or shifts to trap-in-debug is the open contract.

## Why consequential

Overflow policy is a safety + perf contract. Numbers are largely self-contained once overflow policy
is set.

## Roadmap assessment

Call out **numeric overflow** as its own high-stakes decision inside the stdlib track — it sets a
permanent contract.

## Refs

deferred.md "Standard library" (numeric sub-decision); [operator surface](113-operator-surface.md)
(wrapping decision, 2026-08-20); `double_core.nomu`.

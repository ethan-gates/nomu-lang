# Author the `language/` contract tier

**Avenue:** Infra (docs) · **Type/Lifecycle:** `refactor · in-progress` · **Size:** M ·
**Status:** in-progress (folder + readme exist; per-subsystem docs unwritten) · **Source:** deferred.md
(2026-08-03)

## What

Distill the programmer-facing **contract** — what the language *guarantees to the programmer* (syntax,
semantics, the contracts a Nomu author can rely on, no implementation detail) — up out of `internals/`
into `design/language/`. The `internals/` doc stays as as-built detail; `language/` is the short intent
layer above it.

## Status (2026-08-25)

The `language/` tier exists (folder + readme with the standing-task list + the start order);
`internals/` and `plans/` are split out. Only `language/readme.md` is authored — the per-subsystem
contract docs are unwritten.

## Why deferred

The design docs churn while subsystems are still landing; extracting a stable contract for a moving
surface tracks a moving target. Each subsystem's contract pays off once *that* subsystem settles.

## Trigger / order

Author per-subsystem, settled surfaces first (list in `design/language/readme.md`): syntax → types →
generics + interfaces → concurrency. For a settled subsystem, lift the guarantees out of its
`internals/` doc into a `language/` doc, leave the internals doc as detail, cross-reference. Close this
item once the settled subsystems are covered.

## Refs

deferred.md "Docs reorganization: author the `language/` contract tier"; `design/language/readme.md`;
`design/readme.md` (layout model).

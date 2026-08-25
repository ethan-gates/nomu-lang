# `shared` function-type / existential spellings

**Avenue:** Infra · **Type/Lifecycle:** `language-feature · ready-to-build` (trigger-gated) ·
**Size:** S · **Status:** ready-to-build, parked on a trigger · **Source:** deferred.md

## What

The explicit `shared (A) -> B` (shareable closure/function type) and `shared any I` (shareable
existential) spellings (`generics.md` §2). The `<shared T>` *bound* shipped in M5 (`generics.md` §7);
these two spellings did not.

## Why deferred (decided 2026-07-28)

No consumer in M5. Shareability is auto-derived structurally (`generics.md` §7), so no annotation is
needed for the common case. The explicit marker is only required on a **closure/generic parameter
forwarded to a task where the forwarding body is hidden from the caller** (`concurrency.md` §5). Those
hidden-body boundaries are **interface method requirements** and, later, **module boundaries** —
neither exercised for closure-forwarding under M5's single compilation unit. Building it now means
threading the capability through `Type` (~27 switch sites + assignability rules) with nothing to
exercise it.

## Trigger to build

An interface requirement needs to forward a closure to a task (so its signature must spell
`shared (A) -> B`), or **[modules](100-modules.md)** land (hidden bodies across the boundary).

## How to build then

Param-focused and sound, mirroring 5.3.2: parse the spelling, record param shared-ness in the
signature, discharge at call sites (arg closure's captures shareable / arg value's type shareable),
treat a `shared` param as shareable in-body via name-tracking (`Sema.sharedParams`). A full
`Type`-model change is optional, needed only if shared-ness must flow through fields/returns.

## Ergonomic alternative (separate item)

Bottom-up **inference** of a closure param's shareability from a visible body (`concurrency.md` §5,
"inferred bottom-up" — a *Leaning* item) keeps `shared` unwritten for ordinary functions. Larger
analysis; independent of the spelling.

## Refs

`generics.md` §2, §10; `concurrency.md` §5; `interfaces.md` §8; [modules](100-modules.md).

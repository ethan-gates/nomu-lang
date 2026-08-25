# Copy-on-write for value collections

**Avenue:** Usability (+ GC architecture) · **Type/Lifecycle:** `language-feature · needs-design`
(memory model + stdlib + backend) · **Size:** M · **Status:** needs-design · **Source:** deferred.md
(2026-08-18)

## What

Whether value-semantic collections (`Array`, the map, `Set`, `String`) are copy-on-write: a mutation
on a uniquely-referenced buffer happens in place; a mutation on a shared buffer copies first. Swift's
model. Requires a uniqueness check at mutation points.

## Why consequential

It's a **cost-model contract** programmers tune against — passing a big array by value stays cheap
until a shared one is mutated. It shapes how value semantics is implemented across the whole stdlib,
and it **couples with the GC**: the uniqueness check wants a reference count, which a tracing/moving
collector does not maintain — so CoW needs a side count on the buffer or a different uniqueness
mechanism. That coupling is the architectural piece.

## Interactions

The value/reference split (`memory-model.md` §2), the GC (uniqueness without RC), and every value
collection in the stdlib. Ties to [String/UTF-8](121-string-utf8-model.md) (String is a value type).

## Roadmap assessment (three-head)

**Yes.** Perf envelope (copy cost model) + programmer expectations (value-semantics contract) +
architecture (uniqueness under a tracing GC). One of the more consequential items.

## Refs

deferred.md "Copy-on-write for value collections"; `memory-model.md` §2 (value/reference split), §3
(GC object model).

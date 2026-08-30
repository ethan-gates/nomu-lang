# `init` — custom initializers

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** M ·
**Status:** needs-design · **Source:** deferred.md (2026-08-18 surface batch)

## What

Custom initializers beyond today's synthesized memberwise `T(field:)`. Opens:
- init-body validation / normalization,
- multiple inits + overload resolution,
- failable init (`init?` → `Option`/`Result`),
- designated-vs-convenience (if any),
- default field values.

## Why deferred

The memberwise-only form is a placeholder that works for now; custom init reshapes the construction
contract and was parked for a dedicated design pass.

## Shipped: static-method factories (the lighter path)

`static fun new() -> MyType { … }` is built and covers named/validated construction without touching
the init contract. A static method is a type-associated function with no `self` (referencing `self` or
a field is an undefined-name error). It builds a value through the existing memberwise construct and
returns it, so it needs no definite-initialization analysis — the reason full `init` is design-heavy.

- **Syntax:** `static fun` (new `static` keyword) in struct/enum/class bodies. Called `MyType.method(…)`;
  not callable on a value. Instance methods stay callable only on a value.
- **Implementation:** lowers to a free function named `MyType.method` (unspellable by users, so no
  collision), riding the whole SSAIR→LLVM free-function path with no new codegen. Routing added in
  `Sema.checkCall`; static/instance separation enforced in `methodDecl`/`staticMethodDecl`.
- **Not covered (still this task):** failable init, default field values, memberwise suppression, and the
  definite-initialization analysis a real `init` body needs. Generic types reject all members (including
  `static fun`), unchanged. Extensions don't yet accept `static fun`.

## Roadmap assessment (three-head)

**One-liner pointer.** Reshapes the construction contract (programmer-expectation) but rides the
existing type-system track. The memberwise-only form is provisional.

## Dependencies & triggers

Rides the type-system track. Interacts with [default arguments](112-param-labels-args.md) (default field
values ~ default args) and [error handling](115-error-handling.md) (`init?` → `Option`/`Result`).

## Refs

`types.md` (construction), deferred.md "User-level language surface".

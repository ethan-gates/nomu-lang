# First-class functions & closures for user code

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** L · **Status:**
deferred — wanted, but explicitly **not** built during the self-hosting story · **Source:** distilled
during [128](128-self-hosting-runtime.md) 128.1.2 (the function-address co-design).

## What

Full first-class functions and closures as values in the *user* surface: a function type spelling,
function values that can be passed, stored, and called, and closures that capture their environment.

## Why it is filed here (and deferred)

Self-hosting the scheduler needed to hand an entry point to the asm floor and to `pthread_create`. That
need was met by a **runtime-tier primitive** — `RawPtr.ofFunc(f)`, the bare C-ABI code address of a
top-level non-capturing `fun (_: RawPtr) -> RawPtr`, distinct from any user-facing function value
(`internals/selfhosted-scheduler.md` §2). The primitive claims no user-facing surface, so building the
real feature later is unconstrained by it — a genuine `fn(...) -> ...` type (and closures) can subsume or
replace `ofFunc`'s role without breaking anything.

Decision (with Ethan): user-facing first-class functions/closures are wanted eventually, but are a
separate, deliberate language step — not scaffolding to be rushed in under self-hosting.

## Design axes (to settle when built)

- **Function-type spelling** — `fn(A, B) -> C` or another form (new type syntax; syntax/keyword sign-off).
- **Non-capturing vs capturing** — a non-capturing function is ABI-identical to a bare code pointer; a
  closure is a boxed `(code, env)` pair. Whether these are one type with a representation split or two.
- **Interaction with the runtime primitive** — whether `RawPtr.ofFunc` becomes sugar over the non-capturing
  case, or stays a separate runtime-only spelling.
- **Escape / lifetime** — capturing closures interact with the memory model (`memory-model.md`).

## Refs

`internals/selfhosted-scheduler.md` §2 (the `ofFunc` runtime primitive and the deferral note);
[128 self-hosting](128-self-hosting-runtime.md).

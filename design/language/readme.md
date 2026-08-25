# Language — the contract layer

**What Nomu guarantees and aims for**, written for the programmer — and for an LLM or dev who
needs the *intent* fast. Short and distilled; the source of the eventual public docs.

Each doc says what a Nomu author can rely on — syntax, semantics, guarantees — with **no
implementation detail**. For *how it's built*, see [`../internals/`](../internals/readme.md); for
exact behavior, the code. Status tags (Decided / Leaning / Deferred / Open) mark committed
guarantees vs. intended direction.

Authored incrementally, distilled from the detailed `../internals/` docs.

## Standing task — author this tier

This folder holds only this readme so far. As subsystems settle, distill their programmer-facing
contract up out of `../internals/` into a doc here (leaving the internals doc as the as-built
detail). Start where the extraction is cleanest — settled surfaces first:

- **syntax** ← `../internals/syntax.md`
- **types** (values/references, sum types + matching, error handling) ← `../internals/types.md`, `../internals/memory-model.md`
- **generics + interfaces** ← `../internals/generics.md`, `../internals/interfaces.md`
- **concurrency** (the shareability rule, structured scopes, actors) ← `../internals/concurrency.md`

Keep it to guarantees a Nomu author can rely on — no implementation detail. Update the deferred
item ("Docs reorganization: working design docs vs. a language spec", `../plans/deferred.md`) and
close it as these land.

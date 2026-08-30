# Methods (+ computed properties, static) on generic types

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · shipped (tails open)` · **Size:** M ·
**Status:** shipped (slices 1+2; inference tail open) · **Source:** surfaced while scoping
[for … in](117-for-in-iteration.md) and real Array/String — the prerequisite the roadmap never filed as
its own task.

## What

Allow `fun`, computed properties, and `static fun` on generic types — `struct Box<T> { fun get() -> T { … } }`.
Previously rejected outright by `Sema.rejectGenericMembers` + `methods: []` in `lowerGenericDecl`.

## Shipped

Instance methods, computed properties, and `static fun` now work on generic **structs, classes, and enums**
(verified end to end: `Box<Int>.get()`, `Wrap<Bool>`, generic-enum self-match, `Box<Int>.make(v:)`).

- **Lowering** (`lowerGenericDecl`): `self` is the applied generic type `S<T…>`; members lower with the
  type's params in scope, so a `T` resolves to `.typeParam`. Instance methods → `lowerMethods`,
  computed properties → `lowerAccessors`, `static fun` → `lowerStaticMethods` **carrying the type's
  generics** so mono registers it as a template.
- **Call resolution:** `x.m()` / `x.p` on a `.generic` receiver resolve the member on the template and
  substitute the instantiation's args (`genericMethodSig` / `genericSubst`, mirroring the existing
  `genericMemberType` for fields). `Box<Int>.make(…)` emits a `.call` with the type args threaded, so
  monomorphization specializes the static free function per instantiation.
- **Mono + codegen** needed no change — `specializeType` already cloned methods with substitution, and
  generic static functions ride the existing generic-func specialization (`.call` typeArgs → `specName`).

## Tails still open

- **Type-arg inference for generic static methods.** `Box<Int>.make(v: 3)` works; `Box.make(v: 3)` errors
  asking for explicit `<…>`. Inferring the args from the value arguments is not done.
- **Whole-aggregate value read (D6).** A method returning a whole value+reference-mixing aggregate by value
  (`get() -> T` where the concrete `T` mixes value and reference fields) inherits the pre-existing D6 spill
  limitation (`c-types.md` §3.4) — scalar / reference / pure-value `T` and field-wise access are fine.
- **Own generics on a member** (`static fun map<U>(…)`) — members currently use only the type's params.

## Why it matters (high priority, usability)

It is the **gate under the whole collections story.** `Array<T>` and `String` are builtin type cases
(`.array`/`.string` in `Type.swift`), not Nomu-source types, precisely because a real `struct Array<T>`
would need `subscript` / `append` / `count` **as methods on a generic type** — which is exactly what is
rejected. So this blocks:

- Real, extensible [Array](120-stdlib-core.md) / [String](121-string-utf8-model.md) as Nomu types (retiring
  the ~64 `.array`/`.string` special-case sites; fixing the String immortal-buffer leak).
- The **real-iterables** form of [for … in](117-for-in-iteration.md) (a `Sequence`/`Iterator` interface a
  generic collection conforms to).
- The [generic hash map](124-generic-hashmap.md) (a generic value type with methods).

The concrete `for … in` (arrays + ranges) does **not** need this — its surface is identical either way, so
it can ship first. This task is the foundation for the extensible version.

## How it was built (grounded in code — the analysis that held up)

The two back halves of the pipeline already handled generic-type methods; the build fed them from the
frontend. Recorded here because the "already built" finding is what made this an M, not an L:

- **Monomorphization is ready.** `Monomorphizer.specializeType` (`Monomorphize.swift:84`) clones a generic
  type's `methods` with its type parameters substituted (`methods: s.methods.map { rewriteFunc($0, subst, …) }`),
  and `rewriteFunc` (`:133`) rewrites the full method **body**, not just the signature. The moment a generic
  type carries methods, each instantiation gets concrete, substituted copies.
- **Codegen is ready.** After mono a `Box<Int>` method is an ordinary concrete method; codegen's existing
  `declareMethod` / method-call path emits it (the `.typeParam` witness-dispatch branch just isn't taken).
- **The resolution pattern exists.** Field reads on an applied generic (`Box<Int>.field`) already resolve
  via `genericMemberType` (`Sema.swift:1425`), substituting `T` → the concrete arg for the result type. Method
  calls on a `.generic` receiver follow the same shape.

## The frontend work (done)

1. **Lower generic-type members instead of rejecting.** In `lowerGenericDecl` the type's generic params are
   already in scope (`genericScope` set at `Sema.swift:507`), so a `T` field/return resolves to
   `.typeParam("T")`. Route `s.methods` / `e.methods` / `c.methods` through `lowerMethods` (and
   `lowerAccessors`, and the new `lowerStaticMethods`) rather than `rejectGenericMembers` + `methods: []`.
2. **Typecheck method / property / static calls on a `.generic` receiver.** Resolve the member's signature
   from the generic template and substitute the instantiation's type args (mirror `genericMemberType`), emit a
   `.methodCall` (or the static free-call form) that mono then specializes. Instance-method dispatch currently
   keys on `.named(typeName, kind)` (`Sema.swift:2155`); it needs a `.generic(base, args)` sibling.
3. **Modular checking against bounds (generics.md §12).** A generic method body is checked **once** against
   what its bounds promise — a `T: I` receiver inside a method dispatches through the bound's witness, the same
   rule generic *functions* already use (5.2.2). Keep the body free of any per-instantiation assumption so
   witness-passing stays reachable (the witness-first / mono-second reversibility guardrail, generics.md §12).

## Design questions to settle

- **Witness-passing vs mono-only for the type's own methods.** Whole-program mono (the single-CU policy)
  specializes every instantiation, so the type's own methods need no witness table. Decide whether to keep the
  method path mono-only for now or preserve a witness-passing form for the future stable-ABI-at-module-edges
  goal (generics.md §6/§12). Leaning: mono-only now, mirror the reversibility guardrails already honored for
  generic functions.
- **`static fun` on generic types** (e.g. `Array<Int>.empty()`). The static-method routing added recently is
  guarded to non-generic types (`genericArity(tn) == nil`); lift that guard here and mangle the free function
  per instantiation (mono already stamps type args into names).
- **D6 spill interaction.** Methods that take/return `T` by value may hit the whole-aggregate value-read spill
  that blocks [124](124-generic-hashmap.md) and [tuples](109-tuples.md) (`c-types.md` §3.4). Scope whether the
  first cut restricts to reference/scalar `T` uses or waits on D6.

## Dependencies & triggers

- **Rides:** the M5 witness / monomorphization machinery (present); the field-on-generic resolution
  (`genericMemberType`) and the concrete method pipeline (both present).
- **Blocks:** [120 Array](120-stdlib-core.md), [121 String](121-string-utf8-model.md),
  [124 generic hash map](124-generic-hashmap.md), and the real-iterables form of
  [117 for … in](117-for-in-iteration.md).
- **Interacts with:** [118 associated types + where-clauses](118-associated-types.md) (the next layer of
  generics depth); the D6 spill.

## Refs

`Sema.rejectGenericMembers` / `lowerGenericDecl` / `genericMemberType` (the gate + the resolution pattern);
`Monomorphize.specializeType` / `rewriteFunc` (the ready mono half); `generics.md` §6, §12 (witness-first /
mono-second, modular checking); `c-types.md` §3.4 (D6 spill).

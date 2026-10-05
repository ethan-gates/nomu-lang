# Method-level generics (a method's own type parameters)

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** L ·
**Status:** needs-design · **Source:** surfaced while building [100](100-modules.md) §100.4.3.5.3.4 —
the cross-module erased path for generic-type methods assumed an in-module implementation of method-own
type parameters that does not exist.

## What

Allow a method to declare its **own** type parameters, bound per call, independent of the owning type:

```nomu
struct Box<T> {
    var value: T
    fun map<U>(f: (T) -> U) -> Box<U> { return Box(value: f(value)) }
    fun pick<U>(a: U, b: U, useFirst: Bool) -> U { if useFirst { return a }; return b }
}

struct Logger {                       // the owner need not be generic
    fun record<U>(item: U) -> Bool { return true }
}
```

`U` belongs to the method and varies **per call** (`b.map<String>(…)` and `b.map<Double>(…)` from one
`Box<Int>`), whereas the owning type's `T` is fixed when the value is created. This is a distinct axis
from [151](151-generic-type-methods.md) (methods on a generic type that use only the **type's** params);
method-level generics apply to methods on non-generic types too.

## Current state (nothing works)

The parser accepts `fun pick<U>(…)`, but the method's own `<U>` is never put into scope, so even a body
on a **non-generic** type fails at the frontend:

```
error: unknown type 'U'
```

Nothing downstream (call-site inference of the method's args, monomorphization, codegen) handles a
per-method type parameter. [151](151-generic-type-methods.md) lists this as an open tail ("Own generics
on a member"); ownership of the whole feature moves here.

## Scope — this task owns the whole picture

End to end, in this order (each layer is a prerequisite for the next; the in-module feature is useful on
its own and is where most of the work is):

### 170.1 — Frontend scope + type-checking (no modules)
- Put a method's own generics (then-after the owner's) into `genericScope`/`genericBounds` while lowering
  and checking the method body, so `U` resolves to `.typeParam("U")`. Today `lowerMethods`
  (`NOIRGen.swift`) sets only the owner's params; extend it to `ownerGenerics + m.generics`, mirroring
  `lowerFunc` for free generic functions.
- `validateBounds` on the method's own generics; reject a method generic that shadows an owner generic.
- The reconstructed-decl / member registration paths learn method generics (so later the interface and
  erased ABI can see them).

### 170.2 — Call-site inference
- Infer the method's type args from its value arguments (`b.map(f: intToString)` → `U = String`), the
  second, independent inference next to the owner's already-fixed args. Mirror the free-generic-function
  inference (`GenericInference.swift`). Explicit `b.map<String>(…)` as the fallback/disambiguator.

### 170.3 — Monomorphization (in-module)
- Specialize a method per **combination** of (owner type args × method type args): `Box<Int>.map` with
  `U=String` and with `U=Double` are two functions. `specializeType` clones methods with the owner subst
  today; the call site must now also thread the method's own type args so a second specialization axis
  keys the clone. Carry the method type args on the method `.call` (like the static-free-call path does).

### 170.4 — Codegen (in-module)
- After mono a method-generic call is an ordinary concrete method — the existing method-call egress
  should emit it. Verify the mangled name disambiguates the method-arg axis.

### 170.5 — Module boundary (erased) — folds in 100.4.3.5.3.4's method half
- The erased ABI convention is already pinned (`backend.md` §4; [100](100-modules.md) §100.4.3.5.3): hidden
  VWTs for the **owner's** params first, then the **method's own**, so `Box<T>.map<U>` crosses as
  `(VWT_T, VWT_U, …, sret, self, f)`. `FunctionLowerer.lowerMethod`'s erased branch already sets
  `currentGenerics = ownerGenerics + f.generics`. The interface (`.nmi`) carries method generics (the
  `InterfaceFunc.generics` field exists); `interfaceToDecls` reconstructs them; Sema registers the erased
  sig; the consumer call lowering threads both axes' VWTs through `emitErasedExternalCall`.
- The 100.4.3.7 method-differential test leg (erased split-module output == mono) covers this once it lands.

## Why it matters

Method-level generics are standard for collection and functional APIs (`map`/`filter`/`reduce` as members,
generic `record`/`insert` helpers). They are the member-side counterpart to free generic functions, which
Nomu already supports. Not a blocker for the concrete collections surface, but the idiomatic one.

## Dependencies & triggers
- **Rides:** the M5 witness/mono machinery; free-generic-function scope + inference + specialization
  (present); [151](151-generic-type-methods.md) methods-on-generic-types (present).
- **Unblocks:** the method half of [100](100-modules.md) §100.4.3.5.3.4 (erased cross-module generic
  methods); idiomatic member-level `map`/`filter` on [120 Array](120-stdlib-core.md) /
  [124 hash map](124-generic-hashmap.md).
- **Interacts with:** [118 associated types + where-clauses](118-associated-types.md); the D6 by-value
  spill (`c-types.md` §3.4) when a method's own `T` is taken/returned by value.

## Refs
`NOIRGen.lowerMethods` / `lowerFunc` (owner-only vs full generic scope); `GenericInference.swift`
(free-function inference to mirror); `Monomorphize.specializeType` / `rewriteFunc` (owner-subst clone to
extend with the method axis); `FunctionLowerer.lowerMethod` (erased branch, `ownerGenerics + f.generics`);
`backend.md` §4 (erased witness ABI); [100](100-modules.md) §100.4.3.5.3 (the cross-module erased method path).

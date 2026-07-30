# Type System

**Status:** working draft. The home for Nomu's type system apart from interfaces — strong static typing, generics and their dispatch strategy, sum types with exhaustive matching, and error handling. Status tags: **Decided**, **Deferred**, **Open**.

**API scope:** no concrete syntax or keyword here is committed. Constructs like `switch`/`case`, `Result`, `?`, and generic-bound spellings are illustrative and Swift-shaped until we agree. What's pinned is the *model*.

**Siblings:** the value/reference split and category semantics live in `memory-model.md`; interfaces, conformance, dispatch, extensions, and composition live in `interfaces.md`. This doc covers the rest.

---

## 1. Foundations

- **Strong static typing, no classic inheritance.** — **Decided.** Abstraction and reuse come from interfaces + extensions, not a base-class hierarchy (`interfaces.md`).
- **Value / reference split** as the layout and semantics backbone — `struct`/`enum` are values, `class` is a reference (`memory-model.md`). — **Decided.**
- **Interfaces/protocols with default methods** — the abstraction mechanism, detailed in `interfaces.md`. — **Decided.**
- **Modest local inference** — bottom-up expression typing plus declared annotations: `let x = expr` infers `x` from `expr`, a function's return is checked against its annotation, and closure params come from their annotations. A contextual expected type also flows *inward* to a leading-dot enum case (`.circle(...)` — §2), from the binding annotation, argument slot, or return position; that is the one place typing is top-down rather than bottom-up. No Hindley–Milner / global inference (generic inference is M5, `generics.md`). — **Decided (M4.9; contextual enum inference M4.10).**

No inheritance + interfaces + extensions is the Swift-protocol / Rust-trait / Go-interface design — well-trodden and coherent.

---

## 2. Sum types and pattern matching

**Sum types / enums with associated values**, with **exhaustive** pattern matching. — **Decided.**

Sum types are the clearest single win over Go. Exhaustiveness checking is a legibility and correctness feature — the compiler proves every case is handled, so adding a case surfaces every site that must react.

```
enum Shape {
    case circle(radius: Int)
    case rect(w: Int, h: Int)
}

fun area(s: Shape) -> Int {
    switch s {
    case .circle(let r):      return 3 * r * r
    case .rect(let w, let h): return w * h
    }
    // exhaustive: no default needed when all cases are covered
}
```

Enums are value types (tagged unions, laid out inline); a recursive enum (`indirect`) becomes a reference under the hood (`memory-model.md`). Payload matching binds fields per case.

**Construction** (landed M4.10): an enum value names a case and its payload, either **qualified** — `Shape.circle(radius: 10)` — or with the **leading-dot** shorthand `.circle(radius: 10)`, where the enum type is inferred from context (§1). A no-payload case constructs bare (`Color.red`, or `.red`); payload is **labeled**, matching struct construction.

Exhaustiveness is checked as a pass over the typed mid-level IR (`compiler.md` §1), the same altitude Rust checks it (THIR). A `switch` on an enum that misses a case is a compile error; there is no `_`/default arm, so exhaustive means every declared case appears.

---

## 3. Methods on types

**Instance methods on `struct`/`enum`/`class`**, declared with `fun` inside the type body — no separate keyword. — **Decided; methods landed M4.9, mutating value-type methods M4.11.**

```
struct Counter {
    var count: Int
    fun get() -> Int { return count }    // read-only
    fun bump() { count = count + 1 }      // mutating (inferred)
}
```

- A method reads/writes fields by bare name or via `self.`. A **read-only** method takes `self` by value (`struct`/`enum`) or reference (`class`); a **mutating** value-type method takes `self` by reference so its writes reach the caller's value.
- **Mutating-ness is inferred, not declared** — a method is mutating iff it writes a field of `self` or calls a mutating method on `self` (transitive). There is **no `mutating` keyword** (yet); the explicit form can be layered on later. — **Decided (2026-07-23).**
  - **Calling a mutating value-type method requires a mutable (`var`) receiver.** A `let` value binding is immutable, so a mutating call on it is an error; assigning to a `let` field or reassigning `self` is an error. **Classes are reference types**, so their methods are callable on any binding (the reference is constant, the object is mutable).
  - **The inferred bit is part of the method's exported contract** (`modules.md` §1): a body change that flips a method non-mutating → mutating is an API-breaking change with no signature-text change — the standing argument for eventually adding the explicit keyword.
- **Property setters** — computed properties and `{ get set }` interface requirements build on mutating value-type methods and ship in M5 (`interfaces.md`; `memory-model.md` §4 for binding/immutability).
- Methods are the seam for **interface method requirements** (M5, `interfaces.md`).
- Surface: a `fun` member must begin its own line inside a type body (`syntax.md` §2).

---

## 4. Generics

Generics are real and first-class, **built through M5 and specified as-built in `generics.md`** — parameters, type-argument inference, checking, witness-passing + monomorphization, generic types, the `shared` bound + conditional conformance, exhaustiveness, and `Result`. This section keeps only the model overview; `generics.md` is authoritative.

- **Dispatch — witness-passing baseline + monomorphization (Decided; built).** A generic body compiles once against its bounds' protocol witnesses (dictionary-passing); monomorphization is a specialization pass that, under the single compilation unit, runs on **everything**, so generic code is static in practice. **`any I` existentials** are the opt-in dynamic form. The *guaranteed*-static levers (independent of specialization) are **concrete types** and **`some I`** (`generics.md` §1, §6).
- **Checking — modular against declared bounds (Decided; built).** A body is checked once against exactly what `T: I` promises, which keeps witness-passing, monomorphization, and future GC value-witness stenciling all reachable (`generics.md` §4).
- **Power ceiling — ~Rust-trait level, no HKT.** Associated types / generic interfaces, general (user-declared) conditional conformance, and operators-as-requirements are the deferred surface (`generics.md` §10, `interfaces.md` §8).
- **The `<shared T>` bound rides on type parameters — declared, not inferred (built).** A declared bound gives local errors and honest signatures and works whether or not the generic monomorphizes. Full share analysis: `concurrency.md` §5; as-built: `generics.md` §7.

---

## 5. Error handling

**Errors are values, not exceptions.** — **Decided (2026-07-16).** There is no `throw`/`catch` and no stack-unwinding exception mechanism; a failable operation returns its error as a value, propagated explicitly. This runs through the design: cancellation stays distinct from errors precisely because errors are values (`concurrency.md` §7), closure failability rides in the return type (`concurrency.md` §6), and the continuation hands failures back as a value (`resume(Result)`, `concurrency.md` §3). It fits the small-runtime, no-mandatory-unwinding, explicit style.

**Carrier — `Result<T, E>`. — Decided (2026-07-19); built (M5).** A generic sum type `enum Result<T, E> { case ok(value: T)  case err(error: E) }`, a **prelude citizen** in `src/stdlib/core.nomu` (usable with no import, like `Option`), handled by explicit `match`/`switch` over `.ok`/`.err`. The alternatives weighed and dropped were a Go-style tuple and other carriers; the sum type won. As-built detail: `generics.md` §9.

**Deferred:**
- **The `?` operator** — a propagation operator, and its form.
- **Typed throws** — whether error types appear in signatures.

Go-philosophy explicit `match` handling is the shipped baseline; the sugar above is later work.

---

## 6. Open questions

- **Generics** — **built through M5** (dispatch, checking, the `<shared T>` bound, and `some` mechanics all resolved; §4, `generics.md`). Remaining open items are the deferred surface in `generics.md` §10: associated types, operators-as-requirements, general conditional conformance, the newtype mechanism.
- **Error handling form** — errors-as-values is Decided and the `Result<T, E>` carrier is built (§5); open is the `?` operator and typed throws.
- **Associated types / generic interfaces, general conditional conformance** — tracked with the interface + generics work (`interfaces.md` §8, `generics.md` §10). (`some` opaque-type mechanics are Decided and built — `interfaces.md` §5.2.)

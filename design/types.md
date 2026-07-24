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

**Decided:** generics are real and first-class. **Open (highest-priority forward item):** the full design — dispatch strategy, power ceiling, and how the "shareable" bound rides on type parameters. The M5 working design (decided variance, deferred items, dispatch/checking direction) lives in `generics.md`; this section keeps the model overview.

- **Dispatch strategy — leaning monomorphization, not locked.** Monomorphization gives zero-cost generics, no witness table, and a small runtime, and it is the same specialization that would close the performance gap to Swift (`memory-model.md` §8). Dictionary-passing / existential lowering is not ruled out. **`any Interface` existentials** (dynamic dispatch) are opt-in regardless of this choice. — **Open (leaning monomorphization).**
- **Power ceiling** — associated types, constraints; target ~Rust-trait level, **no HKT**. Associated types / generic interfaces, conditional conformance, and `some` (opaque type) mechanics are the highest-complexity area, tracked in `interfaces.md` §4.5. — **Open.**
- **The "shareable" bound rides on type parameters** — a `<T: shareable>` bound is **declared, not inferred-at-instantiation**, for local errors, honest signatures, and because generics aren't guaranteed to monomorphize (a dictionary-passing/existential generic is checked once against its bound). Full share analysis in `concurrency.md` §5. — **Decided (bound is declared); spelling open.**
- **Checking model** — whether generic bodies are checked modularly against the bound (Rust-style) or per-instantiation (C++-style) is open and ties to the dispatch choice (`interfaces.md` §3). — **Open.**

Monomorphization is the leading candidate because it gives strong performance *and* a small runtime. Under the GC pivot the generics design sheds the region-summary coupling that made it hard in the ARC era. Decide the details when generics are actually implemented.

---

## 5. Error handling

**Errors are values, not exceptions.** — **Decided (2026-07-16).** There is no `throw`/`catch` and no stack-unwinding exception mechanism; a failable operation returns its error as a value, propagated explicitly. This is load-bearing across the design: the cancellation model keeps cancellation distinct from errors precisely because errors are values (`concurrency.md` §7), closure failability rides in the return type (§6), and the continuation hands failures back as a value (`resume(Result)`, §3). It fits the small-runtime, no-mandatory-unwinding, legible-and-explicit style.

**The form is open.** — **Open (leaning a `Result` sum type + a `?`-style propagation operator).** Sub-items:
- **The carrier** — a `Result` sum type vs. a Go-style tuple vs. **other approaches worth exploring** when the time comes (the author wants to consider options beyond sum types and tuples, not just pick between those two).
- **The `?` operator** — whether to adopt a propagation operator, and its form.
- **Typed throws** — whether error types appear in signatures.

Finalize alongside generics (an error type is often generic). Go-philosophy explicit handling is the leaning.

---

## 6. Open questions

- **Generics** — dispatch strategy (monomorphization vs. dictionary-passing), power ceiling (associated types, constraints; ~Rust-trait level, no HKT), the `<T: shareable>` bound spelling, and modular-vs-per-instantiation checking. Highest-priority forward item (§4).
- **Error handling form** — errors-as-values is Decided (§5); open is the carrier (`Result`/tuple/other) and the `?` operator / typed-throws question.
- **Associated types / generic interfaces, conditional conformance, `some` mechanics** — tracked with the interface composition work (`interfaces.md` §4.5).

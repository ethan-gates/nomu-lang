# NOIR — the mid-level IR

**Status:** working draft, as-built. The typed structured mid-level IR that the semantic pass builds and the IR passes run on. Where NOIR sits in the whole pipeline is in [`architecture.md`](architecture.md); the optimizer tier NOIR lowers into is [`ssair.md`](ssair.md). Status tags: **Decided**, **Deferred**, **Open**.

A typed **mid-level IR** sits between the parser and the code-generation backend; semantics-aware passes run on *this* IR, then lower to the backend (analog: Swift's SIL). — **Decided; the IR and the semantic pass that builds it were implemented in M4.9.** Nomu's typed IR ≈ **Rust's THIR**; the lower CFG/SSA level (the SSAIR optimizer tier — precise escape analysis, devirtualization, etc.) ≈ **Rust's MIR / Swift's SIL** and lives in [`ssair.md`](ssair.md).

**Altitude — structured, not CFG/SSA.** NOIR keeps `if`/`switch`/loops as nested nodes and closures first-class, so codegen stays mechanical and lowering keeps structured control flow. Every node is **typed** and carries a **source span** — debug info threaded from the start (cheap now; retrofitting is miserable) and preserved by every pass. The DWARF quality the debugger rests on depends on the span invariant surviving every pass ([`debugger.md`](debugger.md)).

**The semantic pass** (name/scope/member/method resolution, expression typing, call/argument checking, return checking) produces the IR and reports **collected diagnostics** (collect-and-continue, not exit-on-first-error). It replaced the old ad-hoc type tracking in codegen (`typeOf` + a `Scope: [String:String]` string map) with a real internal **`Type` model**: `int`/`bool`/`string`/`void`, `named(name, kind ∈ {struct, enum, class, actor})`, `function(params, ret)`, and `error` (suppresses cascades); backed by symbol tables and a lexical scope stack. M5 extends the model (`typeParam`, existentials, generic instances). (POD and let/var checks still run in a small separate AST pass before the semantic pass; an **extension-merge pass** — M4.12 — also runs on the AST before it, folding plain `extension T { … }` methods into their target type's member set so the semantic pass sees one type with all its methods. M5 Phase A's conformance extensions reuse that merge. Extension model: `interfaces.md` §1.)

**NOIR is the M5 dispatch point.** Member/method dispatch is resolved in the IR — a method call names its concrete target — so codegen never re-resolves. M5 extends this: the call node gains a dynamic/witness form for `any`, and generic calls carry witness arguments.

## Passes over the mid-level IR

- **exhaustiveness checking** — *implemented (M4.9)*; runs on the typed IR, the altitude Rust uses (THIR). See `types.md` §2.
- **mutation analysis** — *implemented (M4.11)*; infers each method's mutating-ness (writes to `self`, transitively through self-calls) and validates `let`-field / `self` writes (`types.md` §3).
- **share analysis** — materializing shareability into module interfaces (`concurrency.md` §5). *Currently still in codegen* (spawn-capture + actor-handler-param checks); migrates to an IR pass with M5's shareability work.
- **closure conversion** — *currently still in codegen* (closures stay first-class in the IR); promoted to a pass later.
- **monomorphization** — M5 (`generics.md` §6).
- **escape analysis** (`memory-model.md` §6.1) — the precise flow-sensitive form runs in the SSAIR tier (`ssair.md`); a conservative form shipped with M6.
- **GC safepoint / barrier insertion** — emitted at the LLVM level (`backend.md`).

The backend (LLVM) does not understand the language's semantics, so running these passes on LLVM IR would be the wrong altitude.

(The pass list changed with the memory-model pivot: ARC insertion / refcount elision / isolation-region checks are gone; escape analysis and GC barrier/safepoint insertion take their place, and monomorphization gains importance as a performance lever.)

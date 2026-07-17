# Nomu — North Star

The goal of the language: what it should feel like, what it should cost, and what it refuses to be. The tiebreaker when a design decision is in tension.

## The four wants (and their opposites)

Combine four things no single language gives together:

1. **Swift's type system** — sum types, generics, protocols, value/reference split.
2. **Go's easy memory** — a garbage collector; you don't manage memory.
3. **Go's easy concurrency** — lightweight, colorless, no coloring ceremony.
4. **Swift's performance** — cheap value types, no VM tax.

While avoiding:

- **Swift's memory fiddling** — never reach for `weak`/`unowned`/unsafe pointers for performance.
- **Swift's deployment baggage** — a small static binary, no platform lock-in.
- **Go's thin type system** — sum types and real generics are table stakes.
- **Rust's friction** — no borrow checker, lifetimes, or ownership annotations. Fighting the compiler about memory is the thing Nomu exists to eliminate.

## Memory: invisible

The programmer never annotates memory — no ARC, `weak`/`unowned`, regions, or borrow checker.

- **Reference types are garbage-collected** via MMTk (generational Immix now, an LXR-style RC collector as the footprint endgame). Cycles collect automatically.
- **Value types are copied and inline**; escape analysis keeps non-escaping ones off the heap.
- **Non-memory resources** (files, sockets, locks) release deterministically via `defer` / linear resource types.

Correctness is the runtime's job, performance the compiler's, neither the programmer's.

## Performance

Target: **Swift-class**, honestly. It comes from inline value types + escape analysis + a quality collector; the model is **C# with structs and Native AOT**, not Go.

- **Matches Swift** on value-heavy code; **beats** it on reference-heavy code (a tracing GC pays nothing per access; Swift pays atomic retain/release per share).
- **Concedes** on footprint (~1.1–1.3× live set, tunable) and worst-case latency (small pauses — accepted).

The *design* permits Swift-class performance; *realizing* it is a multi-year backend effort. A prototype won't match Swift — the job now is to keep the ceiling high.

## Type system

Swift-class expressiveness: sum types with payloads and exhaustive matching, protocols + extensions (no inheritance), a value/reference split, and Swift-semantics `let`/`var` where immutability is a type property. Generics are real but their design is unsettled — the highest-priority open item.

## Concurrency

Feels like Go: cheap to reach for, no ceremony.

- **Colorless** — no `async`/`await` coloring; a hard requirement, driving an M:N stackful runtime. No suspension marker at all (transparent, Go-style); concurrency is introduced only by an explicit construct, so serial-vs-concurrent stays legible without one.
- **Actors** for isolated stateful concurrency; values and immutable types make most sharing safe by construction.
- **Race-free by construction** — a value crossing a task boundary must be "shareable" (a value type, an immutable type, or an actor handle), auto-derived and surfacing only on the concurrency APIs. Rust's `Send`/`Sync` without the borrow checker.

## Deployment

Go-class: a single small static binary (~20MB ceiling), no install requirement (no JVM/Python/Erlang VM), copy-and-run on Linux. MMTk links statically and fits.

## Library tiers: language > runtime > stdlib

Three layers, with a firm rule about what may be privileged:

- **Language** — the compiler-known surface: the type system, value/reference split, generics, interfaces, sum types, linear types, and a small set of blessed constructs (e.g. the continuation, an intrinsic over the runtime). What needs compiler magic lives here, explicitly and in a small set.
- **Runtime** — the mandatory floor: the garbage collector (MMTk) and the M:N stackful scheduler + poller. Reference types and all concurrency depend on it. **The runtime is always present** — Nomu declines to define what a reference type or heap allocation would mean without it, so there is no runtime-less configuration.
- **Standard library** — ordinary Nomu code on top of language + runtime: collections, strings, I/O helpers, channels-as-library. **The stdlib is pure** — it gets no special treatment the compiler withholds from user code, and it is **elidable**.

This yields two deployment shapes:

| Shape | Contains | For |
|---|---|---|
| **language + runtime** | full language — value + reference types, generics, interfaces, actors, fibers, GC, continuations — no batteries | minimal-footprint systems, bring-your-own abstractions |
| **+ stdlib** | collections, strings, I/O, channels — ordinary code on top | everyone else |

Colorless stackful concurrency and GC reference types both require the runtime, so they sit at the runtime/language tier, never in the elidable stdlib. Keeping the stdlib pure means anything that needs `park`/`unpark` or other privileged runtime access is a **language/runtime intrinsic**, not a privileged library function. ("Zero privileged surface" is an ideal even Rust and Swift don't fully reach; the target is to keep the privileged set small, explicit, and named as intrinsics rather than scattered as stdlib magic.)

## The feel

You write the program you mean and the types catch mistakes; you never think about memory and it's still fast; you reach for concurrency without dread; you read others' code and understand it; you ship a binary and it runs. **Legibility is the north star** — when two designs are equally correct, the clearer one wins.

## Design principles

Two principles generate downstream decisions; when a future feature is unclear, resolve it against these.

**Few first-class concepts; macros are for extension only.** A small number of well-chosen, first-class concepts, each with real syntax and real type-checker support. Concurrency, memory semantics, and interface conformance are language features, never macro/pragma plumbing. A macro must never be the only way to reach a core capability. This is the anti-Nim principle: Nim's fault is accretion — it lets the user assemble the language out of pragmas, so nothing coheres. Nomu optimizes the opposite axis, **coherence over expressiveness** (`macros.md`).

**Pay only where it's hard, not everywhere.** Any design that asks the programmer to annotate the *common case* is wrong for Nomu. This is a mechanical filter, sharper than "keep it simple." Under the GC, the memory axis costs **zero** annotations — memory is fully invisible. The principle still governs generics, error handling, and concurrency safety: the marker appears at the hard spot (crossing a task boundary through an abstraction), and nowhere on the common case (`concurrency.md` §5).

## Rejected directions

**Mutable Value Semantics / Hylo — evaluated and rejected, from direct experience.** Hylo (formerly Val, from Dave Abrahams) is *Swift-like syntax + a memory model with deliberately no ARC* — a close relative, since Swift-like syntax is a hard requirement here. The author built the Hylo compiler from source and formed a verdict at the keyboard. Where Nomu **agrees** with MVS: most of a program is plain data, data has no identity, so make it values and it never touches a collector or forms a cycle — the value/reference split (`memory-model.md` §1) arrives at the same intuition. Why it was **rejected**: (1) access conventions are required on *every parameter* — the tax lands on the common case, permanently, violating "pay only where it's hard"; (2) identity is awkward — MVS's answer to file handles, sockets, and graphs is "index into a store," a hand-rolled pointer with worse ergonomics; (3) research-stage maturity — frequent compiler bugs in practice. The GC obtains MVS's cycle-and-sharing simplification by a different route, with no per-parameter annotation, so MVS's advantage narrows to a philosophy Nomu already shares minus a tax it declines to pay.

**Rejected globally** (rationale in each home doc): ARC as the memory model (its performance needed a visible ownership discipline = friction); reference capabilities + ORCA (elegance bought with per-parameter annotations); borrow checker as the mechanism (price paid in syntax); MVS access conventions on every parameter (tax on the common case); macros/pragmas as core-language plumbing (Nim's incoherence); multiple concurrency primitives exposed to the user (Nim's incomprehensibility); building a debugger from scratch (reinventing lldb).

## What Nomu is not

- **Not a no-GC language** — it has a collector and says so.
- **Not a maximal-control language** — not C or Rust; it trades the last increment of control for the absence of the control tax.
- **Not zero-pause absolutism** — predictable, small collection cost over hard no-pause guarantees.
- **Not built for adoption** — any wedge for others is a side effect.

## Resolving future decisions

When a decision is unclear, resolve it in favor of the combination at the top of this doc — Swift's expressiveness, Go's ease and deployment, none of Rust's friction — organized around **legibility**: a program whose behavior you can read off the source, with memory deliberately *absent* from that reading rather than intricate within it.

Three rules:
1. **Keep the surface legible.**
2. **Never tax the common case with annotations — pay only where it's hard.**
3. **Bias toward ease; add static enforcement only when it doesn't reintroduce Rust-grade friction.**

And the working discipline: **build the part you doubt first; prototype the belief, not the surface.** The belief to prototype now is the concurrency-safety model and the front-end feel — memory is a solved, borrowed component.

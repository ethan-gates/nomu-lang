# Deferred implementation work (TODO backlog)

A running list of feature work that is **intentionally postponed** — the direction is
decided, the build is parked until a real trigger arrives. Distinct from a design
*Open* question (still undecided) and from a milestone's in-scope deferrals (those live
in the owning `mN-spec.md`). Each entry records **what**, **why deferred**, the
**trigger** that should un-park it, and the **design ref**.

Status vocabulary matches `readme.md` §"Reading the status tags".

---

## `shared` on function-type / existential spellings

- **What.** The explicit `shared (A) -> B` (shareable closure/function type) and
  `shared any I` (shareable existential) spellings (`generics.md` §2). The
  `<shared T>` *bound* shipped in M5 (`generics.md` §7); these two spellings did not.
- **Why deferred (Decided 2026-07-28).** No consumer in M5. Shareability is
  auto-derived structurally (`generics.md` §7), so no annotation is needed for the
  common case. The explicit marker is only required on a **closure/generic parameter
  forwarded to a task where the forwarding body is hidden from the caller**
  (`concurrency.md` §5). Those hidden-body boundaries are **interface method
  requirements** and, later, **module boundaries** — neither exercised for
  closure-forwarding under M5's single compilation unit. Building it now means
  threading the capability through `Type` (`.function`/`.existential`/`.composition`,
  ~27 switch sites + assignability rules) with nothing to exercise it.
- **Trigger to build.** An interface requirement needs to forward a closure to a task
  (so its signature must spell `shared (A) -> B`), or modules land (hidden bodies
  across the boundary).
- **How to build then.** Param-focused and sound, mirroring 5.3.2: parse the spelling,
  record param shared-ness in the signature, discharge at call sites (arg closure's
  captures shareable / arg value's type shareable), treat a `shared` param as
  shareable in-body via name-tracking (`Sema.sharedParams`) — a full `Type`-model
  change is optional, needed only if shared-ness must flow through fields/returns.
- **Ergonomic alternative (separate item).** Bottom-up **inference** of a closure
  param's shareability requirement from a visible body (`concurrency.md` §5,
  "inferred bottom-up" — a *Leaning* item) keeps `shared` unwritten for ordinary
  functions. Larger analysis; independent of the spelling above.
- **Refs.** `generics.md` §2, §10; `concurrency.md` §5; `interfaces.md` §8.

---

## Docs reorganization: working design docs vs. a language spec

- **What.** Split the doc set into two audiences: **working design docs** (the
  `mN-spec.md` build plans, decision records, and per-feature design like `loops.md` —
  how and why we build) and a **language specification** (what the language *guarantees
  to the programmer*: syntax, semantics, and the contracts a Nomu author can rely on,
  independent of implementation). Today both live intermixed across `design/`.
- **Why deferred (raised 2026-08-03).** The design docs are still churning as M8 lands;
  extracting a stable programmer-facing spec now would track a moving target. The split
  pays off once the language surface settles.
- **Trigger to build.** After M6 (post-GC), when the surface is stable enough that a
  guarantees-oriented spec stops thrashing. Revisit as a post-M6 item.
- **How to build then.** Decide the boundary (spec = observable behavior + syntax +
  semantics; design docs = rationale + build plan + internals), then lift the
  programmer-facing content out of `syntax.md`/`concurrency.md`/`types.md`/etc. into a
  spec, leaving the working docs to cross-reference it. Discuss scope first.

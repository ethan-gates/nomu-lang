# Modules & Access Control

**Status:** **stub** — the design is undesigned. This doc reserves the topic and records what other docs already lean on, so it isn't lost. Access control shares this doc because it doesn't yet merit its own. Status tags: **Open**.

**Not on the critical path.** The early milestones (walking skeleton, type surface, concurrency on OS threads) needed neither modules nor access control, so this was deferred; the design work is task `plans/tasks/100-modules.md`. Several decided areas reference it, so the boundaries below must eventually exist.

---

## Why this exists (what already depends on it)

- **Share analysis** (`concurrency.md` §5) materializes each function's shareability requirement **into the module's compiled interface** at public boundaries, and assumes **separate compilation**. That requires a defined notion of a module and its compiled interface.
- **Actors** (`concurrency.md` §9) rely on isolation: fields reachable only from within the actor's own handlers, external code going through the message interface — a visibility distinction.
- **Interfaces/extensions** (`interfaces.md`) reference "non-private" members and static-extension visibility.
- **Binding forms** (`memory-model.md` §9) flag "access control × binding forms" — e.g. publicly-immutable / privately-mutable fields.

---

## 1. Modules — Open

- **What a module is** — a compilation unit and namespace: a directory, an explicitly declared unit, or a package. Undecided.
- **Separate compilation & the compiled interface** — the unit the share analysis materializes into (binary now, textual option later, `concurrency.md` §5). Its format and what it carries (signatures, shareability, **method mutating-ness**, inlinable bodies, monomorphization info) is undecided. Note: method mutating-ness is **inferred** from the body (`types.md` §3), so it's part of the exported interface even though it's not in the signature text — a body change that flips it is an API-breaking change (the standing argument for an explicit `mutating` keyword later).
- **Packages / dependencies** — how modules are grouped, versioned, and resolved. Undecided.
- **Import / visibility across modules** — how names cross a module boundary.

## 2. Access control — Open

- **Levels** — the set (`public` / `internal` / `private`, and whether a file-scoped level exists). Undecided.
- **Default** — what an unmarked declaration is (leaning `internal`-by-default in the module-visible spirit, undecided).
- **Publicly-immutable / privately-mutable fields** — a field readable outside but writable only inside (Swift's `private(set)`). Referenced by `memory-model.md` §9.
- **Interaction with actor isolation** — how access modifiers compose with the actor's own "internal to the handler" isolation, and with interface/extension visibility.

---

## Open questions

- All of the above. Design when a milestone needs cross-module compilation or a real visibility model — after the M1–M3 core proves out.

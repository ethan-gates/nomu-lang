# Loops

**Status:** surface **Decided (2026-08-03)** — the home for Nomu's iteration construct
(syntax, semantics, lowering). Prompted as a prerequisite of the M9 · 8.4 GC substrate (the loop
back-edge is where 8.4.2's safepoint poll lives; carry-over in `m6-spec.md` §6.0.10), but designed
on its own terms.

**Decisions (2026-08-03).** One pre-tested `while` loop (no `loop`/`repeat` alternate form);
`break` + `continue` (innermost only, no labels); `for … in` deferred until a Range/iterator
surface exists; spawn-in-loop joins **per-iteration** for now, with an open design question below.
Keywords added: **`while`, `break`, `continue`**.

Guiding principle (from `syntax.md`): **one canonical way to write each thing.** Resist a second
loop form for occasional convenience. Performance is a first-class goal — the lowering must give
LLVM a shape it can rotate, unroll, and hoist out of.

---

## Why now

Iteration today is only recursion. Real programs need a bounded, in-place loop, and 8.4 needs a
**back-edge** to hang a safepoint poll on — the canonical case for precise-root scanning (a GC
root held live across a loop-carried safepoint). Landing loops before 8.4.2 keeps that slice from
being left for later.

---

## Surface syntax — proposal

**Land one primitive: `while`.** **Decided (2026-08-03).**

```
while <cond> {
    <statements>
}
```

`<cond>` is a `Bool` expression; the body is a block with its own scope. That is the whole
construct. Rationale:

- **`while` is the irreducible loop.** Every other loop is sugar over it. "One canonical way"
  argues against also adding `loop { }` (write `while true`) or a C-style `for(;;)`.
- **`for … in …` is deferred — Decided (2026-08-03).** A `for` loop iterates a *sequence*, which needs a
  Range type or an iterator interface — and Nomu has no collections/iterator protocol yet (that
  is post-GC stdlib work). Adding `for … in` now would drag in that whole surface prematurely.
  The `in` keyword is **already reserved** in the lexer, so `for x in a..<b` stays open for when
  iterators exist. Until then, a counted loop is `var i = 0; while i < n { …; i += 1 }`.

**Control flow inside the body:** `break` and `continue`. **Decided (2026-08-03).** `break`
exits the innermost loop; `continue` skips to the next iteration.

- **No labeled break / multi-level break** — **Decided (2026-08-03).** It is the "second form for
  occasional convenience" the principle warns against, and nested-loop early-exit is rare enough
  to express with a flag or a helper function that `return`s. Additive to introduce later if real
  code demands it.

Everything below assumes this proposal; alternatives are in **Open questions**.

---

## Semantics

- **Condition re-evaluated each iteration**, before the body; false → the loop exits without
  running the body that iteration. Standard pre-tested loop.
- **Body scope.** The body is a block; `let`/`var` bindings introduced in it are scoped to one
  iteration and do not leak to the next or outward (mirrors `if`/`switch` block scoping already
  in the lowerer).
- **`break`/`continue` are statically bound** to the innermost enclosing loop; using either
  outside a loop is a compile error (sema).
- **Mutation and shareability** are unaffected — a loop introduces no new capture or task
  boundary. The existing mutation inference and `shareable` checks apply to the body as to any
  block.

### Structured concurrency inside a loop (working decision + open question)

A `spawn let` in a loop body starts a child fiber. Structured concurrency guarantees a child
does not outlive its scope; the child's scope here is **the iteration**, not the whole loop.
**Working decision (2026-08-03): per-iteration join.**

- **Spawns declared in the loop body join at each iteration boundary** — at the back-edge
  (`continue` / normal fall-through to the next iteration) and at `break`, and of course at
  normal loop exit.

This differs from the current lowering, which joins active spawns at **function exit** and on
read (`Lowering.swift` `joinActiveSpawns`). Loops require **block-scoped joins**: the set of
spawns created within the body must be joined before the back-edge, then the active-spawn set
restored to what it was on entry. This is the main implementation coupling between loops and
existing runtime semantics — it extends the join model rather than fitting the current one. (The
same block-scoped-join gap technically exists for `if`/`switch` bodies too, but is invisible
there because control leaves the block exactly once; a loop re-enters, which forces the issue.)

**Open design question — keep open; enumerate use cases before locking.** Per-iteration join is
the sound default but has a sharp edge: it makes a *value-producing* spawn read within the
iteration overlap correctly (spawn `f()`, do other work, read the result — join at the read),
while making a *void, fire-and-forget* spawn pointless (joining it at the back-edge serializes
the very work you spawned to overlap). Two consequences to settle:

1. **An unread spawn binding should be a compile error** (proposed 2026-08-03). `spawn let r =
   work()` where `r` is never read in its scope is almost certainly a mistake — today it merely
   joins at scope exit. Requiring a read makes the language express only the case per-iteration
   join serves well (overlap-then-consume). Scope of the rule (loops only vs. everywhere) is TBD.
2. **Void / side-effecting fire-and-forget** (overlap a side effect across iterations) is then
   *not* expressible as `spawn let` (no value to read) and needs its own treatment — a distinct
   bare-`spawn` form with different (non-per-iteration) lifetime, or deferral. Likewise true
   cross-iteration **fan-out** (N parallel children joined after the loop) is a separate future
   construct, not a side effect of `while`.

The through-line (per the performance/soundness directive): pick the lowering that makes each
concrete use case behave the way the author expects. Land per-iteration join now to keep loops
sound and shippable; resolve the fire-and-forget / fan-out spellings as their own design pass.

---

## Sema / typing

- `<cond>` must type as `Bool`; otherwise a diagnostic at the condition's span.
- Track "in a loop" during body checking so `break`/`continue` outside a loop are rejected.
- No new type rules; no interaction with generics/interfaces beyond the condition being `Bool`.

---

## IR representation

Add to `StmtKind` (`IR.swift`):

```
case whileStmt(cond: IRExpr, body: [IRStmt])
case breakStmt
case continueStmt
```

`break`/`continue` carry no target — they bind to the innermost loop, resolved structurally at
lowering (a stack of `(latchBB, exitBB)`). Mirrors how `ifStmt`/`switchStmt` already nest blocks.
The AST gets the parallel node in `AST.swift`, parsed by a `parseWhileStmt` alongside
`parseIfStmt`.

---

## LLVM lowering (`Lowering.swift`)

Standard four-block shape, which LLVM's loop passes recognize and can rotate/LICM/unroll:

```
        br %header
header: %c = <cond>; condbr %c, %body, %exit
body:   <statements>            ; continue → br %latch ; break → br %exit
latch:  <per-iteration spawn joins> ; [8.4.2: safepoint poll] ; br %header
exit:
```

- Push `(latch, exit)` on a loop-context stack for the body; `continue` → `br latch`, `break` →
  `br exit`; pop on exit.
- **Per-iteration spawn joins** at `latch` (and before a `break`'s `br exit`): join the spawns
  created in this body, then restore the enclosing active-spawn set — the block-scoped-join
  extension above. Save/restore `activeSpawns` around the body like `enterThunk` does for its
  other state.
- **Local scoping:** save/restore `locals` around the body (as `lowerIf` already does), so
  body-scoped bindings don't leak across iterations.
- **Debug info (8.3):** `setDebugLoc` on the header from the condition's span, and the body
  statements already self-locate. Stepping lands on the condition then walks the body in order.
- **The `latch` block is the safepoint site for 8.4.2** — a poll (protected-page load or flag
  branch) inserted just before `br %header`. Loops lower with the latch present but **no poll**;
  8.4 fills it. Forward-only dependency: nothing in loop lowering needs GC.

---

## Performance posture

Performance-first shapes three choices:

- **Clean loop shape.** Emit the header/body/latch/exit form so LLVM's canonicalization (loop
  rotation, LICM, unrolling, IV simplification) fires once the `-O` pipeline lands (8.5.3). Avoid
  spilling the condition or IV to memory where an `alloca` would block the mem2reg the optimizer
  wants — reuse the existing alloca-per-local pattern and let mem2reg promote it.
- **Cheap back-edge safepoint.** The per-iteration poll (8.4.2) is the loop's GC tax; it is the
  inert `__nomu_poll` seam at the loop header, which M6 fills with a cheap poll (form open —
  protected-page load vs. branch-on-flag; `m6-spec.md` §6.0.10). Placement: a loop body that already **calls
  or allocates** hits a statepoint each iteration, so its back-edge poll is redundant → elide it
  there; a **call-and-alloc-free** loop reaches no statepoint on its own and **must keep** the poll
  (else a moving GC can't scan it and time-to-safepoint is unbounded). Scheduler fairness for a hot
  loop is handled separately by signal-based preemption, not this poll.
- **Minimal cross-safepoint liveness.** A GC pointer held live across the back-edge poll costs a
  reload; the lowering should not extend a managed reference's live range across the latch beyond
  what the source requires.

---

## Sequencing (relative to 8.4)

Loops are self-contained frontend + lowering work (8.2-class): lexer keyword, parser, AST, sema,
IR node, `Lowering.swift`. They depend on nothing in 8.4 and lower to plain branches with no
safepoint. 8.4.2 then inserts the back-edge poll into the latch. No circular dependency; the only
cross-cutting piece is the block-scoped spawn join, which is loop-owned frontend/runtime work,
not GC. Recommended order: **loops (this doc) → 8.4.0 spike → 8.4.1–8.4.4.**

---

## Resolved (2026-08-03)

- **Keywords** — `while`, `break`, `continue`. **Decided.** (`loop`/`repeat` alternates rejected;
  `while` is conventional and pairs with a future `for … in`.)
- **`for … in` timing** — **Decided: deferred** until a Range/iterator surface exists (post-GC
  stdlib). `while`-only in the interim; `in` stays reserved.
- **Labeled / multi-level break** — **Decided: no.** Innermost-only; additive later if needed.
- **Loop-body spawn lifetime** — **Working decision: per-iteration join** (see "Structured
  concurrency" above).

## Still open

- **Spawn-in-loop use cases** — kept open. Resolve (a) whether an *unread* spawn binding is a
  compile error and at what scope, and (b) the spelling/lifetime for void fire-and-forget and
  cross-iteration fan-out — as their own design pass, before those cases are locked. Per-iteration
  join lands now so loops ship sound; these do not block loop implementation.

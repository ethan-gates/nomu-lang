# Error handling — Zig-style error sets + propagation

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** M ·
**Status:** needs-design — direction decided (copy Zig's error system); mechanism + syntax open ·
**Source:** deferred.md (frontend surface group) + cross-cutting

## Direction

**Copy Zig's error system**, adapted to Nomu. Errors are a dedicated language mechanism — **error sets**
plus **error unions** — rather than a library `Result<T, E>`. The defining properties:

- **Error sets** — an error is a member of a set of named error tags (Zig: `error{NotFound, Timeout}`).
  Errors are **payload-free** tags, not payloaded values (Zig's model; a consequence to confirm — Zig
  compensates with out-params and error-return traces rather than attaching data to the error).
- **Mostly inferred, explicitly possible.** A function's error set is **inferred** by default from the
  errors it can produce or propagate (Zig's inferred-error-set `!T`), so most code never writes a set.
  **Explicit** named sets and annotations are available when a function wants to pin or narrow its error
  surface (API boundaries, exhaustive handling).
- **Error unions** — a result is either a success value `T` or an error from the set. (Zig spells this
  `E!T` / `!T`; the Nomu spelling is open — see below.)
- **Propagation is in scope and explicit.** The propagate-or-return behavior that Rust's `?` and Zig's
  `try` provide is a first-class part of this task: at a call that yields an error union, propagate the
  error to the caller (widening the caller's inferred set) or bind the success value. **Syntax is open and
  will not be the `?` operator** — likely a prefix keyword in the Zig `try` family, but the exact spelling
  needs agreement before anything lands.
- **Handling** — a `catch`-style form (supply a default or handle the error inline) and an
  **`errdefer`-style** cleanup that runs only on the error path. Spellings open.

## Reconcile with shipped `Result`

M5 shipped `Result<T, E>` as a library sum type. The Zig model makes error unions the idiomatic
error-carrying type, so `Result`'s role must be reconciled: either the error union supersedes `Result` for
error handling (and `Result` is retired or demoted to a plain sum type for non-error uses), or `Result`
stays and the error union is the surface over it. Leaning toward the error union as the primitive; settle
when the mechanism is designed.

## What's open (needs design + agreement)

- **Syntax** — the error-union type spelling, the propagation keyword (not `?`), and the `catch`/`errdefer`
  spellings. New surface, so each needs sign-off (per the no-unapproved-syntax rule).
- **Payload-free errors** — confirm Nomu accepts Zig's no-data-on-errors stance, and the out-param /
  diagnostic story that goes with it.
- **Inference across modules** — an inferred error set crossing a module/package boundary interacts with
  the `.nmi` interface (an inferred set becomes part of the published signature); decide whether public API
  must pin an explicit set.

## Dependencies & triggers

- **Interacts with:** [110](110-pattern-matching.md) pattern matching (binding + exhaustive error handling),
  [116](116-optional-ergonomics.md) optional ergonomics (the success-bind / early-return forms), the
  error-return ABI (the one midend/backend touch — how an error union is returned and propagated), and the
  module interface (164/173) where an inferred error set enters a published signature.

## Refs

Zig language reference — error sets, error unions, `try`/`catch`/`errdefer`, inferred error sets.
`types.md` §5 (errors); deferred.md "Frontend surface features".

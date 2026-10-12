# Substring — zero-copy string span

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · stdlib` · **Size:** M · **Status:** design
decided (model below); build not started — no blocker, pull when text processing needs non-copying slices.
Split out of [121 String/UTF-8 model](121-string-utf8-model.md), which reserved the first-class byte-access op
on `StringBase` precisely so `String` and `Substring` can share it. · **Source:** the deferred `Substring`
sub-decision of 121.

## Goal

A **zero-copy slice over a `String`'s bytes**. Slicing returns a `Substring` by default — no allocation, no
copy — and copying to an independent `String` is explicit. This encourages the cheap path and makes the
expensive one visible, the opposite of a slice that silently allocates.

## Model (decided)

**Swift's model, GC-backed — not Rust's borrow+lifetime model.** Both languages make the default slice a
non-copying view with an explicit conversion to own (Rust `&s[i..j]` → `&str`, `.to_owned()` to copy; Swift
`s[range]` → `Substring`, `String(sub)` to copy). They differ in how the view stays valid: Rust is a
compile-time **borrow** (the borrow checker proves the source outlives the slice; lifetimes are explicit in
the type system), Swift is runtime **retention** (the `Substring` holds the storage alive via COW, no
lifetimes). Nomu's thesis is memory-invisible — ownership and lifetime are inferred, never spelled — so the
Rust model is out (it would drag borrow-checker machinery into the surface). Swift's model fits, and Nomu's
tracing GC makes it cheaper than Swift's: where Swift pays a COW refcount to keep the parent alive, Nomu's GC
already tracks that reachability, so a `Substring` keeps its parent's buffer alive simply by being reachable.

- **Representation:** `struct Substring { let base: StringBase; let start: Int; let length: Int }` — the
  16-byte `StringBase` plus a byte range, indexing into the base's bytes. A `heap` base keeps `word0` pointing
  at the buffer, so the GC keeps that buffer alive through the `Substring`'s `base` field (the shaped-field
  case, already handled by [176](176-shaped-gc-roots.md) 176.3 — a value aggregate holding shaped content). A
  `small` base carries its inline bytes **by value** in `base`, so there is no borrow-of-a-register problem;
  the same layout handles both uniformly.
- **Slicing returns a `Substring`** (zero-copy). The range is validated on byte boundaries via the bounds
  machinery ([183](183-precondition-bounds-checks.md)); scalar/grapheme-boundary slicing arrives with the
  views ([184](184-string-unicode-views.md)).
- **`String(sub)` is the explicit copy** — builds a fresh, right-sized `String` from the slice's bytes and
  drops the hold on the parent, so the parent buffer can be collected if otherwise dead.
- **Distinct type from `String`** — this is the nudge: a `Substring` can't be stored where a `String` is
  expected without the explicit `String(sub)`, so copies are visible.
- **Retention tradeoff (accepted, as in Swift):** a short slice of a huge `String` pins the whole parent
  buffer until `String(sub)` right-sizes it. The explicit conversion is the right-size point; guidance is
  that substrings are transient and you convert to `String` for storage.
- **Shared byte access:** `count` / `byte(at:)` / iteration read through `base` + `start`, reusing the
  `StringBase` byte-access op that 121 put there for exactly this.

## Open

- A shared `StringProtocol`-style abstraction so generic code accepts `String` *or* `Substring` uniformly
  (Swift's `StringProtocol`, Rust's `AsRef<str>`). Deferred until generic text code wants it; the distinct
  types stand alone first.
- Whether slice indices are byte offsets only (now) with scalar/grapheme-indexed slicing layered on
  [184](184-string-unicode-views.md)'s opaque indices later.

## Dependencies

- **Built on:** [121 String/UTF-8 model](121-string-utf8-model.md) — the byte layer and the first-class
  `StringBase` byte-access op; [176](176-shaped-gc-roots.md) 176.3 (a `Substring` is a value aggregate with a
  shaped `base` field, GC-scanned there).
- **Couples with:** [184 Unicode views](184-string-unicode-views.md) (scalar/grapheme-boundary slicing),
  [183 bounds checks](183-precondition-bounds-checks.md) (slice-range validation),
  [117 `for … in`](117-for-in-iteration.md) (iterating a substring's bytes/scalars).
- **Rests on:** the tracing GC keeping the referenced parent buffer alive — no lifetimes, no refcount.

## Refs

[121 String/UTF-8 model](121-string-utf8-model.md) *Type layering* (the `Substring`-shared byte-access op);
Swift `Substring` / `StringProtocol`; Rust `&str` / `to_owned`.

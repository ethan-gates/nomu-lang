# Public compile-time constants

**Avenue:** Usability · **Type/Lifecycle:** `language · needs-design` · **Size:** S · **Status:** needs-design ·
**Source:** [223](223-retire-the-c-floor.md).1, which limits every global to `private` or `internal`.

## What

223.1 makes globals module-private: a global is a constant or an actor reference, and
`package` or `public` on a global is an error. A constant whose value folds at compile time has none of the
problems that motivate that limit (no state, no initialization order), and libraries want to export them
(sizes, limits, version numbers). Decide whether `package` and `public` are allowed on compile-time
constants, and what a dependent module may assume about one (inlined at its use sites, so changing it
means recompiling dependents, or referenced by symbol).

## Refs

[223](223-retire-the-c-floor.md).1; `../../language/modules.md` (Visibility; Initialization & entry point).

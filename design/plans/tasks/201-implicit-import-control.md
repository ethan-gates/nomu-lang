# Implicit import control — opting out of or narrowing the implicit `import std`

**Avenue:** Usability · **Type/Lifecycle:** `language · modules · needs-design` · **Size:** M · **Status:**
needs-design · **Source:** [190](190-explicit-module-builds.md) 190.6 F11, which kept the implicit
`import std` for every file outside the language workspace, pinned workspaces included.

## Deliverable

A way for a package (or module, or file; the scope is part of the design) to control the implicit
`import std`, covering the use cases below, with the default unchanged: every file outside the language
workspace gets the implicit import (`modules.md` §Imports).

## Use cases

1. **No `std`.** Code that must not depend on the standard library at all: low-level packages, code that
   supplies its own foundations, targets where `std` is unavailable.
2. **`std` required explicitly.** Some authors want every import written out. Their resolved imports are
   identical to the implicit route; only the spelling differs. The implicit import is turned off and a file
   that uses prelude names without `import std` is an error.
3. **Granular selection.** Take part of what the implicit import brings and leave the rest, for example
   strings but no arrays.

## Questions for the design

- Where control lives: the package manifest (`pkg.json`), the workspace (`nomu.yaml`), per module, or per
  file. Any new syntax or manifest key needs agreement before it is added.
- How each case interacts with the rest of the system:
  - Case 1: what still works without `std` (the compiler-backed types in the language workspace's `core`,
    which user code cannot import, and anything the code generator assumes from `std`).
  - Case 2: whether it is a lint-like check (same resolution, stricter spelling) or a change to resolution.
  - Case 3: the units of selection. Today `std/prelude` is one module; granular selection may mean
    splitting it, or filtering names from it.
- Dependencies: a package that turns off `std` may depend on packages that use it; whether that is allowed,
  and what the dependent package then sees.
- Diagnostics: a file using a prelude name it cannot see should get a message that names the setting
  responsible.

## Relationships

- **190** 190.6 F11: the current rule and its reasoning (one meaning per workspace wherever it is built).
- **174** (prelude as packages) defined `std/prelude` as the module the implicit import names.
- F7 (190.6): the language workspace's `core` does not exist to user workspaces; case 1 must work within that
  rule.

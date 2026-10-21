# Symbol encoding — one injective mangling for every symbol family

**Avenue:** Risk (correctness) · **Type/Lifecycle:** `codegen · ready-to-build` · **Size:** M–L ·
**Status:** ready-to-build — encoding decided · **Source:** [190](190-explicit-module-builds.md) 190.6 F2,
moved here when 190 closed.

## Problem

`Mangle.qualifier` joins origin components with `_`, and components may contain `_`, so `a_b/c` and
`a/b_c` give the same qualifier. The boundary between qualifier and name collides the same way: `fun
helper` in module `app/util` and `fun util_helper` in module `app` are both
`nomu_fn_<ws>_app_util_helper`. Generic instances use a second scheme (raw `/`, `@`, `<`, `>`, `,`, as
`Monomorphize` builds them), so producer and consumer names come from two code paths. The entry module and
the runtime both use bare names, and the actor and spawn thunks take no qualifier. A collision between
strong symbols fails the link; one involving a weak symbol (a generic specialization, the runtime's
weak-ODR set) silently links the wrong definition.

## Decided — the 9-escape of `backend.md` §3, built as specified and extended

A symbol is a family prefix (`nomu_fn_`, `nomu_m_`, `nomu_on_`, the thunk prefixes), then its parts joined by
`_`: the module path components, then the declaration parts. Within a part, `_` → `90`, `.` → `91`, `<` →
`93`, `>` → `94`, `,` → `95`, `:` → `96`, and the escape `9` → `99`; letters and other digits stay as they
are. A raw `_` is therefore always a join, and every `9` starts an escape pair, so the encoding is injective.
Each family has a fixed number of declaration parts (function 1, method 2: type and member), so the module
path is everything before them. Nested type names and accessors stay inside one part (`Outer91Inner`,
`isEmpty96get`). Generic instances escape their argument lists inside the name's part, with qualified type
arguments encoded the same way. Examples: `nomu_fn_acme_shop_app_util90helper` (`fun util_helper` in `app`)
against `nomu_fn_acme_shop_app_util_helper` (`fun helper` in `app/util`);
`nomu_m_nomu_nomu_std_prelude_String_isEmpty96get`.

**Why.** Weighed against Itanium-compatible length-prefixed names (free demangling in every tool, at
the cost of `::`-separated scopes and markers for families), raw structural delimiters (shortest,
but invalid C identifiers that need quoting in lldb) and an identity hash (only probabilistically
injective). The 9-escape keeps names valid C identifiers, reads like the source wherever names are
camelCase, and is within about 3% of the length-prefixed form on real symbols. The demangling
integration is ours to build.

## Work

- **203.1 — one encoder.** Every symbol family goes through it: free functions, methods, accessors, `on`
  handlers, actor and spawn thunks, generic instances (replacing `Monomorphize`'s raw names), and
  descriptors or type ids if they embed names (audit first).
- **203.2 — the entry module is qualified** like any other; only the runtime's pinned C-ABI names stay
  bare.
- **203.3 — demangler and debugger.** `nomu demangle`, or a filter in the style of `c++filt`, for `nm`,
  crash logs and profiles; lldb integration (a script or plugin that shows demangled names). Scope to be
  set when 203.3 starts.
- **203.4 — tests.** A fixture per collision (component boundary, qualifier/name boundary, generic
  instance in two consumers), each linking and calling the intended function; demangler round-trips over
  every family.

## Open

compressing the module paths repeated in generic arguments, once symbol size is measured
(`backend.md` §3 "Compression" already allows a selective form).

## Refs

`backend.md` §3 (mangling, compression); `Mangle.qualifier`; `Monomorphize` (instance names);
[190](190-explicit-module-builds.md) 190.6 F2 (where this was found and decided).

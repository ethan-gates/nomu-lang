# Symbol encoding — one injective mangling for every symbol family

**Avenue:** Risk (correctness) · **Type/Lifecycle:** `codegen · ready-to-build` · **Size:** M–L ·
**Status:** done — Rust v0 mangling built · **Source:** [190](190-explicit-module-builds.md) 190.6 F2,
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

A second collision of the same kind, found when 203 started: **GC descriptors** are named after a type's
bare name (`nomu_gc_desc_Node`) and are weak so copies fold. Two modules that each declare a `class Node`
with different fields both define a weak `_nomu_gc_desc_Node`; the binary keeps one, and the collector
scans one module's objects with the other's pointer map (an untraced field dangles after a moving
collection). Reproduced with two modules whose `Node`s hold `String, Int` and `Int, Int`.

## Decided — Rust's v0 mangling, a subset

Symbols follow Rust's v0 scheme ([RFC 2603](https://rust-lang.github.io/rfcs/2603-rust-symbol-name-mangling-v0.html)):
`_R` then a path, every identifier length-prefixed, so the encoding is injective with no escape table.
The system `c++filt`, LLVM's demangler (lldb), gdb and `perf` demangle it, so there is no demangler of our
own to build. The subset:

- **Module path.** The crate root is the workspace scope, then each further component in an internal
  namespace `m`: `C4acme` `Nm…4shop` `Nm…3app` `Nm…4util`. A workspace's scope and name already match
  `[a-z][a-z0-9_]*`.
- **Functions** `Nv <module> <name>`; **types** `Nt <module> <Type>`, nested types `Nt <Outer> <Inner>`;
  **methods and `on` handlers** `Nv <type path> <method>`; an **accessor** `isEmpty:get` is
  `Nv (Nv <type> 7isEmpty) 3get`. Modules (`m`), types (`t`) and values (`v`) are distinct namespaces, so a
  module `app/util/Rect` and a type `Rect` in `app/util` never meet.
- **Closures and spawn routines** (`clo:N`, `spawn:N`) are closure paths `NC <module> [s…] <name>`, with
  the index as v0's disambiguator; a spawn routine's name is `spawn`.
- **Generic instances** wrap the path: `I <path> <type args> E`. Type arguments: `Int` `x` (i64), `UInt8`
  `h`, `UInt64` `y`, `Double` `d`, `Bool` `b`, `Void` `u`, `String` `e` (str), `RawPtr` `Pu`, `Ptr<T>`
  `P<T>`, `Array<T>` `S<T>` (a slice), a function type `F … E <ret>`, `any I` and compositions `D … E L_`
  (dyn), a named type its path (with its own `I … E`). Reserved paths directly under `C4nomu` (no real
  type sits there, since every module path has at least the workspace name below the crate) hold the rare
  rest: a type parameter, `Self`, `some I`.
- **GC descriptors and pointer maps** are a reserved generic path naming the kind and the type:
  `I Nd C4nomu 4desc <type> E`, `… 6ptrmap …`, and `arraybuf`, `managedbuffer`, `spawnbox`, `msg` likewise;
  singletons (`anybox`, `mailbox`, `arrayhandle`, `string`) are `Nd C4nomu <kind>`.
- **Unchanged:** `nomu_main` (the C runtime calls it); the `runtime` package's bare `nomu_fn_<name>` names
  (C pins them, and a bare name never begins with `_R`); internal symbols (witness tables, VWTs), which
  cannot collide across objects. The actor and spawn thunks become internal.
- A name holding characters outside an identifier keeps its raw bytes, length-prefixed: still injective,
  left mangled by demanglers.

**Why.** Considered: the 9-escape (a code table and a demangler of our own), Itanium C++ (no way to tell a
module from a type, so `Rect.area` and module `Rect`'s `area` collide; names read as C++). v0 was designed
for a language with modules and generics, separates namespaces, and is read by the tools in use; the
project prefers adopting a working scheme over building its own.

## Work

- **203.1 — one encoder.** Every symbol family goes through it: free functions, methods, accessors, `on`
  handlers, closures, generic instances (their `Monomorphize` names parsed into paths and type
  arguments), and GC descriptors and pointer maps (the collision above). The actor and spawn thunks become
  internal.
  *Done:* `src/mangle` (`Mangle`), its own library so its tests need no LLVM. Every external family goes
  through it: `Mangle.function`, `Mangle.method` (methods, `on` handlers, accessors), closures and spawn
  routines, generic instances (Monomorphize's names parsed back into a head and arguments), and
  `Mangle.descriptor` / `pointerMap` for every GC descriptor kind. `LLVMGen.homeModule` (the job's origin)
  replaces the qualifier string. Decided along the way:
  - **Type arguments resolve against the compiling module:** a bare type name in a specialization is the
    compiling module's own type, so `lib@keep<Item>` in two consumers names two different `Item`s.
  - **Bare imported names stay bare:** an imported function with no origin is a runtime function.
  - **Accessors** (`count.get`) split on `.` and `:` into nested value paths.
- **203.2 — the entry module is qualified** like any other; only the runtime's pinned C-ABI names stay
  bare. *Done:* binaries pass their origin as the home module; `main` stays `nomu_main`.
- **203.3 — tools.** Check that `nm -C`/`c++filt`, lldb (breakpoints, backtraces) and crash logs show
  demangled names for every family; no demangler of our own. *Done:* `c++filt` reads every family (the unit
  tests check its output), `nm -C` likewise, and lldb sets breakpoints by name (`b helper`) and shows
  demangled backtraces.
- **203.4 — tests.** A fixture per collision (component boundary, qualifier/name boundary, generic
  instance in two consumers, two modules' same-named types under a collecting GC leg), each linking and
  calling the intended function; unit tests of the encoder per family, checked against `c++filt`.
  *Done:* `mangle-module-boundary` (`util_helper` in `lib` and `helper` in `lib/util`),
  `mangle-same-type-name` (two `Node` layouts under GC stress) and `mangle-generic-two-consumers` (`keep<Item>`
  for two consumers' `Item` structs of different sizes); `//src/mangle:mangle_tests` covers every family and
  the former collisions. The suite passes on both tiers.

## Open

Compressing repeated paths with v0's backreferences (`B`), once symbol size is measured.

## Refs

`backend.md` §3 (mangling, compression); `Mangle.qualifier`; `Monomorphize` (instance names);
[190](190-explicit-module-builds.md) 190.6 F2 (where this was found and decided).

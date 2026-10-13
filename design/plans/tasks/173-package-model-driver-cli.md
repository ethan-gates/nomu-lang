# Package model, manifest + driver CLI

**Avenue:** Infra (+ Usability) · **Type/Lifecycle:** `language-feature · needs-design` (driver + build
orchestration + a thin Sema/codegen touch) · **Size:** L · **Status:** needs-design (partially built) ·
**Source:** pulled out of [100](100-modules.md) §100.3.1–100.3.6. The compilation model (separate
compilation, module = CU) is built (100.1/100.2/100.4); this is the package structure and the usable build
tool layered **around** that compiler. It sits mostly outside the compilation pipeline — manifest parsing,
package/workspace discovery, the CLI, build orchestration — with a thin touch into Sema (entry validation)
and codegen (ordered global init).

Programmer surface + the compilation model are settled in the contract doc
[`../../language/modules.md`](../../language/modules.md); this task carries the package/manifest/driver
implementation.

## Why its own task (out of 100)

Task 100's remaining in-house work is the compilation model itself (100.5, the specialization dial). The
package model + build tool is an independent layer — its prerequisites (100.1/100.2/100.4) are done, nothing
in 100.5 depends on it, and it is overwhelmingly driver/orchestration rather than compiler-pipeline work.
Pulling it out keeps 100 focused on the separate-compilation architecture. Prelude-as-packages (the one
architectural piece of the old 100.3) is its own task [174](174-prelude-as-packages.md); the suite migration
to 1 dir == 1 module folds into [155](155-integration-suite-harness.md).

## Deliverable

`nomu build` / `run` / `test` on a manifest'd package with multiple bins (the binary is renamed from
`nomuc`; see 173.5.1).

## Phases

- 173.1 — **Manifest** in **JSON** (dependency-free in the Swift host; switch to YAML later,
  [163](163-manifest-yaml.md)) + schema: name, version, `default-module`, `sealed`, `bin`, tests (deps later).
  **Done (schema):** the full contract decodes (`src/modules/sources/Manifest.swift`) — `name` required,
  `version`/`default-module`/`sealed`/`bin` (`{name, module}`)/`tests` (`{module}`) optional, every section
  past `name` defaulting so a name-only manifest stays valid; absent → default package `main`;
  present-but-malformed is fatal. `default-module` is the leaf module a bare package name forwards to
  (modules.md §First-party addressing). Unit tests in
  `src/modules/tests`. The two-file scheme is settled (modules.md §Manifest): **package → `pkg.json`**,
  **workspace → `nomu.yaml`** (repo root), **module → no file**. **Open policy:** keep requiring a manifest
  and erroring when absent (drop the default) once the fixtures/tooling assume one — now unblocked by the 155
  migration, still deferred so loose single-file programs compile.
- 173.2 — **Package boundary** (manifest presence); workspace (root + members); package identity. **Done
  (package half):** the package root is the nearest `pkg.json` ancestor (`findPackageRoot`,
  `src/driver/sources/Driver.swift`), falling back to the `nomu.yaml` workspace marker, then the entry's
  directory; package identity comes from that `pkg.json`'s `name`. It anchors `pkg/…` addressing and module
  identity. **Deferred:** the workspace section's contents (member packages, one resolved version per external
  dependency) — not exercisable until cross-package linkage exists, so `nomu.yaml` is a marker only; designed
  with the external-package work (173.3.1).
- 173.3 — **Seal enforcement** (sealed module not importable outside package; symbols capped at package).
  - 173.3.1 — **`package`-tier visibility across the package boundary** (the multi-package half of 100.2.5,
    deferred there until cross-package linkage exists). Today only `public` reaches a `.nmi`, so a `package`
    symbol behaves like `internal` across a module — wrong once siblings compile separately. When
    multi-package lands: emit `package` symbols into the `.nmi` **tagged with their visibility**, have a
    consumer admit a `package` (or sealed) symbol only when it shares the producer's package (deny it to a
    foreign package with a clear diagnostic), and fold package identity into the mangling qualifier (the
    `Mangle.qualifier` package-identity item carried forward from 100.4). The single-package
    signature-consistency guard (100.2.5) already stands; this closes the cross-boundary half.
- 173.4 — **Entry points.** **`main` detection + declarations-only enforcement: already satisfied.** `main`
  lowers to the fixed `nomu_main` entry symbol and the entry object requires it (`loweredMain`); the grammar
  admits only declarations at the top level (`declStart` has no `let`/`var`/statements), so there is no
  top-level executable code to reject. A module with a `main` **is** an executable (`loweredMain` /
  `nomu_main`); `build`/`run` target it by path, so no declaration is needed. **`bin` declarations deferred
  to distribution/install** (modules.md §Initialization & entry point): the manifest's `bin` list is a
  package's shipped-executable manifest (names + modules), useful for install/distribution and renamed
  binaries, carried in the schema but unconsumed until that lands. **Ordered-eager
  global init: deferred** — the language has no global-variable surface yet (no top-level `let`/`var`), so
  there is nothing to initialize; the module-topological init-order emission (the one real codegen touch)
  comes when globals do.
- 173.5 — **Single-binary driver:** the `nomu` uber-CLI over the `compile` primitive; compile-logic-as-library;
  in-process build orchestration over the module graph. The driver is `nomuc <file>` today; the subcommands
  wrap the primitive, which stays. Broken down by command (build order 173.5.1 → .4):
  - 173.5.1 — **CLI skeleton + `compile` primitive.** **Done — suite 133/133 green.** _Rode
    [186](186-cli-argument-parser.md) (the dependency-free subcommand arg parser)._ The `nomuc` binary is
    retired and renamed `nomu`; every entry is a subcommand — `nomu compile|build|run|test|query` (the
    command tree in `src/nomu-cli/sources/main.swift`). `compile` is the exposed primitive; `build`/`run`/
    `test`/`query` exist in the help with a "not yet implemented" stub pending their phases. Each subcommand
    parses its own arguments, so compile's flags stay isolated. The compile primitive is invocable **both
    ways**: as a subprocess (`nomu compile …`, the form the integration harness now uses) and **in-process** —
    `compile(...)` returns `Bool` instead of calling `exit`, so `build`/`run` can drive it without spawning.
    The root alias and `tools/install` were re-pointed to `:nomu`. **Residual:** `compile()`'s deep helper
    fatals (codegen/link) still `exit`; converting them to returns for full in-process resilience rides
    173.5.2 (where the in-process build loop exercises them). A `nomuc`→`nomu` sweep of the legacy
    `tools/*.sh` dev scripts + doc build commands is a non-blocking cleanup (those are off the build graph).
  - 173.5.2 — **`build`.** **Core built + green (suite 133/133).** `nomu build [targets…]` resolves each
    target directory to a **single module** and builds it in-process (`buildTarget` in `Driver.swift`, over
    the `compile(...)` library form), naming the binary after the module (not the `main.nomu` entry file).
    Resolution (modules.md §First-party addressing): a package root with root-level source → that root
    module; a container package root → its `default-module` (error if none); any other directory → that leaf
    module. Default target is the current directory. The `build` subcommand takes `-O`/`--mono`.
    **Deferred within the phase:** recursive/multi-module targeting (`//path/...`), so "build the whole
    package" waits for the label surface; `compile()`'s deep helper fatals still `exit` (harden to returns
    when the multi-target loop needs per-target resilience); `examples/pkg.json` executable declarations land
    with `run` (173.5.3). Not bin-centric: `bin` declarations name executables, they do not gate what builds;
    library-/test-only packages build fine.
  - 173.5.3 — **`run`.** **Done — path-based, suite green.** `nomu run [target] [-- args]` resolves the
    target to a module (the same resolver as `build`; default: the cwd), builds it, and execs the binary,
    forwarding the post-`--` args and propagating the exit status (`runTarget` in `Driver.swift`). A module
    with no `main` is not executable and errors. **No `bin` declarations or `--bin` selection** — targeting
    is by path (`nomu run pkg/server`), since a binary module sits shallow (`<pkg>/<name>`) and the path is
    the name. The compiler's artifact-path diagnostics moved from stdout to stderr, so `run`'s stdout is the
    program's alone.
  - 173.5.4 — **`test`.** Build the manifest's test modules with white-box `test import` visibility widening;
    the case runner + test-case designation stay in the test-framework task ([161](161-test-framework.md)), so
    this phase builds + links test modules and stops short of a runner.
- 173.6 — **`query`** — the subcommand (wired on the 173.5.1 dispatch) + its metadata: package → modules +
  inter-module dep edges + external deps.
- 173.7 (tests) — Package builds; multiple bins; `run`/`test`; seal enforcement; init order. (The suite-wide
  **1 dir == 1 module** migration is [155](155-integration-suite-harness.md)'s, not this task's.)

## Dependencies & triggers

- **Rides:** 100.1/100.2 (multi-file + multi-module, done), 100.4 (separate compilation + per-module objects +
  link, done), the name-only manifest loader (present).
- **Feeds:** [161](161-test-framework.md) test framework (needs test-module identity + the `test`
  subcommand), [160](160-resource-embedding.md) resource embedding (manifest `include`), [163](163-manifest-yaml.md)
  (JSON → YAML), [137](137-tooling-lsp-formatter.md) (the `query` server reasons over the package graph).
- **Interacts with:** [174](174-prelude-as-packages.md) (prelude/`std` become packages in the same package
  model), [155](155-integration-suite-harness.md) (the manifest-required policy is decided alongside the
  suite migration), [100](100-modules.md) (the 173.3.1 `package`-tier + qualifier item was carried forward
  from 100.4's interims).

## Refs

[`../../language/modules.md`](../../language/modules.md) (the programmer surface + compilation model);
[100](100-modules.md) §100.3.1–100.3.6 (the pulled-out phases), §100.2.5 (the single-package visibility
guard this builds the cross-package half of); `src/driver/sources/Driver.swift` (the current driver + the
name-only manifest loader).

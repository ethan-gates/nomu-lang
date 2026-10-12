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
  [163](163-manifest-yaml.md)) + schema: name, version, `sealed`, `bin`, tests (deps later). **Done (schema):**
  the full contract decodes (`src/modules/sources/Manifest.swift`) — `name` required, `version`/`sealed`/`bin`
  (`{name, module}`)/`tests` (`{module}`) optional, every section past `name` defaulting so a name-only
  manifest stays valid; absent → default package `main`; present-but-malformed is fatal. Unit tests in
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
  top-level executable code to reject. **`bin` declarations + root-`main` shorthand:** the live piece,
  consumed by `build` — it lands with 173.5.2 (building it standalone yields an inert bin list). **Ordered-eager
  global init: deferred** — the language has no global-variable surface yet (no top-level `let`/`var`), so
  there is nothing to initialize; the module-topological init-order emission (the one real codegen touch)
  comes when globals do.
- 173.5 — **Single-binary driver:** the `nomu` uber-CLI over the `compile` primitive; compile-logic-as-library;
  in-process build orchestration over the module graph. The driver is `nomuc <file>` today; the subcommands
  wrap the primitive, which stays. Broken down by command (build order 173.5.1 → .4):
  - 173.5.1 — **CLI skeleton + `compile` primitive.** _Rides [186](186-cli-argument-parser.md) (the
    dependency-free subcommand arg parser), built first._ Retire the `nomuc` binary and rename it `nomu`; every
    entry is a subcommand — `nomu compile|build|run|test|query`. `compile` is the exposed primitive but the
    easy path is `build`/`run`/`test`/`query`; each subcommand parses its own arguments, so compile's flags
    stay isolated from the orchestration flags. The compile primitive is invocable **both ways**: as a
    subprocess (`nomu compile …`, the form the integration harness uses) and **in-process** — a library entry
    (`compile(...)`) that reports success/failure instead of calling `exit`, so `build`/`run` can drive it
    without spawning. Foundation for the rest.
  - 173.5.2 — **`build`.** Manifest-driven: build every declared `bin` in the package at/above the target
    directory — resolve each bin to its module, gather the module's files, compile + link to the bin's output,
    in-process over the module graph. Consumes 173.4's `bin` declarations + the root-`main` shorthand (the live
    half of 173.4 lands here), and populates `examples/pkg.json`'s bin list as the first real multi-bin package.
  - 173.5.3 — **`run`.** Build a selected bin (by name, or the single declared bin / root-`main` shorthand) and
    exec it, forwarding arguments + exit status.
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

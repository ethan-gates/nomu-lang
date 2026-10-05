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

`nomuc build` / `run` / `test` on a manifest'd package with multiple bins.

## Phases

- 173.1 — **Manifest** in **JSON** (dependency-free in the Swift host; switch to YAML later,
  [163](163-manifest-yaml.md)) + schema: name, version, `sealed`, `bin`, tests (deps later). Interim file
  name `pkg.json`; root still marked by `nomu.yaml` (both subject to change). **Partial:** a minimal
  name-only manifest already loads; absent → default package `main`. **Open policy:** keep requiring a
  manifest and erroring when absent (drop the default) once the fixtures/tooling assume one — decide when the
  whole suite migrates to 1 dir == 1 module ([155](155-integration-suite-harness.md)).
- 173.2 — **Package boundary** (manifest presence); workspace (root + members); package identity. **Partial:**
  single-package identity via the name-only manifest; workspaces not built.
- 173.3 — **Seal enforcement** (sealed module not importable outside package; symbols capped at package).
  - 173.3.1 — **`package`-tier visibility across the package boundary** (the multi-package half of 100.2.5,
    deferred there until cross-package linkage exists). Today only `public` reaches a `.nmi`, so a `package`
    symbol behaves like `internal` across a module — wrong once siblings compile separately. When
    multi-package lands: emit `package` symbols into the `.nmi` **tagged with their visibility**, have a
    consumer admit a `package` (or sealed) symbol only when it shares the producer's package (deny it to a
    foreign package with a clear diagnostic), and fold package identity into the mangling qualifier (the
    `Mangle.qualifier` package-identity item carried forward from 100.4). The single-package
    signature-consistency guard (100.2.5) already stands; this closes the cross-boundary half.
- 173.4 — **Entry points:** `main` detection, `bin` declarations, root-`main` shorthand; declarations-only
  enforcement; ordered-eager global init in module-topological order. **Partial:** `main` runs today; `bin`
  stanzas / init-order emission not built. (The init-order emission is the one real codegen touch in this
  task.)
- 173.5 — **Single-binary driver:** `compile`/`build`/`run`/`test`/`query`; compile-logic-as-library;
  in-process build orchestration over the module graph. The driver is `nomuc <file>` today; this is the
  uber-CLI refactor (the `compile` primitive stays; the subcommands wrap it).
- 173.6 — **`query` metadata** (package → modules + inter-module dep edges + external deps).
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

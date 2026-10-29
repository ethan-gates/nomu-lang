# White-box runtime tests through `test import` — retire the runtime prelude copy

**Avenue:** Infra · **Type/Lifecycle:** `driver · tests · ready-to-build` · **Size:** S–M · **Status:** ready to build ·
**Source:** found during [159](159-gc-observability.md).2: the recorder's fixture compiles a copy of the
runtime into the fixture's module, under the fixture's configuration, instead of testing the `runtime`
module programs link.

## Today

The runtime is the language workspace's `runtime` package ([174](174-prelude-as-packages.md)). Suite
fixtures that call its internals by name (`rtImmixNew`, `rtAcquireBlock`, `rtRecNew`, …) cannot reach them
through `import`, so 174.5 kept an opt-in copy: `test.runtime_prelude` (the `rt_prelude` config) prepends
the runtime's source to the fixture's module (`prependRuntimePrelude`, `CompileSupport.swift`), its
weak-ODR definitions folding with the package's at link. 20 suite cases use it: `mark-verify`,
`mark-verify-arr`, `walk-mark`, `walk-multiframe`, `stw-selfhost`, `stw-running`, `immix-region`,
`rt-prelude`, `immix-defrag`, `immix-evac`, `immix-forward`, `immix-line-mark`, `immix-sweep`,
`gen-barrier`, `gen-nursery`, `gc-record`, `gc-record-off`, `gc-record-minor`, `gc-record-major`,
`gc-record-stress`.

The copy compiles under the fixture's configuration (debug), so these cases test a build of the runtime no
program links, and settings meant for the runtime module act on the copy instead.

## Can `test import` do it

Not as it stands. `test import` is same-package only (`Resolution.swift`: "'test import' may not cross a
package boundary"), and the fixtures are in the `nomu_lang` workspace, outside the `runtime` package. The
rest is in place: a `test import` target is built white-box (`ModuleJob.whiteBox`, its interface carrying
internals, under its own key), so a fixture that may `test import` the runtime reaches its internals and
links the runtime module itself.

## What

A suite-only exception, on the pattern of the hidden `--allow-core-import`: a hidden flag lets a fixture
`test import` the language workspace's `runtime` package across the package boundary. Everywhere else the
rule stands. The 20 fixtures switch from `rt_prelude` to `test import`, and `test.runtime_prelude`,
`prependRuntimePrelude` and the `rt_prelude` config are deleted.

## Work

- **220.1** The exception: the hidden flag, the resolution change, a test that a fixture without it is still
  refused.
- **220.2** Move the 20 fixtures to `test import` and check each still passes; note any that depended on
  the copy compiling under the fixture's configuration.
- **220.3** Delete `test.runtime_prelude`, `prependRuntimePrelude`, the `rt_prelude` config and the suite
  setting.

## Open question

1. **Runtime-subset designation.** The copy designated its functions runtime-subset by name; the package
   designates them by membership. Check that a white-box build of the package keeps that designation.

## Refs

`prependRuntimePrelude` (`src/driver/sources/CompileSupport.swift`), `test import` resolution
(`src/planner/sources/Resolution.swift`), `allowCoreImport` (`src/planner/sources/Plan.swift`);
[174 prelude as packages](174-prelude-as-packages.md) (174.5).

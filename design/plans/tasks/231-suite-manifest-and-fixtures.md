# Suite manifest and fixtures — YAML by area, a local run order, fewer and denser fixtures

**Avenue:** Infra · **Type/Lifecycle:** `tooling · tests` · **Size:** M · **Status:** in progress (231.1–231.5 done; 231.6–231.7 open; 231.7 next) ·
**Source:** `tests/suite.json` had grown to 77 KB, and its machine-written `computed_order` is one line of
864 names rewritten on every full-tier run.

## Today

- **One JSON manifest.** `tests/suite.json` holds the defaults, two dimensions, two groups and 193 cases in
  about 600 lines without comments, plus `computed_order`. The harness (`src/compiler-test`) reads it with
  `JSONDecoder` and checks unknown keys by hand (`checkKeys`). `Ordering.swift` splices the order back into
  the file as a single line.
- **Fixtures in two places.** Suite fixtures live in `tests/fixtures/` (94 cases) and `examples/` (99 cases).
  `examples/` also holds 35 language demos no case runs, the benchmarks (`examples/benchmarks`, read by
  `tools/perf-tier.py` and `tools/gc-baseline.py`) and `speed_nomu`.
- **What a case costs.** Measured on a fast-tier run (343 runs, 38 s, all compiles cached), and on single
  fixtures:
  - a fixture whose own module changed: about 20 ms to compile and 70 ms to link (the runtime and `std`
    come from the cache);
  - the program's run: under 5 ms for most cases;
  - the first run of a new executable file: 0.10–0.15 s alone, about 0.4 s under the suite's load. macOS
    checks each new file once, keyed by the file: a file rewritten in place with the same bytes runs at once,
    while a new file (a copy, a clone, or a rebuild's output) pays again. `nomu build` writes the binary as a
    new file on every build, a no-op build included, and the harness copied it again
    (`Compile.swift`), so every case paid this on every run.
- **Which cases can merge.** 60 cases fall into 19 groups that share compile arguments, compile settings,
  run settings and carriers; the largest has 28 plain stdout cases. The rest cannot merge without losing
  what they check: 45 build several modules or workspaces, 46 read the collector report, the object's
  symbols or stdin, 26 expect a compile error, and 16 repeat to catch races.

## Design

- **The run order is a local cache.** It moves to `build/compiler-test/order.txt`, one name per line,
  outside git. Timings depend on the machine and nobody reads the ranking. A fresh checkout's first full run
  dispatches unranked cases first, as a new case does today, and writes the file.
- **The manifest is YAML, split by area.** `tests/suite/suite.yaml` holds the defaults, dimensions and
  groups; `tests/suite/cases/<area>.yaml` holds the cases, one file per area (gc, modules, runtime,
  scheduler, language, and so on). The harness takes the directory, loads every file, and rejects a name
  used twice. `YAMLDecoder` (`src/yaml`) rejects unknown keys and reports positions, replacing
  `checkKeys`. Keys stay snake_case.
- **Fixtures live in `tests/fixtures/`.** Every suite fixture in `examples/` moves there. `examples/` keeps
  the language demos, as the user-facing programs that show what Nomu can do; a suite group runs them so
  they keep working. The benchmarks move to a top-level `benchmarks/`.
- **Unchanged binaries stay in place.** The harness leaves its kept binary alone when the build's output has
  the same bytes, so an unchanged binary skips the first-run check. A hard link would not help: it points at
  the build's new file, which has never run. The driver can do the same for its own output (231.6).
- **Cheap cases merge.** Cases with the same compile and run shape, plain stdout checks and runs under
  10 ms merge into one fixture per shape. Each former fixture becomes a module of the merged package whose
  entry function prints a header line before its output, so a failing diff names the part that broke. One
  build and one link replace one per case.

## Work

- **231.1** The run order: `build/compiler-test/order.txt`; `computed_order` leaves the manifest. *Done.*
- **231.2** The YAML manifest: `tests/suite/` by area, the loader on `YAMLDecoder`, a one-time conversion,
  the README and the `//:suite_sources` filegroup updated. *Done:* six area files (gc 64 cases, modules 44,
  generics 37, runtime 19, scheduler 16, language 13); the fast tier runs the same 343 runs, and
  `--check-reproducible` passes.
- **231.3** Unchanged binaries kept in place by the harness. *Done:* the fast tier with unchanged binaries
  went from 39.7 s to 12.6 s. After a compiler change every binary is new and the run pays the check per
  binary, which 231.5's merging reduces.
- **231.4** Fixtures out of `examples/`: suite fixtures to `tests/fixtures/`, benchmarks to `benchmarks/`,
  references in the tools, docs and code comments updated; the remaining demos run by a suite group. *Done:*
  77 fixtures moved, each its own package now; `benchmarks/` holds the benchmarks and the Fibonacci pair; the
  `examples` group runs 33 demos against their `expected.txt`, excluding `generics`
  ([232](232-generic-string-property-concat.md)) and `table` (an empty `main.nomu`, left for removal). Groups
  gained `exclude`. Fast tier: 376 runs.
- **231.5** Merged fixtures, called bundles (`tests/README.md`, "Bundles"). *Done:* 22 cases became three
  bundles: `bundle-plain` (18, no settings), `bundle-rt-prelude` (2) and `bundle-core-import` (2); each
  bundle's output matches its programs' former expected output byte for byte. Of the 60 candidates, 35
  stayed separate: another case uses the same fixture with other settings (the `-evac` and `-nursery`
  legs), the program prints while globals initialize, the module or workspace layout is under test, a
  Bazel test reads the fixture, or the run takes over 10 ms. The mark-verify and root-walk programs were
  bundled and taken back out: they print heap fingerprints and live counts that depend on what ran earlier
  in the process. The fast tier has 19 fewer compile jobs (292 → 273, with the 33 demos added in 231.4)
  and runs 357 runs in 14.2 s; the full tier 879 in 47.2 s.
- **231.6** The driver keeps an unchanged binary in place: when the link is cached and the output path
  already holds the same bytes, `nomu build` leaves the file alone. A no-op `nomu run` of a small program
  takes 0.16 s today, about 0.15 s of it the first-run check.
- **231.7** Multiplexed test binaries, next. The harness builds one binary per compile setup from the
  fixtures as they are, and each run picks its case by argument (`bin <case>`), still one process per case.
  The hand-made bundles go back to separate fixtures. To settle: the generated entry runs only the chosen
  module's global initializers (they run at startup today); a group that fails to compile is rebuilt one
  member at a time to name the culprit; negative compile cases and module or workspace layout cases keep
  their own builds; a way for the program to read its arguments (an internal runtime feature, no syntax).

## The first-run check

What each approach measured, as the cost of a new executable's first run against its second:

- **Developer Tools exemption** (System Settings → Privacy & Security → Developer Tools, with the
  terminal app added and restarted): removes the check for every process the app starts. With Zed exempted,
  the fast tier with every binary new went from 47 s to 14 s (13 s with binaries kept). This is the current
  setup; each machine needs it set up separately.
- **Ad hoc signing:** no effect. The linker already signs every binary ad hoc; re-signing with
  `codesign -s -` pays the same ~160 ms.
- **`/private/var/tmp`:** no effect, for files copied in and for files `clang` links there directly
  (~120 ms against ~10 ms).
- **A stable runner that `dlopen`s each test:** no effect. A new library pays the check on its first
  load (142 ms against 9 ms).
- **Overwriting a run file in place:** skips the check. With the exemption off, 15 Nomu binaries written in
  turn into one long-lived file ran in 9–30 ms each against 114–138 ms for new copies, with correct output.
  macOS appears to record its check per file and keep it across content changes; a later macOS may close
  this. Left unused while the exemption is in place.

## Refs

`src/compiler-test/sources/Manifest.swift`, `Ordering.swift`, `Compile.swift`; `tests/README.md`;
[155 integration suite harness](155-integration-suite-harness.md), [200 YAML parser](200-yaml-parser.md).

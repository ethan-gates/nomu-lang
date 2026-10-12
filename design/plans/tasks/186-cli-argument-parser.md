# CLI argument parser (dependency-free, subcommand-aware)

**Avenue:** Infra · **Type/Lifecycle:** `tooling` (host library) · **Size:** M · **Status:** **built +
green** — the `src/cli` module (`ArgParser.swift`) implements the full scope below; 13 unit tests in
`src/cli/tests` cover subcommand dispatch, long/short/`=` option forms, compacted short-flag clusters (and
the value-option-in-cluster error), choice validation, repeated + comma-split list options, defaults,
pass-through after `--`, inherited globals, synthesized top-level + per-subcommand help, `--version`, and
each error path. Unblocks [173](173-package-model-driver-cli.md) §173.5.1 (the `nomu` uber-CLI builds its
entry on this). · **Source:** split from 173 §173.5.1 — the subcommand CLI wants a real parser, and
hand-rolling it per subcommand (as `main.swift` does today) does not scale to
`compile`/`build`/`run`/`test`/`query` each with their own flags.

## Decision — our own, not swift-argument-parser

**Build our own.** Apple's swift-argument-parser does all of this, but it adds an external dependency and
leans on macros / property wrappers that complicate a hermetic Bazel build. The host stays dependency-free
(the same call as the JSON manifest over a YAML parser, [163](163-manifest-yaml.md)), and the parser is a
small, well-bounded utility, so owning it costs little and removes a build-graph dependency.

## Goal

A reusable Swift host library (new module, e.g. `src/cli`) that the `nomu` driver uses to declare a command
tree and parse `CommandLine.arguments` against it, with good errors and synthesized help. Declarative: a
subcommand states its flags/options/positionals, and parsing + help fall out of the declaration.

## Scope

- **Subcommands** — a top-level command dispatches to one of `compile`/`build`/`run`/`test`/`query`; each
  owns its argument set. Unknown subcommand → error + top-level usage.
- **Flags** (boolean, presence-only) and **options** (take a value), each with a **long** (`--output`) and
  optional **short** (`-o`) form. Option values both space-separated (`-o path`) and `=`-joined
  (`--output=path`, `-o=path`).
- **Compacted short flags** — a short cluster `-fun` expands to `-f -u -n`. **Flags only:** every member
  must be a value-less flag; a value-taking short option cannot sit in a cluster (it uses `-o val` / `-o=val`),
  and a value-option found inside a cluster is an error.
- **Choice options** — an option whose value is validated against a fixed allowed set, with the set shown in
  help (`--mono=none|edge|all`, `--stop=ast|noir|ssair|llvm|binary`).
- **List options** — an option that collects multiple values: repeated occurrences (`-I a -I b`) and, when
  the option opts in, comma-split (`--runtime-subset=a,b`).
- **Defaults + required/optional** — options carry a default or are required; positionals likewise.
- **Positionals** — ordered required/optional args and a variadic tail (the source-file list).
- **Pass-through** — `--` ends option parsing; the remainder is a trailing list the command interprets
  (positional for most; `run` forwards it as the executed program's argv).
- **Shared / inherited flags** — a flag or option declared once and attached to several subcommands (`-O`,
  `--mono` on `compile`/`build`/`run`), so it is not re-declared per command.
- **Synthesized `--help` / `-h` + `--version`** — a top-level summary listing subcommands, and a
  per-subcommand help listing its flags/options/positionals (with choices + defaults) from the declaration.
- **Errors** — unknown flag/option, missing option value, a value-option inside a short cluster, a bad choice
  value, missing required positional/option, wrong arity; a clear message + the relevant usage, not a stack
  trace. (Frontend no-crash spirit: the CLI is an exit boundary.)

## Non-goals (deferred)

- Long-option abbreviation / prefix-matching, attached short-option values (`-ofile`), subcommand aliases,
  shell completion, env-var binding, config-file layering, mutually-exclusive groups, "did you mean"
  suggestions. Add only if a concrete need appears.

## Deliverable

`src/cli` module + unit tests (`src/cli/tests`): subcommand dispatch, short/long/`=` option forms, positionals
+ variadic, help-text synthesis, and each error path. [173](173-package-model-driver-cli.md) §173.5.1 then
rebuilds `nomu`'s entry on top of it.

## Refs

`src/nomu-cli/sources/main.swift` (the current hand-rolled flag loop this replaces);
[173](173-package-model-driver-cli.md) §173.5 (the consumer).

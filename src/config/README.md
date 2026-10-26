# config/

The build configuration library: setting schemas, layers, configs and the resolver. The design is
`design/plans/tasks/198-build-configuration.md`; its goals are cited here as G1–G20.

- The schema is an input (`sources/Schema.swift`). The library declares no settings; the compiler's schema
  is one user, and the tests use a made-up bakery (`cfgresolver/sources/Bakery.swift`).
- `Schema.builtinLayer` turns defaults and builtin config values into the weakest layer. Callers build the
  other layers (`Layer`, `Declaration`) from `cfg.yaml` files; the command line only selects configs.
- `ConfigTable` collects config declarations and flattens a selection into the ordered list; `resolve`
  takes the layers, the table and that list and returns a `Configuration`: one value per setting, with
  every declaration of it and its status (G1).
- `ConfigFile` reads one `cfg.yaml`. `BuildConfiguration` takes every workspace's files, the pins and the
  selection, checks every file once, and gives each module its stack (`stack(for:)`) and configuration;
  program and build settings come from the entry workspace for every module.
- `Record.swift` writes the configuration record, one module's values, and the builtin dump.
- `cfgresolver/` is a small tool over the bakery schema that reads a fixture tree like a build does; its
  golden cases (`cfgresolver/tests/cases/<case>/{args,expected}`) test the library end to end. Update them
  with the command in `cfgresolver/tests/GoldenTests.swift`.
- `Configuration.canonical` is the form a job file carries and the cache key hashes (G2): values only,
  never config names.
- Errors are values (`ConfigErrors`) with a stable code each; the library never prints.

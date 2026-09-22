# Test framework — test-case designation + runner

**Avenue:** Usability · **Type/Lifecycle:** `language-surface · tooling` · **Size:** M ·
**Status:** needs-design (module-level test identity settled in [100](100-modules.md); case designation + runner open)

The in-language testing story: how individual test cases are marked, how they run, and what the
assertion/reporting surface is. Distinct from the compiler's own integration harness ([155](155-integration-suite-harness.md)),
which tests `nomuc` via external scripts.

## Settled upstream (modules, task 100)

- **Test identity is module-level**, declared in the package manifest (a test-module list, alongside
  `sealed` and `bin`). A module is real XOR test; no filename-suffix discovery, no double-duty modules.
- **White-box access** via a `test import pkg/foo` modifier that widens the test module's visibility
  into `foo` to `internal`/`package`; a plain import stays black-box (public only).
- Test modules can live adjacent to their target (e.g. `foo_tests/` beside `foo/`).

## Open scope (this task)

- **Test-case designation** — how a function is marked a test (an attribute like `@test`, not a
  filename or name convention). Needs agreement before any syntax lands.
- **Runner** — how tests are discovered within a test module, executed, isolated, and ordered;
  parallelism; setup/teardown.
- **Assertions** — the assertion surface (builtin vs stdlib), failure reporting, expected-failure
  and skip markers.
- **Output** — result format for humans and for tooling (machine-readable for CI/LSP).
- **Test-only dependencies** — once external deps land, keeping test deps isolated from the
  production build (test modules already isolate this structurally).

## Dependencies

- Modules [100](100-modules.md) — test-module identity, `test import`, manifest home.
- Ties to attributes/annotations surface (shared with other `@`-markers) — coordinate spelling.

## Refs

- Rust: `#[test]`, `#[cfg(test)]`, `cargo test`.
- Go: `testing` package, `go test` (mechanism kept only as contrast — filename suffix rejected).
- Swift: XCTest / swift-testing `@Test` macro.

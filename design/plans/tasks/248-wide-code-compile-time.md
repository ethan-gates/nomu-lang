# Compile time on wide code: superlinear in fields and expression length

**Avenue:** Infra · **Type/Lifecycle:** `perf · compiler · needs-investigation` · **Size:** M ·
**Status:** found, not started · **Source:** [104](104-fiber-stack-strategy.md).2.4's oversized-frame check
and the deep-expression crash

## The finding

Compile time grows faster than the input on wide code. Debug builds, release compiler, one module:

| input | size | build |
|---|---|---|
| a struct built from an array and summed in 100-term pieces | 1,700 fields | 14 s |
| the same | 4,500 fields | 171 s |
| one expression `a * 0 + a * 1 + …` | 1,700 terms | 1.9 s |
| the same | 20,000 terms | 24 s |

Ordinary programs are unaffected; generated code (wide records, large tables) would hit it.

## To do

- Profile both shapes and find the passes that scale badly (`nomu build`'s timings report per stage).
- Fix or bound them; add a timing check over a wide fixture.
- `checkExpr`'s frame is about 6.8 KB per level: moving its large cases into separate functions would cut
  the stack each nesting level needs and may speed checking.

## Refs

`tests/fixtures/deep_expression`, `tests/fixtures/wide_signature`; `src/nomu-cli/sources/main.swift`
(`runOnLargeStack`).

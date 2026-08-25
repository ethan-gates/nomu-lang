# Frontend perf (interning, lexer allocation, streaming)

**Avenue:** Infra (perf) · **Type/Lifecycle:** `perf · needs-grounding` · **Size:** M ·
**Status:** mixed (see per-item) · **Source:** deferred.md (2026-08 session)

Groups three coherent lexer/frontend perf items.

## Identifier interning `[needs-grounding]`

Intern identifiers to integer symbols at lex time; downstream Sema comparisons/maps become int-keyed.
Touches Sema's string-keyed tables and interacts with macro **hygiene** (carry `(symbol,
hygiene-ctx)` — see [macros](140-macros.md)) and future parallel/incremental compilation. Ground against
Sema's map usage first. Deliberately deferred out of the parser-perf pass.

## Lexer allocation levers `[ready-to-build]`

After the byte-lexer + compact-spans work, two small wins remain: parse `Int` literals directly from
bytes (drop the per-number `String`), and reuse one scratch `[UInt8]` across string literals (drop the
per-literal array). Keywords/operators are already allocation-free; identifiers still allocate their
`String` (fundamental until interning above).

## Streaming / pull lexer `[needs-design, parked]`

A `pull_next_token()` model instead of full up-front tokenization, to cut peak memory / allow
lex+parse overlap. `Lexer.next()` is already the pull primitive; a pull driver needs a rewindable
lookahead buffer for the parser's backtracking. Parked — the batch model is fine and this is not a
throughput lever. Ties to the streaming axis of [IR/pipeline hardening](142-ir-pipeline-hardening.md).

## Refs

deferred.md "Identifier interning", "Lexer allocation levers", "Streaming / pull lexer";
`Lexer`, Sema's string-keyed tables; [macros](140-macros.md) (hygiene).

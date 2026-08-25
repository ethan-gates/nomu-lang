# String / UTF-8 model

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** M ·
**Status:** needs-design (high-stakes, permanent contract) · **Source:** deferred.md (stdlib track)

## What

The permanent String model — a high-stakes decision pulled out of the [stdlib track](120-stdlib-core.md).
Axes:
- **Indexing unit** — byte / Unicode scalar / grapheme cluster.
- **Storage** — UTF-8 backing, small-string optimization.
- **Normalization.**
- **Whether there is a `Char` type.**

Precedents: Swift indexes by grapheme (O(n)) over a UTF-8 store; Rust exposes UTF-8 bytes with scalar
`char`. Nomu's choice sets a permanent expectation *and* cost model (indexing complexity, iteration).

## Why consequential

`String` is a C primitive today (M4.13), so this decision also revisits that placement (ties to
[self-hosting](128-self-hosting-runtime.md)). Programmer-expectation + perf, both hard.

## Dependencies & triggers

- **Rests on:** [unsafe raw memory](125-unsafe-raw-memory.md) (the backing store) if String moves into
  Nomu.
- **Couples with:** [copy-on-write](123-copy-on-write.md) (String is a value type), the C-core-floor
  placement decision.

## Refs

deferred.md "Standard library" (String/UTF-8 sub-decision); M4.13 (`String` as C primitive).

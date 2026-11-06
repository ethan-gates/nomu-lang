# One-shot continuations

**Avenue:** Risk (concurrency thesis) · **Type/Lifecycle:** `language-feature · needs-design` ·
**Size:** M · **Status:** designed in `concurrency.md`, unbuilt · **Source:** `concurrency.md` §3, §6

## What

The checked one-shot continuation: a resume-once suspension primitive, which `select` rides
(`concurrency.md` §4). Resume-once is checked at runtime.

Cancellation left this task: it is a convention over channels, with no language or runtime concept
(`concurrency.md` §7).

## Dependencies & triggers

- **Ready:** the M:N runtime, safepoints, the async actor runtime.
- **Feeds:** `select` in [channels](102-channels.md).

## Refs

`concurrency.md` §3 (continuations), §4 (`select`), §7 (cancellation); `runtime.md` §3.

# Fan-out helpers

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-evidence` · **Size:** S ·
**Status:** waiting on programs · **Source:** `concurrency.md` §8

## What

Dynamic fan-out is an array of tasks and a loop (`concurrency.md` §8), so nothing needs building for it. A
library `Group` waits until programs show which need is common:

- results in completion order, today a shared channel passed to the workers;
- stopping on first error, today a stop channel the workers check;
- a concurrency limit, today a counted channel.

## Dependencies & triggers

- **Depends on:** [250](250-fiber-task-surface.md) (`task`).

## Refs

`concurrency.md` §7, §8; [fiber-stack-strategy](104-fiber-stack-strategy.md).

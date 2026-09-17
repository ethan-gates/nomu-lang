# Env-var audit — collapse the NOMU_* surface to a minimal, principled set

**Avenue:** Infra · **Type/Lifecycle:** `hygiene · needs-design` · **Size:** M ·
**Status:** needs-design · **Source:** grounded during 150.4.4 — adding `NOMU_MATURE_FLOOR` prompted
the observation that the `NOMU_*` surface grows one knob at a time with no back-pressure.

Audit every `NOMU_*` environment variable and remove nearly all of them. Env vars are a poor
configuration surface — invisible, unvalidated, untyped, easy to forget (a forgotten flag passes a
test for the wrong reason), and they accumulate without review. The default should be zero knobs: a
correct build needs no environment at all. Each survivor must justify its existence.

## Why now

The surface is ~two dozen distinct `NOMU_*` vars read across the runtime and compiler, and it grew
incrementally during the self-hosting push (each GC/scheduler increment added its own). No single place
lists them, documents them, or governs whether a new one is warranted. This is the moment to set the
policy before the runtime stabilizes and the knobs calcify into a de-facto interface people script
against.

## The principle

One product lever, not many. `NOMU_RUNTIME={native,selfhost}` already exists as the umbrella that
selects self-hosted scheduler + allocator + collector together (task 128.4). Everything else should be
either (a) an internal default with no env at all, (b) a dev/test-only override clearly marked as
such, or (c) removed. Product selection stays a single flag; behavior tuning lives in the code with a
sensible default, overridable only where a test genuinely needs it.

## What — the audit

Enumerate every `NOMU_*` var (grep `getenv` / `environment[` across `src/`, plus any referenced only
in `tools/`), and for each classify + decide:

- **Product selection.** `NOMU_RUNTIME` (keep — the one lever). `NOMU_SCHED` / `NOMU_GC_PLAN` are
  temporary differential-oracle overrides kept only to diff against MMTk; they retire with MMTk
  (§7 Open in `selfhosted-gc.md`). Confirm nothing else selects an implementation.
- **GC/scheduler tuning.** `NOMU_NURSERY_RESERVE`, `NOMU_MATURE_FLOOR`, `NOMU_CARRIERS`,
  `NOMU_GC_TRIGGER_RESERVE`, and the like. Each should carry an internal default (the descriptor
  already holds `nurseryReserve = numBlocks/4`, for instance) and drop the env, or demote it to a
  dev-only override. When the generational trigger flips on by default (150.4.5), the reserve + floor
  knobs fold into internal defaults.
- **Debug / stats / smoke toggles.** `NOMU_GC_DEBUG_*`, `NOMU_GC_STATS*`, `NOMU_GC_SMOKE*`,
  `NOMU_STW_*`, `NOMU_DUMP_*`, `NOMU_TIME_*`, `NOMU_GC_TYPEMAPS`, etc. Candidates for a single unified
  diagnostics channel (one `NOMU_DEBUG=<comma-list>` or a `--debug` compiler flag) instead of one env
  per probe, or removal once the integration harness (task 155) owns test observability.
- **Codegen flags.** `NOMU_NO_ESCAPE`, `NOMU_NO_INLINE_ALLOC`, and friends — these change emitted code,
  so they belong as compiler `--flags` (visible, validated, recorded in `--timings`), and in fixtures
  via task 155's `//@ compile-env` directive, not ambient environment.

Decide per var: **keep** (with justification), **internalize** (default in code, no env), **demote**
(dev/test-only, documented), or **remove**. The bar for keep is high; the expected outcome is that
nearly all are internalized or removed.

## Deliverables

- A single documented registry of the survivors (what/why/default), so a new env var requires a
  conscious edit to a reviewed list rather than a stray `getenv`.
- Codegen-affecting flags moved to compiler `--flags`.
- Test-only knobs expressed through the harness (task 155) fixture directives, not scattered exports.
- The default `NOMU_RUNTIME=selfhost` (or bare native) run needs no other environment.

## Dependencies / ordering

Ties to **155** (integration-suite harness — fixture-declared env removes most test-time exports) and
lands cleanly after **150.4.5** (when the generational reserve/floor become internal defaults). The
oracle-override vars (`NOMU_SCHED` / `NOMU_GC_PLAN`) retire with MMTk. Do the audit + policy now; sweep
the removals as each dependency clears.

## Refs

[155 integration-suite harness](155-integration-suite-harness.md);
[150 GC ladder](150-selfhosted-gc-ladder.md); [128 self-hosting runtime](128-self-hosting-runtime.md)
(the `NOMU_RUNTIME` umbrella, task 128.4); `internals/selfhosted-gc.md` §7 (MMTk retirement).

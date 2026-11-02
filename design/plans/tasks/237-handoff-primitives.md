# Handoff primitives: a direct switch, and the compiler marking handoffs

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `perf · needs-design` ·
**Size:** M–L · **Status:** waits on a decision about the primitive (channels, a request-reply call, or
another; new syntax or API, to be agreed) · **Source:** [234](234-scheduler-wake-and-pool.md)'s step two
and 234.3

## Background

234 gave each carrier a run-queue slot: a fiber readied by a running fiber runs next on the same carrier.
Each readying still wakes a carrier (Go's `wakep`), in case the readier keeps running and the readied fiber
must move. From the readier's side there are three cases:

1. **It knows it parks next**: a fiber's completion readying its joiner, or a runtime operation that readies
   and parks in one call.
2. **It parks next, but nothing at the readying knows it**: a send followed by a receive, as in a
   ping-pong.
3. **It keeps running.**

Only case 3 needs the wake. Go's runtime sees one operation at a time, so it treats every readying as
case 3. Nomu's compiler sees the code after a readying.

## The two parts

- **Marking handoffs.** For each readying site, the compiler walks forward on every path to the first park,
  and marks the site when what lies between is bounded and short: no loops but small bounded ones, no calls
  through interfaces or function values, and only callees whose summaries say bounded and never blocking
  (the kind of summary 104 plans for stack bounds). A marked site readies without a wake. A wrong "no"
  costs a wasted wake; a wrong "yes" cannot happen.
- **A direct switch.** At a marked site the compiler emits one operation for the pair (send then receive),
  which hands the value over and switches straight into the partner: one context switch a hop instead of
  two, with no pass through the carrier loop. The operation does the loop's duties itself: the lock handoff
  across the switch, the carrier record's current fiber, the stop-the-world check, the slice, and the
  periodic run-queue check.

## Measured so far

From 234 (ns per hop at 2 / 4 / 8 carriers): the fiber ping-pong with a wake at every readying is 27 / 49 /
52; with no wake (a probe) it is about 22–26 at every count. The register swap is 6 ns a switch; a hop is
two switches and a pass through the carrier loop.

## The cliff

A small edit can lose a site's mark, as an edit can make a Go variable escape or put a function over Go's
inlining budget. The loss is bounded: the wake (case 2 handled as case 3) and one switch a hop. The perf
report should list readying sites and why each did or did not get the fast path, as `-gcflags=-m` does for
Go's escape and inlining decisions.

## Refs

234's step two and 234.3 (the cases, the measurements, the cliff discussion);
`src/stdlib/runtime/scheduler.nomu` (`rtSchedReadyNext`, `rtSchedPick`); [104](104-fiber-stack-strategy.md)
(call-tree summaries).

# Concurrency hardening (M12)

**Avenue:** Risk · **Type/Lifecycle:** `refactor · observability · evaluate` · **Size:** L ·
**Status:** placed at M12 (after the full surface + debugger exist) · **Source:** roadmap M12

## What

Systematic battle-testing plus a bulletproof runtime spec for the concurrency substrate.

- **Battle-testing:** a scheduler + park-protocol stress/fuzz harness driving randomized
  spawn / park / wake / steal / STW schedules; race + deadlock detection (TSan, deterministic replay,
  and/or a model checker over the park/unpark + stop-the-world handshakes); long-running soak tests
  under GC pressure; property tests for the guarantees — per-sender FIFO and non-reentrancy for
  actors, structured-scope join (no work escapes a scope), shareability at task boundaries, and
  cancellation propagation to parked children.
- **Spec:** pin to stated-not-folklore the park/unpark contract + lost-wakeup rule (§2), scheduler
  invariants + memory ordering, the safepoint/STW handshake (`runtime.md` §6), actor lifetime +
  drain-then-collect (§9), and cancellation semantics (§7).

## Why here

The full surface is built by M12 (M8 cancellation / continuation / channels on top of the M:N
runtime, structured scope, async actors) and the [debugger](138-debugger.md) (M11) can investigate races
— so hardening covers the whole system once rather than a moving target.

**Motivation:** M6·6.4 surfaced a ~1-in-150 latent park race caught by luck, not a test. The goal is
that whole class of bug is caught by construction, and that every concurrency guarantee the docs
claim has a test and a precise statement behind it.

## Dependencies & triggers

Seed a lightweight version of the stress harness during M8 as ongoing discipline; M12 is the
comprehensive formalization + exhaustive pass, not the first test. Overlaps the SSAIR randomized
differential (T7, `148-ssair-optimizer-tier.md` §148.9).

## Refs

`concurrency.md`, `runtime.md` §6; roadmap M12; `148-ssair-optimizer-tier.md` §148.9 (T7).

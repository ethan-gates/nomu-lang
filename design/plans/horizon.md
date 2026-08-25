# Near-horizon — what's next, and why in this order

The current working order. Identity numbers point into [`tasks.md`](tasks.md); this doc carries only
the sequencing reasoning. The order is editable and separate from task identity.

**Frame.** The headline risk bet — [127 LXR](tasks/127-lxr-collector.md), the footprint endgame — is
gated on a benchmark-scale stdlib. So the Risk and Usability avenues share one critical path now: build
the stdlib, which needs a raw-memory substrate plus enough ergonomics to write real programs. This
horizon walks that path.

## Now — the foundation

- [125 Unsafe raw memory](tasks/125-unsafe-raw-memory.md) — scoped to the byte buffer needed to back
  real `String` and `Array` (Set/Dict ride the same buffer). Everything below rests on it, so it goes
  first.

## Next — stdlib primitives, on 125

- [121 String / UTF-8](tasks/121-string-utf8-model.md) — real strings over the byte buffer.
- [120 Stdlib core](tasks/120-stdlib-core.md) — real `Array`; Set/Dict layered by hand on the same buffer.

## In parallel — frontend-contained, independent of 125

- [117 `for … in`](tasks/117-for-in-iteration.md) — iteration; also cashes the bounds-check-free perf claim.
- [115 Error handling `?`](tasks/115-error-handling.md) — wanted once there is I/O.
- Cheap papercuts between tasks: [114 grouping parens](tasks/114-grouping-parens.md),
  [143 parser recovery](tasks/143-parser-error-recovery.md), [119 float literals](tasks/119-float-exponent-literals.md).

## Settle cheaply, regardless

- [142 IR hardening](tasks/142-ir-pipeline-hardening.md) — cheapest while SSAIR is young; underlies
  incremental compilation later.

## Deferred, with trigger

- [104 Dynamic fiber stacks](tasks/104-fiber-stack-strategy.md) — safe to defer. Its build rides the
  late massive-fan-out workload ([103](tasks/103-dynamic-spawn-group.md)), and the GC substrate it needs
  is already built. Lean guard-page (runtime-only, low codegen ripple) keeps the door open; fixed 128 KiB
  holds until then.
- [127 LXR](tasks/127-lxr-collector.md) — the endgame this horizon builds toward; un-parks when the
  stdlib is benchmark-scale.

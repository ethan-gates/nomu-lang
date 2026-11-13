# Benchmarks

Workloads for measuring the compiler and the runtime, one per directory. `tools/perf-tier.py` times them
under the optimizer's pass configurations; `tools/gc-baseline.py` times them under each collector plan and
reads the collector report. `speed_nomu` and `speed-py.py` are a recursive Fibonacci pair.

`mem_routines` concatenates and compares short strings (16 to 140 bytes) and copies a 64 KiB buffer, the
memory routines' load (task 104.3.4). `print_loop` prints three million integers, each a libc call from a fiber, which runs on the carrier's
stack (task 104.3.3); it measures a libc call's cost, with stdout sent to /dev/null.

`stack_shrink` parks 10,000 fibers on a channel after deep recursion and runs six major collections,
printing each pause and the fibers' total stack size: the cost and the effect of shrinking stacks (task
104.4.5; `--config=rt_prelude`).

`spawn_grow` starts 100,000 short fibers a round, each recursing to a depth from 0 to 1,024, and
`deep_recursion` runs 4 fibers recursing to 10,000, 100,000 and 1,000,000: what growing a stack costs (task
104.5.1). Run them with `NOMU_STACK_STATS=1` for the moves' count, bytes and time. Their Go counterparts are
in the gitignored `practice/go/stacks`.

`ctx_swap`, `pingpong_fiber` and `pingpong_actor` measure a fiber switch; `tools/pingpong.py` builds and
runs them, with a local Go counterpart when one is present (task 104). The scheduler workloads
(`fanout_actor`, `forkjoin_fiber`, `pipeline_actor`, `producer_fiber`, `sleepers_fiber`, `mixed_fiber`,
`idle_fiber`, with the two ping-pongs) run under `tools/schedbench.py`, which sweeps the scheduler's
settings (task 234.3).

The `frames_*` workloads (`frames_tree`, `frames_strings`, `frames_loops`, `frames_fib`, `frames_mutating`)
measure what finding roots costs: references and `String` values live across calls, call-free loops, a
control with neither, and a pointer into a caller's frame (a field-writing method's `self`) live across calls.
`tools/frames-ceiling.py` runs them under the `measure_*` configs (task 243.1); each allocates little enough
to finish without a collection under `NOMU_NURSERY_RESERVE=7000`.

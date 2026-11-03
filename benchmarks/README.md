# Benchmarks

Workloads for measuring the compiler and the runtime, one per directory. `tools/perf-tier.py` times them
under the optimizer's pass configurations; `tools/gc-baseline.py` times them under each collector plan and
reads the collector report. `speed_nomu` and `speed-py.py` are a recursive Fibonacci pair.

`ctx_swap`, `pingpong_fiber` and `pingpong_actor` measure a fiber switch; `tools/pingpong.py` builds and
runs them, with a local Go counterpart when one is present (task 104). The scheduler workloads
(`fanout_actor`, `forkjoin_fiber`, `pipeline_actor`, `producer_fiber`, `sleepers_fiber`, `mixed_fiber`,
`idle_fiber`, with the two ping-pongs) run under `tools/schedbench.py`, which sweeps the scheduler's
settings (task 234.3).

The `frames_*` workloads (`frames_tree`, `frames_strings`, `frames_loops`, `frames_fib`) measure what finding
roots costs: references and `String` values live across calls, call-free loops, and a control with neither.
`tools/frames-ceiling.py` runs them under the `measure_*` configs (task 243.1); each allocates little enough
to finish without a collection under `NOMU_NURSERY_RESERVE=7000`.

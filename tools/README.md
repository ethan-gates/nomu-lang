# tools/

Most integration drivers moved into the declarative suite (`tests/suite.json`), run by the
`compiler-test` harness (see `tests/README.md`). ~42 one-off `*.sh` drivers were retired that way.
What remains here is the tail the harness does not yet express, plus a few meta-runners.

## Run the ported suite

```
bazel build //src/compiler-test:compiler-test
bazel-bin/src/compiler-test/compiler-test
```

`gen-default-suite.sh` runs that suite and then the GC tail scripts below.

## Tail scripts (still bespoke)

Each of these asserts something the current manifest schema cannot, or belongs to a different
testing layer. They stay as scripts until (if) the harness grows the matching feature.

Precise root-set / walk assertions — extract values from stderr, sort/dedupe, assert an exact set
with exclusions ("dead 999 absent"):
- `gc-smoke.sh`, `gc-smoke-parked.sh`, `gc-smoke-stw.sh`, `gc-smoke-tier.sh`, `gc-t6-stw.sh`
- `walk-mark.sh`, `walk-multiframe.sh`, `walk-parked.sh`
- `mark-verify.sh`, `mark-verify-oracle.sh`, `mark-types.sh`
- `sched-root.sh`, `stackmap-probe.sh`, `stw-selfhost.sh`

Contrast / self-checked / cross-oracle output (bespoke comparisons, not a fixed golden):
- `gc-actor.sh` (sorted line-count), `gc-actor-teardown.sh` (3-way heap contrast),
  `gen-multicarrier.sh` (multi-fixture self-check), `gc-oom.sh` (two-fixture OOM bundle),
  `sched-integration.sh` (self-hosted scheduler == C oracle), `selfhost-gc.sh` (nogc==nomu bundle),
  `subset.sh` (two distinct compile-error substrings + undesignated-compiles-clean)

Compiler-artifact inspection (looks at the binary/IR, not program output — belongs with the
IR-pipeline layer, task 142):
- `escape.sh` (`nm` for `rt_alloc`), `subset-poll.sh` (`otool` poll-count), `ir-golden.sh` (IR goldens),
  `escape-diff.sh` (corpus on/off behavior diff)

Perf and corpus matrices (harness Phase 2):
- `perf-tier.py`, `gc-corpus-matrix.sh`

Meta-runner:
- `gen-default-suite.sh` (delegates to `compiler-test`, then the GC tail)

`install/` is unrelated tooling, left as-is.

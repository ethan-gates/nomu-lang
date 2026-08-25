# Plans — work-tracking (ephemeral)

**Backlogs and milestone build-plans**, not durable design. Durable design lives in
[`../language/`](../language/readme.md) and [`../internals/`](../internals/readme.md); these track
parked and in-flight work.

- `deferred.md` — postponed feature work, each with its un-park trigger.
- `ssair-backlog.md` — the SSAIR optimizer-tier backlog.
- `mN-spec.md` — a milestone's ordered build plan (authored per `milestone-doc-guide.md` at the repo root).

A completed milestone spec is **deleted**, not kept: its durable design — and any directions explicitly
*not* taken — folds up into `../language/` + `../internals/` first, then git and the code are the record.
(Nothing durable dies; a stale build-plan doesn't linger.)

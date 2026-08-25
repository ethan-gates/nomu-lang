# Plans — work-tracking (ephemeral)

**Backlogs and milestone build-plans**, not durable design. Durable design lives in
[`../language/`](../language/readme.md) and [`../internals/`](../internals/readme.md); these track
parked and in-flight work.

- `horizon.md` — the near-horizon **ordering**: what's next and the sequencing reasoning, pointing
  into `tasks.md`. Editable order, separate from task identity.
- `tasks.md` — the backlog task **index** (scannable table, tagged by avenue / size / status),
  pointing at one doc per task under `tasks/`. Each task has a stable identity number; docs are
  named `tasks/1NN-slug.md`. Prioritized against two avenues (Risk / Usability / Infra). Dissolved
  out of the former `deferred.md` (2026-08-25).
- `tasks/` — the per-task docs (`1NN-slug.md`), each with its un-park trigger. A task carries its
  own sub-item backlog at `1NN.x` granularity (e.g. the SSAIR optimizer tier, `148-ssair-optimizer-tier.md`).
- `mN-spec.md` — a milestone's ordered build plan (authored per `milestone-doc-guide.md` at the repo root).

A completed milestone spec is **deleted**, not kept: its durable design — and any directions explicitly
*not* taken — folds up into `../language/` + `../internals/` first, then git and the code are the record.
(Nothing durable dies; a stale build-plan doesn't linger.)

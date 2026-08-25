# Parameter labels + argument model

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** M ·
**Status:** needs-design (scope decided 2026-08-18) · **Source:** deferred.md (2026-08-18 surface batch)

## What (scope decided 2026-08-18)

- **Label rules** — external vs internal name, omission; whether labels are part of API identity /
  overload resolution.
- **Default argument values.**
- **Argument evaluation order** (an observable contract).

Variadics out of scope for now.

## Roadmap assessment (three-head)

**One-liner pointer** (leaning yes). The label grammar is trivial; the weight is default args +
label-as-identity pulling on overload resolution and the call-site cost model (default-arg lowering /
ABI), plus evaluation order as an observable contract.

## Dependencies & triggers

- Interacts with [`init`](107-init.md) (default field values ~ default args) and overload resolution.

## Refs

deferred.md "User-level language surface".

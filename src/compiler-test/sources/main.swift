import Foundation

// compiler-test — one command to run the integration suite. Reads a JSON manifest, compiles each
// fixture once, runs it across its run-env × carriers × iterations matrix under bounded timeouts, and
// compares stdout to a golden value. See design/plans/tasks/155-integration-suite-harness.md.
//
// The work is split by concern: Ctx (args/paths/manifest/selection), CompileCache (Phase A), CaseRunner
// (one case), Suite (drives the pool + report), Ordering (LPT dispatch), Progress (live output),
// Spawn (bounded subprocess). This file is just the entry point.

exit(Suite(Ctx.fromArgs()).run())

import ssair
import support

// The pass manager + the four M7 passes over SSAIR (m7-spec.md §7.3–§7.5).
//
// Scaffold (7.2.1). Filled from 7.3 on: a small hand-rolled pass manager with two pass kinds —
// analyses (side tables keyed by value/site identity; mutate nothing) and transforms (rewrite the
// IR, invalidating analyses) — and explicit analysis dependencies + invalidation. Build order is
// EA-first (7.3), then devirt (7.4), then inlining/specialization + bounds-check elimination (7.5).
public enum SSAIRPasses {}

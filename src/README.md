# compiler/

The Nomu compiler, split into per-stage Bazel modules grouped by pipeline phase (M7 §7.1 —
interface modules hold each IR's format, implementation modules hold the code;
`design/internals/architecture.md`):

- **support** — Span, Diagnostic, the semantic Type model (shared leaf, top-level, no deps)

**frontend/** — source → NOIR (architecture backlog: [frontend/README.md](frontend/README.md))
- **frontend/ast** — Token, AST, ASTDump (syntactic interface) · **frontend/parse** — Lexer, Parser (impl)
- **frontend/noir** — NOIR + NOIRDump (typed-IR interface) · **frontend/sema** — semantic pass +
  AST/NOIR checking passes (impl)

**midend/** — the mid-level tier (NOIR→NOIR and, from M7, the SSAIR optimizer tier)
- **midend** — Monomorphize (NOIR→NOIR); the SSAIR optimizer tier
  (`ssair`, `ssairgen`, `ssairpasses`). The old NOIR `EscapeAnalysis` retired with the NOIR egress
  (M7 §7.7); the SSAIR `StackPromotion`/`ScalarPromotion` passes replace it.

**Backend & driver**
- **llvmgen** — NOIR → LLVM IR (C API) → native object; the GC pass pipeline
- **driver** — pipeline orchestration: parse → sema → midend → llvmgen → `cc`; owns `EmitMode`
- **nomu-cli** — `nomuc` binary; argument parsing, calls into driver

**runtime/** — the mandatory floor, linked into every emitted program (`c-types.md`)
- **runtime/embedded** — the C floor under the Nomu runtime (process entry, GC driver threads, TLAB and
  mod-buffer registries, GC descriptor accessors, raw memory) + the C core floor (`core.c`: String,
  primitives), bundled into `nomuc`. The scheduler and collector are Nomu code in `stdlib/runtime.nomu`.

**stdlib** — the Nomu-written standard library (compiled alongside user code)

**bench** — frontend throughput benchmark (lexer/parser timing, isolated from codegen).

**yaml** — the strict YAML 1.2 Core subset read by manifests and `cfg.yaml` (spec in `yaml/spec.md`).

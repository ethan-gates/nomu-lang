# compiler/

The Nomu compiler, split into four Bazel packages:

- **frontend** — lexer, parser, AST, typechecker
- **codegen** — C code emitter (including the runtime preamble)
- **driver** — pipeline: frontend → codegen → `cc`; owns `EmitMode`
- **nomu-cli** — `nomuc` binary; argument parsing, calls into driver

# nomu-cli

The `nomu` command: argument parsing and dispatch to the driver.

**Output.** The terminal is for people: diagnostics, a build's summary line, the paths of what it produced.
A tool never parses `nomu`'s stdout or stderr; it reads files. What a build did (each module's and link's
outcome and reason, timings, the binaries) is in `build/_perf/report.json`
(`design/plans/tasks/193-compiler-performance-report.md`).

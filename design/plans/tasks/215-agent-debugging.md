# Debugging from an agent — lldb in batch mode inside the agent's sandbox

**Avenue:** Usability · **Type/Lifecycle:** `tooling · needs-design` · **Size:** S–M · **Status:** needs-design ·
**Source:** `vision.md` (Audience): debugging is an AI-only use, so its tools are built for an agent. Found in
207.3 and 207.6: lldb hangs inside the coding agent's sandbox, so each lldb check went to a person.

## What

An agent debugs a Nomu binary the way it runs any tool: a batch of lldb commands (`lldb -b -s …`), output
captured, an exit status, inside its sandbox. Today the session hangs there, so the debug-info work (207.3's
source paths, 207.6's debug map and dSYM) could only be checked by hand.

## Work

- **215.1** Find why lldb hangs in the sandbox (the debug server, process attach, or something else) and what
  lets it run: a sandbox exception, a launch mode, or a tool that runs lldb outside the sandbox on request.
- **215.2** A batch recipe an agent uses, written where agents look (a README): build, load the binary's
  `.lldbinit`, set breakpoints, run, read frames and variables, all as one command with captured output.
- **215.3** A check that runs it: a test that debugs a fixture in batch mode and reads a source line and a local's
  value, so a regression in debug info or in the sandbox setup fails a test.

## Refs

`DebugPaths` (`.lldbinit`), `link.debug_info_storage` (207.6); `vision.md` (Audience).

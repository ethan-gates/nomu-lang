# Networking

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** L ·
**Status:** not started · **Source:** [250](250-fiber-task-surface.md) 250.5

## What

Sockets on the poller, with the waits a server needs: a read or accept that parks its fiber, I/O deadlines,
closing a connection waking a blocked read, and connection reads as `select` cases (`concurrency.md` §4, §7).

## Dependencies & triggers

- **Ready:** the poller (`runtime/io.nomu`), `select` (250.5).

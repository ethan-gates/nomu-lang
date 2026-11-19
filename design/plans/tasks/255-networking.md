# Networking

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** L ·
**Status:** not started · **Source:** [250](250-fiber-task-surface.md) 250.5

## What

Sockets on the poller, with the waits a server needs: a read or accept that parks its fiber, I/O deadlines,
closing a connection waking a blocked read, and connection reads as `select` cases (`concurrency.md` §4, §7).

## Open: the poller's architecture

The stdin poller is one dedicated thread blocking in `kevent`, with one registration for stdin. Sockets need it
generalized (any descriptor, read and write readiness, waiters per descriptor), and a choice of where it runs:

- **A dedicated poller thread,** as today: every I/O event costs a cross-thread wake.
- **A poller the scheduler checks,** as Go's netpoller: an idle carrier polls before it sleeps, and a busy
  scheduler polls periodically, so a ready connection's fiber is queued without a wake hop.

This decides P3 (servers against Go, [236](236-fiber-preemption.md)'s performance rules) as much as
preemption does, so it gets its own goals and architecture before it is built. Linux `epoll` comes after
macOS `kqueue`.

## Measuring

A small Go client drives both a Nomu server and the same server in Go. 236's G5 (tail latency in mixed
workloads) is measured on simulated I/O inside 236, and again on real sockets once this task lands.

## Dependencies & triggers

- **Ready:** the poller (`runtime/io.nomu`), `select` (250.5).

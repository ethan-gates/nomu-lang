// Nomu runtime — shared ABI (M4.13).
//
// The boundary between generated user code, the C core floor, and the privileged
// runtime. Anything the generated `user.c` or the other C files call is declared
// here; each `.c` includes this header. (Design: m4.13-spec.md; noir.md.)
#ifndef NOMU_RUNTIME_H
#define NOMU_RUNTIME_H

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>    // generated code lowers `print` to printf
#include <pthread.h>  // generated actor code uses pthread_mutex_t directly

// ---- Shared object model ----
// The in-object GC header (M6 · 6.1.2): one 8-byte word. `type_id` (codegen-assigned) keys the
// per-type pointer map `scan_object` dispatches through (6.1.3); `reserved` is spare header space
// (32 bits is plenty for the type-id — the word is 8 bytes only for field alignment, so the other
// half is free for future in-object GC metadata / flags). Mark/log bits live in the collector's side tables,
// not here.
typedef struct { uint32_t type_id; uint32_t reserved; } ObjectHeader;

// A closure value: code pointer + captured environment (heap-allocated, bump-and-leak).
typedef struct { void* fn; void* env; } Closure;

// ---- GC driver threads ----
// Starts the collector's coordinator threads; the codegen-emitted process entry `main` calls it after the
// runtime's init function, before it boots the scheduler.
void    rt_gc_threads_start(void);

// ---- Actor mailbox (fire-and-forget message-send) ----
// The decided actor model (`concurrency.md` §9): a send enqueues a message on the actor's mailbox and
// RETURNS immediately (the sender never waits, gets no reply).
// Handlers run on fibers rented from a program-global pool, one drain per actor at a time (serial,
// non-reentrant). There is no reply/ask of any kind — fire-and-forget is the only actor operation
// (§9). Teardown is structural — actor + mailbox are ordinary GC objects, so the runtime allocates
// nothing per-actor and frees nothing here.
//
// ABI contract with codegen (`Lowering.swift`). The mailbox and message are GC-allocated objects
// with fixed layouts this C code reaches without knowing the actor's fields / the handler's args.
// The actor object is unchanged (class-shaped) except its last slot holds a pointer to its mailbox;
// codegen loads that at the call site, so the runtime never parses the actor. Codegen supplies the GC
// pointer maps. The Nomu scheduler (nomuSchedActorSend / nomuSchedMailboxPop) reads these layouts.
//
//   mailbox object { i64 header; Msg* mb_head; Msg* mb_tail; i64 scheduled; Mailbox* sched_next; }
//   message object { i64 header; Msg* next; void(*thunk)(void* msg); void* self; args… }
//
// `mb_head`/`mb_tail`/`next`/`self`/`sched_next` are GC-scanned (they chain live queued messages and
// the scheduled-mailbox queue, kept live with the receiver); `thunk` (a code ptr) is not.
// `nomuSchedActorSend` enqueues `msg` on `mailbox` and returns after appending the mailbox to the global
// scheduled queue (and dispatching a mailbox fiber) if it wasn't already scheduled.
//
// The drain LOOP is codegen-emitted (`nomu_actor_drain`), not here: it must hold the mailbox and
// message as tracked addrspace(1) roots across each handler call, which C can't. It loops over
// `nomuSchedMailboxPop` (FIFO pop, NULL on empty + clears the drain flag), running `msg->thunk(msg)` on
// each message until the mailbox is empty. Codegen calls both scheduler functions directly. Each module
// that uses actors emits the loop weak-ODR, and creating an actor stores its address in the scheduler.

#endif

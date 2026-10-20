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

// String: a 16-byte bit-stealing value, `{ i64 word0, i64 word1 }` (task 121 Representation; 176 shape).
// `word0` is inline UTF-8 bytes (`small`), a buffer pointer (`immortal`/`heap`), or empty. `word1` carries
// the count in its low 56 bits and the 4-bit discriminant in its top nibble: `small=0` (zeroed value = the
// empty string), `immortal=1`, `heap=2`. The pointer word stays clean and untagged so a moving collector
// relocates it with no masking. The C floor currently produces `immortal` (literals, concat, readLine).
typedef struct { uint64_t word0; uint64_t word1; } String;

#define NOMU_STR_TAG_SMALL     0u
#define NOMU_STR_TAG_IMMORTAL  1u
#define NOMU_STR_TAG_HEAP      2u
#define NOMU_STR_COUNT_MASK    0x00FFFFFFFFFFFFFFULL   // low 56 bits of word1 (bytes 8–14)

// Pack a pointer-backed (`immortal`/`heap`) String from a buffer pointer, byte count, and tag.
// Build a `StringBase` value with a given tag (the bit-stealing layout, task 121). The only remaining C
// String constructor — used by the privileged `rt_read_line` (I/O). Codegen owns the ops that read a
// `StringBase` back (`count`/`bytePointer` → `strLen`/`strPtr` in `LLVMGen`), so no reader helper lives here.
static inline String nomu_str_make(const char* ptr, int64_t len, uint64_t tag) {
    String s;
    s.word0 = (uint64_t)(uintptr_t)ptr;
    s.word1 = (tag << 60) | ((uint64_t)len & NOMU_STR_COUNT_MASK);
    return s;
}

// A fiber is opaque outside the privileged runtime; generated code only holds handles.
typedef struct Fiber Fiber;

// A structured spawn handle: a fiber whose result we will join.
typedef struct { Fiber* fiber; } SpawnHandle;

// ---- Memory (privileged) ----
// Managed allocation is codegen's self-hosted seam (`__nomu_selfhost_alloc` → the Nomu Immix allocator);
// nothing here allocates on the managed heap.
void  rt_free(void* p);
void* rt_raw_alloc(int64_t bytes, int64_t align);   // task 125 — unmanaged off-heap memory (RawPtr/Ptr<T>)
void  rt_raw_free(void* p);                          // task 125 — free rt_raw_alloc memory
void  rt_bounds_trap(int64_t idx, int64_t len);   // M6 stdlib — array subscript out-of-range trap
void  rt_gc_write_barrier(void* obj, void* slot, void* val);   // generational write barrier slow path

// ---- Core floor: pure value primitives ----
// The `String` type is off the C floor (task 121): literals, `allocHeap`, `count`, and `bytePointer` are all
// codegen, and the surface is Nomu. No String primitive is declared here.
void   rt_print_double(double x);   // M6 stdlib — print a Double: shortest round-tripping form, always with a decimal point, + newline

// ---- Privileged: blocking primitives + structured concurrency ----
int64_t rt_sleep_ms(int64_t ms);
String  rt_read_line(int fd);   // one stdin line; parks the fiber until input arrives (the stdin poller)
Fiber*  fiber_spawn(void* (*fn)(void*), void* arg);
void*   spawn_join(SpawnHandle* h, int64_t final);   // final: structured scope-exit join (150.3.13)

// ---- Actor mutex (opaque, heap-allocated) — C backend only ----
// The C backend inlines a `pthread_mutex_t` in the actor struct; it has no portable layout for the
// LLVM backend. The LLVM backend does NOT use this: it drives actors through the mailbox ABI below
// (M6 · 6.4). Kept for the C backend's mutex-serialized actor.
void* rt_mutex_new(void);
void  rt_mutex_lock(void* m);
void  rt_mutex_unlock(void* m);

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
// `rt_actor_send` enqueues `msg` on `mailbox` and returns after appending the mailbox to the global
// scheduled queue (and dispatching a mailbox fiber) if it wasn't already scheduled.
//
// The drain LOOP is codegen-emitted (`nomu_actor_drain`), not here: it must hold the mailbox and
// message as tracked addrspace(1) roots across each handler call, which C can't. It loops over
// `rt_mailbox_pop` (FIFO pop, NULL on empty + clears the drain flag), running `msg->thunk(msg)` on
// each message until the mailbox is empty.
void  rt_actor_send(void* mailbox, void* msg);
void* rt_mailbox_pop(void* mailbox);

#endif

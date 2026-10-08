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
// half is free for future in-object GC metadata / flags). Mark/log/forwarding bits live in MMTk side
// metadata, not here. Replaces the vestigial `refcount` (was written =1, never read).
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
static inline String nomu_str_make(const char* ptr, int64_t len, uint64_t tag) {
    String s;
    s.word0 = (uint64_t)(uintptr_t)ptr;
    s.word1 = (tag << 60) | ((uint64_t)len & NOMU_STR_COUNT_MASK);
    return s;
}
static inline int64_t     nomu_str_len(String s) { return (int64_t)(s.word1 & NOMU_STR_COUNT_MASK); }
static inline uint64_t    nomu_str_tag(String s) { return s.word1 >> 60; }
// The UTF-8 byte pointer. `immortal`/`small`/empty keep bytes at `word0` (a static buffer, inline bytes, or
// null for the empty string). A `heap` String's `word0` is the `StringStorage` object base, so its bytes sit
// past the `{ header, cap }` prefix — offset 16 (task 176.2). `small` inline bytes (121.3) are not produced
// yet; when they are this grows a third case returning `&s.word0`.
static inline const char* nomu_str_ptr(String s) {
    if (nomu_str_tag(s) == NOMU_STR_TAG_HEAP) return (const char*)(uintptr_t)s.word0 + 16;
    return (const char*)(uintptr_t)s.word0;
}

// A fiber is opaque outside the privileged runtime; generated code only holds handles.
typedef struct Fiber Fiber;

// A structured spawn handle: a fiber whose result we will join.
typedef struct { Fiber* fiber; } SpawnHandle;

// ---- Allocation seam (privileged; the heap alloc/free the generated code uses) ----
void* rt_alloc(size_t size);
void* rt_alloc_immortal(size_t size);   // M6 · 6.2.4 — non-moving String buffers (immortal interim)
void  rt_free(void* p);
void* rt_raw_alloc(int64_t bytes, int64_t align);   // task 125 — unmanaged off-heap memory (RawPtr/Ptr<T>)
void  rt_raw_free(void* p);                          // task 125 — free rt_raw_alloc memory
void  rt_bounds_trap(int64_t idx, int64_t len);   // M6 stdlib — array subscript out-of-range trap
void  rt_gc_write_barrier(void* obj, void* slot, void* val);   // M6 · 6.3.1 — generational write barrier

// ---- Core floor: pure value primitives ----
String rt_str_lit(const char* data, int64_t len);
// Concatenation is lowered in codegen (task 176.2): the compiler emits the plan-aware managed `StringStorage`
// alloc (so a live `heap` String in the caller is shaped-rooted across it) and these two gc-leaf helpers do
// the byte work with no managed allocation between them. `rt_str_snapshot` copies both inputs into one fresh
// off-heap buffer *before* the alloc (so the alloc relocating the inputs can't strand the copy); `rt_str_fill`
// blits that snapshot into the storage body and frees it.
void* rt_str_snapshot(String a, String b);
void  rt_str_fill(void* body, void* snapshot, int64_t len);
void   rt_print_double(double x);   // M6 stdlib — print a Double: shortest round-tripping form, always with a decimal point, + newline

// ---- Privileged: blocking primitives + structured concurrency ----
int64_t rt_sleep_ms(int64_t ms);
String  rt_read_line(int fd);
Fiber*  fiber_spawn(void* (*fn)(void*), void* arg);
void*   spawn_join(SpawnHandle* h, int64_t final);   // final: structured scope-exit join (150.3.13)

// ---- Actor mutex (opaque, heap-allocated) — C backend only ----
// The C backend inlines a `pthread_mutex_t` in the actor struct; it has no portable layout for the
// LLVM backend. The LLVM backend does NOT use this: it drives actors through the mailbox ABI below
// (M6 · 6.4). Kept for the C backend's mutex-serialized actor.
void* rt_mutex_new(void);
void  rt_mutex_lock(void* m);
void  rt_mutex_unlock(void* m);

// ---- Actor mailbox (M6 · 6.4 · fire-and-forget message-send, LLVM backend) ----
// The decided actor model (`concurrency.md` §9, fire-and-forget revision 2026-08-12): a send enqueues
// a message on the actor's mailbox and RETURNS immediately (the sender never waits, gets no reply).
// Handlers run on fibers rented from a program-global pool, one drain per actor at a time (serial,
// non-reentrant). There is no reply/ask of any kind — fire-and-forget is the only actor operation
// (§9). Teardown is structural — actor + mailbox are ordinary GC objects, so the runtime allocates
// nothing per-actor and frees nothing here.
//
// ABI contract with codegen (`Lowering.swift`). The mailbox and message are GC-allocated objects
// with fixed layouts this C code reaches without knowing the actor's fields / the handler's args.
// The actor object is unchanged (class-shaped) except its last slot holds a pointer to its mailbox;
// codegen loads that at the call site, so this code never parses the actor. Codegen supplies the GC
// pointer maps.
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

// ---- GC root scanning (design: backend.md GC backend substrate; runtime.md §6) ----
// Parse the process's `__llvm_stackmaps` section into a return-address → live-GC-slot index.
// Idempotent; called lazily by the walk. Inert until M6 turns on collection.
void nomu_gc_stackmap_init(void);
// Called once per distinct live GC root found while walking a stack: `slot` is the stack address
// the pointer lives at, `value` is the pointer. (M6's collector updates `*slot` on relocation.)
typedef void (*nomu_root_visitor)(void** slot, void* value, void* userdata);
// Walk the current stack for GC roots, from the caller's frame up, invoking `visit` per root
// (D4 single-stack walk). Shaped for M6 reuse: it drives a libunwind cursor, so a parked fiber's
// saved context can be walked the same way (M6 passes the fiber's context instead of the current).
void nomu_gc_walk_current(nomu_root_visitor visit, void* userdata);
// M6 · 6.2.1 — walk a stopped carrier's stack for GC roots. `carrier_tls` is the carrier's opaque
// token (the `pthread_self` handed to `nomu_gc_bind_mutator`). At STW the carrier is parked at a
// safepoint and its register context saved; this walks that context the same way as the current
// stack. The MMTk binding calls this from `scan_roots_in_mutator_thread`. Until the STW handshake
// saves contexts (6.2.3) no carrier is ever stopped for GC, so this reports no roots.
void nomu_gc_walk_carrier(void* carrier_tls, nomu_root_visitor visit, void* userdata);
// M6 · 6.2.2 — walk one parked fiber's stack (seeded from its saved `ucontext`), and over the whole
// live-fiber registry, every parked fiber's stack (only PARKED has a root-bearing saved context; the
// on-CPU fiber is scanned via its carrier, a never-run RUNNABLE fiber holds no roots). The MMTk
// binding calls the latter from `scan_vm_specific_roots`. Inert until collection turns on.
void nomu_gc_walk_fiber(Fiber* f, nomu_root_visitor visit, void* userdata);
void nomu_gc_scan_parked_fibers(nomu_root_visitor visit, void* userdata);

#endif

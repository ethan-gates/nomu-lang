// Nomu privileged runtime (M4.13) — the trusted core: allocator, M:N fiber
// scheduler, timer heap, I/O poller, and the process entry point. Carved verbatim
// from the former embedded preamble; the scheduler/timer/poller internals stay
// `static`, while the symbols generated code calls have external linkage via
// nomu_runtime.h. (Design: m4.13-spec.md §1, level 1.)
#define _XOPEN_SOURCE 600
#define _DARWIN_C_SOURCE
#include "runtime.h"
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>
#define UNW_LOCAL_ONLY
#include <libunwind.h>
#ifdef __APPLE__
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h> // _mh_execute_header (M8.4.3: locate __llvm_stackmaps)
#include <sys/event.h>
#endif

// ---- GC binding (MMTk, M6 · 6.1.1) — implemented in Rust (src/gcbinding), NoGC to start ----
extern void nomu_gc_init(size_t heap_bytes);
extern void* nomu_gc_bind_mutator(void* tls);
extern void* nomu_gc_alloc(void* mutator, size_t size, size_t align);
extern void* nomu_gc_alloc_immortal(void* mutator, size_t size, size_t align);
extern void nomu_gc_write_barrier_post(void* mutator, void* src, void* slot, void* target);
extern void nomu_gc_report_stats(void);   // M6 · 6.3.2 — footprint report (NOMU_GC_STATS)

// One MMTk mutator per carrier thread (Q1). Bound lazily on the thread's first allocation; a fiber
// migrating carriers allocates against whichever carrier it currently runs on (thread-local storage
// gives the per-carrier split for free). MMTk mutators are not shared across threads.
// Exported (not `static`) so the §6.6 codegen-inlined alloc fast path can read the current carrier's
// mutator as a thread-local global; null until the carrier's first allocation binds it (→ slow path).
_Thread_local void* rt_mutator = NULL;

// ---- Allocation seam ----
// Routed through MMTk (NoGC): bump-allocate on the carrier's mutator. MMTk returns raw memory, so we
// zero it to preserve the previous `calloc` contract (Nomu relies on zero-initialized fields) — this
// also zeroes the `ObjectHeader.type_id` (6.1.2), which codegen fills in at 6.1.3.
void* rt_alloc(size_t size) {
    if (!rt_mutator) {
        rt_mutator = nomu_gc_bind_mutator((void*)pthread_self());
    }
    void* p = nomu_gc_alloc(rt_mutator, size, 8);
    if (!p) {
        fputs("out of memory\n", stderr);
        exit(1);
    }
    memset(p, 0, size);
    return p;
}

// Immortal allocation seam (M6 · 6.2.4): non-moving, never-collected memory for String buffers under
// the moving collector (the immortal interim, Q6). Same lazy-bind + zero contract as rt_alloc.
void* rt_alloc_immortal(size_t size) {
    if (!rt_mutator) {
        rt_mutator = nomu_gc_bind_mutator((void*)pthread_self());
    }
    void* p = nomu_gc_alloc_immortal(rt_mutator, size, 8);
    if (!p) {
        fputs("out of memory\n", stderr);
        exit(1);
    }
    memset(p, 0, size);
    return p;
}

// ---- Generational write barrier seam (M6 · 6.3.1) ----
// The codegen `__nomu_write_barrier` seam stores `val` into `*slot` (a managed reference field of the
// managed object `obj`) and then calls this. It forwards to the MMTk object-remembering post-barrier
// on the current carrier's mutator, which — under GenImmix — remembers `obj` the first time a mature
// object is mutated so a nursery collection sees the new cross-generation pointer. Under NoGC/Immix
// the mutator's barrier is `NoBarrier` and this is a no-op (the seam calls it unconditionally; the
// plan decides — collector-agnostic, 6.0.5). Never triggers GC, so its call site stays `gc-leaf`.
// `rt_mutator` is always bound here: a store into a managed object means that object was allocated on
// this carrier's (or some carrier's) mutator, and any carrier that ran Nomu code has bound one — but
// bind lazily anyway to be safe against a store before this thread's first allocation.
void rt_gc_write_barrier(void* obj, void* slot, void* val) {
    if (!rt_mutator) {
        rt_mutator = nomu_gc_bind_mutator((void*)pthread_self());
    }
    nomu_gc_write_barrier_post(rt_mutator, obj, slot, val);
}

// ---- GC pointer maps (M6 · 6.1.3) ----
// Codegen emits these per program: `_data` = each type-id's `[count, off…]` concatenated,
// `_index[id]` = that id's start in `_data`, `_count` = number of type-ids (see Lowering.swift).
extern const int32_t nomu_gc_typemap_data[];
extern const int32_t nomu_gc_typemap_index[];
extern const int64_t nomu_gc_typemap_count;
// Parallel per-type-id total object byte size (M6 · 6.2.4): `_sizes[id]` = the fixed size of every
// object of that type (header included). Codegen emits it beside the pointer maps.
extern const int32_t nomu_gc_typemap_sizes[];
// Parallel per-type-id kind + array element stride (M6 stdlib · Slice 4): `_kind[id]` is 0 for a
// fixed-size object, 1 for a variable-size array buffer; `_stride[id]` is one element's byte size for
// an array buffer (0 otherwise). Lets the collector size/scan a buffer from its `cap`/`len`.
extern const int32_t nomu_gc_typemap_kind[];
extern const int32_t nomu_gc_typemap_stride[];

// Managed-field byte offsets for a type-id (NULL if out of range); *out_count receives the count.
// The binding's `scan_object` and the self-check below both walk objects through this.
const int32_t* nomu_gc_typemap(uint64_t type_id, int32_t* out_count) {
    if (type_id >= (uint64_t)nomu_gc_typemap_count) {
        *out_count = 0;
        return NULL;
    }
    const int32_t* entry = &nomu_gc_typemap_data[nomu_gc_typemap_index[type_id]];
    *out_count = entry[0];
    return entry + 1;
}

// Total object byte size for a type-id (M6 · 6.2.4). The binding's `ObjectModel::get_current_size`
// reads this to size an object for copying — every object of a given type-id is this fixed size.
// Returns 0 for an out-of-range id (a bug: every live object carries a codegen-assigned id).
uint64_t nomu_gc_typesize(uint64_t type_id) {
    if (type_id >= (uint64_t)nomu_gc_typemap_count) {
        return 0;
    }
    return (uint64_t)nomu_gc_typemap_sizes[type_id];
}

// Object kind for a type-id (M6 stdlib · Slice 4): 0 = fixed-size, 1 = variable-size array buffer.
// The binding's `get_current_size`/`scan_object` branch on this.
int32_t nomu_gc_typekind(uint64_t type_id) {
    if (type_id >= (uint64_t)nomu_gc_typemap_count) {
        return 0;
    }
    return nomu_gc_typemap_kind[type_id];
}

// Array element byte stride for an array-buffer type-id (M6 stdlib · Slice 4). 0 for a fixed type.
uint64_t nomu_gc_typestride(uint64_t type_id) {
    if (type_id >= (uint64_t)nomu_gc_typemap_count) {
        return 0;
    }
    return (uint64_t)nomu_gc_typemap_stride[type_id];
}

// Map-walk self-check (6.1 exit): dump every type's pointer map. Gated by NOMU_GC_TYPEMAPS so it is
// off for normal runs; a test compiles a program with known types and diffs this against expectation.
static void nomu_gc_dump_typemaps(void) {
    fprintf(stderr, "typemaps: %lld\n", (long long)nomu_gc_typemap_count);
    for (int64_t id = 0; id < nomu_gc_typemap_count; id++) {
        int32_t n;
        const int32_t* offs = nomu_gc_typemap((uint64_t)id, &n);
        fprintf(stderr, "  type %lld: %llu bytes, %d managed [",
                (long long)id, (unsigned long long)nomu_gc_typesize((uint64_t)id), n);
        for (int32_t i = 0; i < n; i++) {
            fprintf(stderr, "%s%d", i ? " " : "", offs[i]);
        }
        fprintf(stderr, "]\n");
    }
}

void rt_free(void* p) { free(p); }

// Array bounds violation (M6 stdlib · Slice 3). Codegen emits a check on every subscript and calls
// this on an out-of-range index; it prints and aborts (Swift-style trap). Never returns.
void rt_bounds_trap(int64_t idx, int64_t len) {
    fprintf(stderr, "fatal error: array index %lld out of range for length %lld\n",
            (long long)idx, (long long)len);
    abort();
}


// ---- Fiber scheduler (M4.5: multi-carrier, idle sleep, fiber-aware timer) ----
#define RT_MAX_FIBERS 256
#define RT_MAX_CARRIERS 16
#define RT_STACK_SIZE (128 * 1024)

// FIBER_RUNNING marks a fiber currently on-CPU on some carrier (M6 · 6.2.2). Its live registers are
// on the carrier, not in `ctx`, so the GC scans it via that carrier's stack (6.2.1) and the
// parked-fiber scan skips it; `ctx` is only a valid stack to walk once the fiber has swapped out
// (PARKED, or RUNNABLE waiting to resume from its last park point).
typedef enum {
    FIBER_RUNNABLE,
    FIBER_RUNNING,
    FIBER_PARKED,
    FIBER_DONE
} FiberStatus;

struct Fiber {
    ucontext_t ctx;
    char* stack;
    FiberStatus status;
    void* result;
    struct Fiber* joiner;
    void* (*fn)(void*);
    void* arg;
    struct Fiber* rt_prev; // M6 · 6.2.2 — global live-fiber registry (intrusive doubly-linked list)
    struct Fiber* rt_next;
    struct Fiber* pool_next; // M6 · 6.4 — mailbox-fiber free-list link (guarded by rt_queue_mu)
};

static Fiber* rt_run_queue[RT_MAX_FIBERS];
static int rt_rq_head = 0, rt_rq_tail = 0;
static int rt_active = 0;
static long rt_active_drains = 0;   // M6 · 6.4 — outstanding actor drains; see the mailbox section
static pthread_mutex_t rt_queue_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t rt_queue_cond = PTHREAD_COND_INITIALIZER;
static _Thread_local Fiber* rt_current = NULL;
static _Thread_local ucontext_t rt_sched_ctx;
static Fiber* rt_main_fiber = NULL; // the Nomu `main` fiber (first spawn); scopes the 6.2.2 parked smoke

// ---- Global live-fiber registry (M6 · 6.2.2, Q8) ----
// The single source of truth for "every fiber that could hold GC roots." An intrusive doubly-linked
// list guarded by rt_queue_mu (spawn/complete already hold it, so registry upkeep is off the hot
// path): O(1) insert on spawn, O(1) remove on completion. At STW the collector iterates it to scan
// every parked/runnable fiber's stack (a fiber is scannable wherever it waits — no per-wait-list
// opt-in that a missed list could silently drop). A fiber currently on a carrier (FIBER_RUNNING) is
// scanned through that carrier instead (6.2.1) and skipped here.
static Fiber* rt_fiber_list = NULL;

// Both callers hold rt_queue_mu.
static void rt_registry_insert(Fiber* f) {
    f->rt_prev = NULL;
    f->rt_next = rt_fiber_list;
    if (rt_fiber_list) {
        rt_fiber_list->rt_prev = f;
    }
    rt_fiber_list = f;
}

static void rt_registry_remove(Fiber* f) {
    if (f->rt_prev) {
        f->rt_prev->rt_next = f->rt_next;
    } else {
        rt_fiber_list = f->rt_next;
    }
    if (f->rt_next) {
        f->rt_next->rt_prev = f->rt_prev;
    }
    f->rt_prev = f->rt_next = NULL;
}

// ---- Stop-the-world handshake (M6 · 6.2.3, Q3/Q4) ----
// Cooperative STW for the M:N scheduler. A carrier (an MMTk mutator, Q1) is either running Nomu code
// — where it reaches a safepoint at every non-leaf call, allocation, and the back-edge poll — or
// sitting in the scheduler between fibers (holding no roots). The initiator raises __nomu_stop_world;
// a running carrier parks at its next poll (saving a scannable context), an idle carrier parks at the
// scheduler dispatch. The initiator waits until every carrier has parked, the collector scans roots
// (running carriers via their saved context, 6.2.1; parked fibers via the registry, 6.2.2), then
// resume clears the flag and wakes them. The flag is a single read-mostly global (written twice per
// GC) rather than the per-carrier flag of the Q3 decision — identical correctness for a full STW;
// per-carrier is a deferred perf refinement (avoids the shared-line read traffic on many carriers).
volatile int __nomu_stop_world = 0; // read by the inlined poll (Lowering.swift) and the scheduler

typedef struct {
    pthread_t tls; // carrier thread id (the nomu_gc_bind_mutator token)
    int in_use;
    volatile int parked; // reached a safepoint / dispatch and is waiting for resume
    int has_ctx;         // ctx below is a running fiber's stack (scan it); else idle (no roots)
    unw_context_t ctx;   // saved at the safepoint, for the carrier root walk (6.2.1)
} CarrierCB;

static CarrierCB rt_carriers[RT_MAX_CARRIERS];
static int rt_ncarriers_reg = 0;
static pthread_mutex_t rt_stw_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t rt_stw_cond = PTHREAD_COND_INITIALIZER; // carrier ↔ initiator, both directions
static _Thread_local CarrierCB* rt_self_cb = NULL;
// M6 · 6.2.4 — set by a carrier that triggers a collection (in `nomu_gc_block_for_gc`), cleared by
// `nomu_gc_resume_the_world` at the end of the cycle. Keeps the triggering carrier blocked across the
// collection even before `__nomu_stop_world` is raised (the GC worker raises that a moment later).
static volatile int rt_gc_wanted = 0;

// Register the current carrier on scheduler entry (once per carrier thread), making it STW-visible.
static void rt_carrier_register(void) {
    pthread_mutex_lock(&rt_stw_mu);
    CarrierCB* cb = &rt_carriers[rt_ncarriers_reg++];
    cb->tls = pthread_self();
    cb->in_use = 1;
    cb->parked = 0;
    cb->has_ctx = 0;
    rt_self_cb = cb;
    pthread_mutex_unlock(&rt_stw_mu);
}

// Park the current carrier for STW until the world resumes. `ctx` (or NULL for an idle carrier with no
// roots) is the scannable context captured at the safepoint. Must NOT be called holding rt_queue_mu.
static void rt_carrier_park_for_stw(const unw_context_t* ctx) {
    CarrierCB* cb = rt_self_cb;
    pthread_mutex_lock(&rt_stw_mu);
    if (ctx) {
        cb->ctx = *ctx;
        cb->has_ctx = 1;
    } else {
        cb->has_ctx = 0;
    }
    cb->parked = 1;
    pthread_cond_broadcast(&rt_stw_cond); // tell the initiator we reached the safepoint
    while (__nomu_stop_world) {
        pthread_cond_wait(&rt_stw_cond, &rt_stw_mu);
    }
    cb->parked = 0;
    cb->has_ctx = 0;
    pthread_mutex_unlock(&rt_stw_mu);
}

// Must be called with rt_queue_mu held. Signals a sleeping carrier.
static void rt_rq_push(Fiber* f) {
    rt_run_queue[rt_rq_tail % RT_MAX_FIBERS] = f;
    rt_rq_tail++;
    pthread_cond_signal(&rt_queue_cond);
}

// Must be called with rt_queue_mu held.
static Fiber* rt_rq_pop(void) {
    if (rt_rq_head == rt_rq_tail) {
        return NULL;
    }
    Fiber* f = rt_run_queue[rt_rq_head % RT_MAX_FIBERS];
    rt_rq_head++;
    return f;
}

// Lock-handoff park protocol (M6 · 6.4). rt_queue_mu is held across every fiber↔scheduler context
// switch: the scheduler switches INTO a fiber with the lock held, and a fiber switches BACK to the
// scheduler with the lock held. A fiber releases the lock right after it is switched in (before
// running any Nomu code) and re-acquires it to park or finish. This closes the window where a
// waker could re-queue a fiber whose context is not yet fully saved by swapcontext — the bug that
// showed up as a lost-wakeup deadlock / SIGBUS under heavy actor↔actor parking. A fiber is only
// ever eligible for wakeup once the scheduler has regained control (context fully saved) and later
// released the lock (by switching into the next fiber, or via cond_wait).
static void rt_fiber_trampoline(void) {
    Fiber* self = rt_current;
    pthread_mutex_unlock(&rt_queue_mu); // release the lock handed over by the scheduler on switch-in
    self->result = self->fn(self->arg);
    pthread_mutex_lock(&rt_queue_mu);
    self->status = FIBER_DONE;
    rt_registry_remove(self); // M6 · 6.2.2 — done fibers hold no roots; drop from the registry
    rt_active--;
    if (self->joiner) {
        rt_rq_push(self->joiner);
        self->joiner = NULL;
    }
    pthread_cond_broadcast(&rt_queue_cond); // wake all carriers to re-check rt_active == 0
    swapcontext(&self->ctx, &rt_sched_ctx); // hand the lock back to the scheduler (held across)
}

Fiber* fiber_spawn(void* (*fn)(void*), void* arg) {
    Fiber* f = (Fiber*)calloc(1, sizeof(Fiber));
    f->stack = (char*)malloc(RT_STACK_SIZE);
    f->fn = fn;
    f->arg = arg;
    f->status = FIBER_RUNNABLE;
    getcontext(&f->ctx);
    f->ctx.uc_stack.ss_sp = f->stack;
    f->ctx.uc_stack.ss_size = RT_STACK_SIZE;
    f->ctx.uc_link = NULL;
    makecontext(&f->ctx, rt_fiber_trampoline, 0);
    pthread_mutex_lock(&rt_queue_mu);
    rt_active++;
    rt_registry_insert(f); // M6 · 6.2.2 — track from spawn so the fiber is scannable wherever it waits
    rt_rq_push(f);
    pthread_mutex_unlock(&rt_queue_mu);
    return f;
}

static void rt_scheduler_run(void) {
    rt_carrier_register(); // M6 · 6.2.3 — this carrier is now STW-visible
    pthread_mutex_lock(&rt_queue_mu);
    while (1) {
        // 6.2.3 — an idle/dispatching carrier parks for STW here rather than picking up a fiber, so it
        // holds no roots and starts no mutation while the world is stopped (no ctx: nothing to scan).
        if (__nomu_stop_world) {
            pthread_mutex_unlock(&rt_queue_mu);
            rt_carrier_park_for_stw(NULL);
            pthread_mutex_lock(&rt_queue_mu);
            continue;
        }
        Fiber* f = rt_rq_pop();
        if (f) {
            f->status = FIBER_RUNNING; // M6 · 6.2.2 — on-CPU; scanned via this carrier, not the registry
            rt_current = f;
            // Switch in with the lock HELD (handoff protocol); f releases it before running Nomu
            // code and hands it back here when it parks/finishes. No unlock/relock around the switch.
            swapcontext(&rt_sched_ctx, &f->ctx);
        } else if (rt_active == 0 && rt_active_drains == 0) {
            break;   // no user fibers and no outstanding actor drains — quiescent (§9 drain-then-collect)
        } else {
            pthread_cond_wait(&rt_queue_cond, &rt_queue_mu);
        }
    }
    pthread_mutex_unlock(&rt_queue_mu);
}

static void* rt_carrier_entry(void* _) {
    rt_scheduler_run();
    return NULL;
}

void* spawn_join(SpawnHandle* h) {
    pthread_mutex_lock(&rt_queue_mu);
    if (h->fiber->status != FIBER_DONE) {
        h->fiber->joiner = rt_current;
        rt_current->status = FIBER_PARKED;
        // Park with the lock HELD (handoff protocol): the scheduler receives it, and this fiber
        // becomes wakeable only after its context is fully saved. Resumes here with the lock held.
        swapcontext(&rt_current->ctx, &rt_sched_ctx);
    }
    pthread_mutex_unlock(&rt_queue_mu);
    return h->fiber->result;
}

// ---- Actor mailbox + mailbox-fiber pool (M6 · 6.4 · fire-and-forget message-send) ----
// The decided actor model (`concurrency.md` §9, fire-and-forget revision 2026-08-12), backing the
// LLVM backend. An actor is an ordinary GC object whose fixed prefix carries a mailbox (a FIFO of
// GC-allocated messages); a send enqueues a message and RETURNS immediately (the sender never waits).
// A mailbox with pending messages joins a **global scheduled-mailbox queue**; a **capped pool of
// mailbox fibers** pulls mailboxes off that queue and drains them (at most one drain per mailbox at a
// time — the `scheduled` flag — so handling is serial, non-reentrant, per-sender FIFO). Teardown is
// structural: nothing here is allocated per actor. Layout is the ABI contract in runtime.h.
typedef struct NomuMsg {
    uint64_t header;
    struct NomuMsg* next;                // FIFO link (GC-scanned)
    void (*thunk)(void* msg);            // codegen per-handler thunk: reads self+args, runs the handler
    void* self;                          // the receiver actor (GC-scanned); the rest is args…
} NomuMsg;

typedef struct NomuMailbox {
    uint64_t header;
    NomuMsg* mb_head;                // GC-scanned
    NomuMsg* mb_tail;                // GC-scanned
    int64_t scheduled;              // 1 while queued for / undergoing draining
    struct NomuMailbox* sched_next; // GC-scanned — intrusive link in the global scheduled-mailbox queue
} NomuMailbox;

// The global scheduled-mailbox queue: an intrusive FIFO through `sched_next` of every mailbox with
// pending messages awaiting a mailbox fiber. `rt_sched_head` is a **GC root** (reported by
// nomu_gc_scan_parked_fibers); since `sched_next` is a scanned field, rooting the head keeps the whole
// chain — and each queued mailbox's pending messages and receiver actor — alive even when the actor is
// otherwise unreferenced. This is what makes fire-and-forget outstanding work survive GC. Guarded by
// rt_queue_mu; non-static so the root scan can read it.
NomuMailbox* rt_sched_head = NULL;
static NomuMailbox* rt_sched_tail = NULL;

// The mailbox-fiber pool: a CAPPED set of reusable fibers that pull mailboxes off the scheduled queue
// and drain them. `rt_mbfiber_free` is a free-list of idle (parked) mailbox fibers; `rt_mbfiber_count`
// is how many exist (≤ the cap). Capping is what stops a churn of many concurrently-busy actors from
// spawning a fiber (a 128 KiB stack) each and overrunning the run queue — excess mailboxes wait in the
// scheduled queue and a busy fiber picks them up when it finishes its current one. Guarded by
// rt_queue_mu; mailbox fibers do not count toward rt_active (they are infrastructure).
#define RT_MAX_MAILBOX_FIBERS 64
static Fiber* rt_mbfiber_free = NULL;
static int rt_mbfiber_count = 0;

// `rt_active_drains` (declared with the scheduler globals) counts mailboxes currently `scheduled`:
// fire-and-forget sends create no user fiber, so `rt_active` alone would let the program exit with
// actor work still queued (silently dropped). It is ++'d on the 0→1 edge (rt_actor_send appends to the
// scheduled queue) and --'d on the 1→0 edge (a drain emptying its mailbox, rt_mailbox_pop); the
// scheduler exits only when rt_active == 0 AND it is 0 — drain-to-quiescence (§9 drain-then-collect).
// A self-sustaining actor keeps it > 0, so the program stays alive (a live server, §9).

// The drain LOOP is emitted by codegen, not written here: it must hold the mailbox + message as
// tracked addrspace(1) roots across each handler call (a moving GC can relocate them at a safepoint
// inside the handler), which C code can't. Codegen's `nomu_actor_drain(mailbox)` loops over
// rt_mailbox_pop → `msg->thunk(msg)` until the mailbox is empty. The C side here manages the pool and
// provides the non-safepoint-spanning `rt_mailbox_pop` primitive below.
extern void nomu_actor_drain(void* mailbox);

// Remove and return the head of the scheduled-mailbox queue (FIFO), or NULL if empty. Caller holds
// rt_queue_mu. The returned mailbox stays `scheduled` — the caller is now its drainer.
static NomuMailbox* rt_sched_pop(void) {
    NomuMailbox* mb = rt_sched_head;
    if (!mb) return NULL;
    rt_sched_head = mb->sched_next;
    if (!rt_sched_head) rt_sched_tail = NULL;
    mb->sched_next = NULL;
    return mb;
}

// A mailbox fiber's top level: pull a scheduled mailbox and drain it; when none remain, park on the
// free-list; repeat. Never returns. Handoff protocol: rt_queue_mu is held at every loop top and across
// every park, so a mailbox popped here is handed to nomu_actor_drain (which makes it a tracked root)
// with no GC window between.
static void rt_mailbox_fiber_main(void) {
    Fiber* self = rt_current;
    // Entered (first) / resumed (later) with the lock HELD by the scheduler — the loop-top invariant.
    while (1) {
        NomuMailbox* mb = rt_sched_pop();
        if (!mb) {
            self->pool_next = rt_mbfiber_free;   // no work — park on the free-list
            rt_mbfiber_free = self;
            self->status = FIBER_PARKED;
            swapcontext(&self->ctx, &rt_sched_ctx);   // hand lock to scheduler; resumes with lock HELD
            continue;                                 // lock held → loop-top invariant restored
        }
        pthread_mutex_unlock(&rt_queue_mu);
        nomu_actor_drain(mb);   // drains all of mb's messages; clears mb->scheduled when empty
        pthread_mutex_lock(&rt_queue_mu);
    }
}

// Create a fresh mailbox fiber. Caller holds rt_queue_mu. Registered so one parked inside an
// inline-blocking handler is scanned for roots like any fiber (6.2.2); an idle one holds no live roots.
static Fiber* rt_mailbox_fiber_new(void) {
    Fiber* f = (Fiber*)calloc(1, sizeof(Fiber));
    f->stack = (char*)malloc(RT_STACK_SIZE);
    f->status = FIBER_RUNNABLE;
    getcontext(&f->ctx);
    f->ctx.uc_stack.ss_sp = f->stack;
    f->ctx.uc_stack.ss_size = RT_STACK_SIZE;
    f->ctx.uc_link = NULL;
    makecontext(&f->ctx, rt_mailbox_fiber_main, 0);
    rt_registry_insert(f);
    return f;
}

// Ensure a mailbox fiber will service the scheduled queue: wake a parked one, else create one up to
// the cap. If all fibers are busy and at the cap, the newly-queued mailbox simply waits — a busy fiber
// pops it when it finishes its current mailbox. Caller holds rt_queue_mu; called on the 0→1 edge.
static void rt_mailbox_dispatch(void) {
    Fiber* f = rt_mbfiber_free;
    if (f) {
        rt_mbfiber_free = f->pool_next; f->pool_next = NULL;
        f->status = FIBER_RUNNABLE;
        rt_rq_push(f);
    } else if (rt_mbfiber_count < RT_MAX_MAILBOX_FIBERS) {
        f = rt_mailbox_fiber_new();
        rt_mbfiber_count++;
        rt_rq_push(f);
    }
    // else: all mailbox fibers busy and at the cap — the mailbox waits in the scheduled queue.
}

// Pop the next message from `mailbox` in FIFO order, or return NULL when empty. On empty it clears
// `scheduled` under the same lock hold a concurrent enqueue takes, so no message is lost: an enqueue
// either linked before we looked (this returns it) or arrives after the clear and redispatches a
// fresh drain. No safepoint/allocation inside → GC cannot move `mailbox` across this call, so
// codegen's tracked mailbox pointer stays valid. Called from codegen's `nomu_actor_drain`.
void* rt_mailbox_pop(void* mailbox) {
    NomuMailbox* mb = (NomuMailbox*)mailbox;
    pthread_mutex_lock(&rt_queue_mu);
    NomuMsg* msg = mb->mb_head;
    if (!msg) {
        mb->scheduled = 0;                       // 1→0 edge: this drain is finished
        if (--rt_active_drains == 0 && rt_active == 0) {
            pthread_cond_broadcast(&rt_queue_cond);   // may have reached quiescence — wake idle carriers to exit
        }
        pthread_mutex_unlock(&rt_queue_mu);
        return NULL;
    }
    mb->mb_head = msg->next;
    if (!mb->mb_head) mb->mb_tail = NULL;
    rt_gc_write_barrier(mb, &mb->mb_head, mb->mb_head);   // slot mutated; keep the moving GC's remset honest
    pthread_mutex_unlock(&rt_queue_mu);
    return msg;
}

// Enqueue `msg` on `mailbox` and return immediately — fire-and-forget (§9). On the 0→1 schedule edge,
// append the mailbox to the global scheduled queue (rooting its pending work for GC) and ensure a
// mailbox fiber will service it. The sender does not wait and gets no reply. The message stays
// reachable via the mailbox chain (mb_head/tail/next all GC-scanned); the barriers keep the moving
// GC's remembered set honest across the stores.
void rt_actor_send(void* mailbox_, void* msg_) {
    NomuMailbox* mb = (NomuMailbox*)mailbox_;
    NomuMsg* msg = (NomuMsg*)msg_;
    pthread_mutex_lock(&rt_queue_mu);
    msg->next = NULL;
    if (mb->mb_tail) {
        mb->mb_tail->next = msg;
        rt_gc_write_barrier(mb->mb_tail, &mb->mb_tail->next, msg);
    } else {
        mb->mb_head = msg;
        rt_gc_write_barrier(mb, &mb->mb_head, msg);
    }
    mb->mb_tail = msg;
    rt_gc_write_barrier(mb, &mb->mb_tail, msg);
    if (!mb->scheduled) {
        mb->scheduled = 1;
        mb->sched_next = NULL;
        if (rt_sched_tail) {
            rt_sched_tail->sched_next = mb;
            rt_gc_write_barrier(rt_sched_tail, &rt_sched_tail->sched_next, mb);
            rt_sched_tail = mb;
        } else {
            rt_sched_head = mb;
            rt_sched_tail = mb;
        }
        rt_active_drains++;      // outstanding scheduled mailbox (0→1); cleared when it empties
        rt_mailbox_dispatch();
    }
    pthread_mutex_unlock(&rt_queue_mu);
}

// ---- Actor mutex (opaque, heap-allocated) ----
// A `void*`-fronted `pthread_mutex_t` for the LLVM backend, which can't lay out the platform mutex
// inline. Additive to the ABI; the C backend keeps inlining `pthread_mutex_t` directly.
void* rt_mutex_new(void) {
    pthread_mutex_t* m = (pthread_mutex_t*)malloc(sizeof(pthread_mutex_t));
    pthread_mutex_init(m, NULL);
    return m;
}

void rt_mutex_lock(void* m) { pthread_mutex_lock((pthread_mutex_t*)m); }

void rt_mutex_unlock(void* m) { pthread_mutex_unlock((pthread_mutex_t*)m); }

// ---- Timer heap (M4.5) ----
#define RT_MAX_TIMERS 256

typedef struct {
    uint64_t expiry_ns;
    Fiber* fiber;
} TimerEntry;

static TimerEntry rt_timers[RT_MAX_TIMERS];
static int rt_timer_count = 0;
static pthread_mutex_t rt_timer_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t rt_timer_cond = PTHREAD_COND_INITIALIZER;

static uint64_t rt_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

// Min-heap helpers — must be called with rt_timer_mu held.
static void rt_timer_push(uint64_t expiry, Fiber* f) {
    int i = rt_timer_count++;
    rt_timers[i] = (TimerEntry){expiry, f};
    while (i > 0) {
        int p = (i - 1) / 2;
        if (rt_timers[p].expiry_ns <= rt_timers[i].expiry_ns) {
            break;
        }
        TimerEntry tmp = rt_timers[p];
        rt_timers[p] = rt_timers[i];
        rt_timers[i] = tmp;
        i = p;
    }
    pthread_cond_signal(&rt_timer_cond);
}

static void rt_timer_pop(void) {
    rt_timers[0] = rt_timers[--rt_timer_count];
    int i = 0;
    while (1) {
        int l = 2 * i + 1, r = 2 * i + 2, s = i;
        if (l < rt_timer_count && rt_timers[l].expiry_ns < rt_timers[s].expiry_ns) {
            s = l;
        }
        if (r < rt_timer_count && rt_timers[r].expiry_ns < rt_timers[s].expiry_ns) {
            s = r;
        }
        if (s == i) {
            break;
        }
        TimerEntry tmp = rt_timers[s];
        rt_timers[s] = rt_timers[i];
        rt_timers[i] = tmp;
        i = s;
    }
}

static void* rt_timer_thread(void* _) {
    pthread_mutex_lock(&rt_timer_mu);
    while (1) {
        if (rt_timer_count == 0) {
            pthread_cond_wait(&rt_timer_cond, &rt_timer_mu);
            continue;
        }
        uint64_t now = rt_now_ns();
        uint64_t next = rt_timers[0].expiry_ns;
        if (next > now) {
            struct timespec ts = {(time_t)(next / 1000000000ULL), (long)(next % 1000000000ULL)};
            pthread_cond_timedwait(&rt_timer_cond, &rt_timer_mu, &ts);
            continue;
        }
        Fiber* f = rt_timers[0].fiber;
        rt_timer_pop();
        pthread_mutex_unlock(&rt_timer_mu);
        pthread_mutex_lock(&rt_queue_mu);
        rt_rq_push(f);
        pthread_mutex_unlock(&rt_queue_mu);
        pthread_mutex_lock(&rt_timer_mu);
    }
    return NULL;
}

static void nomu_gc_smoke(void);        // M8.4.3 — defined below (current-stack root-walk smoke)
static void nomu_gc_smoke_parked(void); // M6 · 6.2.2 — defined below (parked-fiber root-walk smoke)

int64_t rt_sleep_ms(int64_t ms) {
    // M8.4.3 smoke (env-gated, inert otherwise): `sleep` is a safepoint (this call is a statepoint),
    // so at entry the caller's live GC roots are recorded. Walk them before parking the fiber.
    if (getenv("NOMU_GC_SMOKE")) {
        nomu_gc_smoke();
    }
    // M6 · 6.2.2 parked-fiber smoke: from `main`'s safepoint, scan a peer fiber that is parked
    // elsewhere (recovered from its saved ucontext, not the current stack). Scoped to `main` so the
    // parked worker's own sleep does not re-enter the scan and stall waiting for a peer.
    if (getenv("NOMU_GC_SMOKE_PARKED") && rt_current == rt_main_fiber) {
        nomu_gc_smoke_parked();
    }
    uint64_t expiry = rt_now_ns() + (uint64_t)ms * 1000000ULL;
    // Handoff protocol (M6 · 6.4): hold rt_queue_mu across the park so the timer thread's wake (which
    // takes rt_queue_mu to rq_push) can't run until this fiber's context is fully saved. Registering
    // on the timer heap under both locks is deadlock-free — the timer thread releases rt_timer_mu
    // before it ever reaches for rt_queue_mu.
    pthread_mutex_lock(&rt_queue_mu);
    pthread_mutex_lock(&rt_timer_mu);
    rt_timer_push(expiry, rt_current);
    pthread_mutex_unlock(&rt_timer_mu);
    rt_current->status = FIBER_PARKED;
    swapcontext(&rt_current->ctx, &rt_sched_ctx);
    pthread_mutex_unlock(&rt_queue_mu);
    return ms;
}

// ---- I/O poller (M4.4: kqueue, fiber-aware fd readiness) ----
#ifdef __APPLE__
static int rt_kq = -1;

static void rt_wait_readable(int fd) {
    // Handoff protocol (M6 · 6.4): hold rt_queue_mu across the park so the poller thread's wake (which
    // takes rt_queue_mu to rq_push) can't run until this fiber's context is fully saved. Registering
    // the kevent under rt_queue_mu is safe — the poller blocks in kevent() without that lock.
    struct kevent ev;
    EV_SET(&ev, fd, EVFILT_READ, EV_ADD | EV_ONESHOT, 0, 0, rt_current);
    pthread_mutex_lock(&rt_queue_mu);
    kevent(rt_kq, &ev, 1, NULL, 0, NULL);
    rt_current->status = FIBER_PARKED;
    swapcontext(&rt_current->ctx, &rt_sched_ctx);
    pthread_mutex_unlock(&rt_queue_mu);
}

static void* rt_poller_thread(void* _) {
    struct kevent events[32];
    while (1) {
        int n = kevent(rt_kq, NULL, 0, events, 32, NULL);
        for (int i = 0; i < n; i++) {
            Fiber* f = (Fiber*)events[i].udata;
            pthread_mutex_lock(&rt_queue_mu);
            rt_rq_push(f);
            pthread_mutex_unlock(&rt_queue_mu);
        }
    }
    return NULL;
}

String rt_read_line(int fd) {
    rt_wait_readable(fd);
    char buf[4096];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    if (n <= 0) {
        return rt_str_lit("", 0);
    }
    if (buf[n - 1] == '\n') {
        n--;
    }
    // Immortal (non-moving) buffer — String's raw `data` pointer must survive a moving GC (6.2.4).
    char* data = (char*)rt_alloc_immortal(sizeof(ObjectHeader) + (size_t)n + 1) + sizeof(ObjectHeader);
    memcpy(data, buf, (size_t)n);
    data[n] = '\0';
    return (String){.data = data, .len = (int64_t)n};
}
#else
// Non-macOS: readLine is not wired yet (epoll path unwritten, runtime.md §... poller).
String rt_read_line(int fd) {
    (void)fd;
    return rt_str_lit("", 0);
}
#endif

// ---- GC root scanning (design: backend.md GC backend substrate; runtime.md §6) ----
// Parse the `__llvm_stackmaps` section (stackmap v3) into a return-address → live-GC-slot index,
// then walk a stack (libunwind) mapping each frame's return address to its record and reading the
// live roots. Inert now — nothing calls this except the smoke path (M6 drives it from the
// collector). The layout follows llvm/Object/StackMapParser.h.
typedef struct {
    int reg;
    int32_t off;
} gc_slot; // Indirect [dwarf reg + off]; reg 31=SP, 29=FP

typedef struct {
    uintptr_t addr;
    int nslots;
    gc_slot* slots;
} gc_record; // one statepoint

static gc_record* gc_records = NULL;
static int gc_nrecords = 0;
static int gc_inited = 0;

static uint16_t gc_rd16(const uint8_t* p) { return (uint16_t)(p[0] | (p[1] << 8)); }

static uint32_t gc_rd32(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t gc_rd64(const uint8_t* p) { return (uint64_t)gc_rd32(p) | ((uint64_t)gc_rd32(p + 4) << 32); }

void nomu_gc_stackmap_init(void) {
    if (gc_inited) {
        return;
    }
    gc_inited = 1;
#ifdef __APPLE__
    unsigned long size = 0;
    const uint8_t* sm = getsectiondata(&_mh_execute_header, "__LLVM_STACKMAPS", "__llvm_stackmaps", &size);
    if (!sm || size < 16 || sm[0] != 3) {
        return; // no section, or unsupported version
    }
    uint32_t nfuncs = gc_rd32(sm + 4), nconsts = gc_rd32(sm + 8), nrecs = gc_rd32(sm + 12);
    const uint8_t* funcs = sm + 16;
    const uint8_t* recs = funcs + (size_t)nfuncs * 24 + (size_t)nconsts * 8; // records follow funcs+consts
    gc_records = (gc_record*)calloc(nrecs ? nrecs : 1, sizeof(gc_record));
    // Function records own their statepoint records in order (each says how many it has). The
    // record's absolute address = function address + instruction offset = the call's return address.
    const uint8_t* r = recs;
    for (uint32_t fi = 0; fi < nfuncs; fi++) {
        uint64_t faddr = gc_rd64(funcs + (size_t)fi * 24);
        uint64_t frecs = gc_rd64(funcs + (size_t)fi * 24 + 16);
        for (uint64_t k = 0; k < frecs; k++) {
            uint32_t ioff = gc_rd32(r + 8);
            uint16_t nloc = gc_rd16(r + 14);
            const uint8_t* locs = r + 16;
            gc_record* gr = &gc_records[gc_nrecords++];
            gr->addr = (uintptr_t)(faddr + ioff);
            gr->slots = (gc_slot*)calloc(nloc ? nloc : 1, sizeof(gc_slot));
            gr->nslots = 0;
            // Skip the 3 leading meta constants (calling conv, flags, #deopt); the rest are the live
            // GC pointers, recorded as (base, derived) pairs — dedup to distinct slots.
            for (int li = 3; li < nloc; li++) {
                const uint8_t* L = locs + (size_t)li * 12;
                uint8_t kind = L[0];
                if (kind != 3 /*Indirect*/ && kind != 1 /*Register*/) {
                    continue;
                }
                int reg = gc_rd16(L + 4);
                int32_t off = (int32_t)gc_rd32(L + 8);
                int dup = 0;
                for (int s = 0; s < gr->nslots; s++) {
                    if (gr->slots[s].reg == reg && gr->slots[s].off == off) {
                        dup = 1;
                        break;
                    }
                }
                if (!dup) {
                    gr->slots[gr->nslots].reg = reg;
                    gr->slots[gr->nslots].off = off;
                    gr->nslots++;
                }
            }
            // Advance to the next record: locations, align 8, then NumLiveOuts (u16) + live-outs.
            size_t locend = (size_t)((locs + (size_t)nloc * 12) - r);
            locend = (locend + 7) & ~(size_t)7;
            uint16_t nlive = gc_rd16(r + locend);
            size_t recsz = (locend + 2 + (size_t)nlive * 4 + 7) & ~(size_t)7;
            r += recsz;
        }
    }
#endif
}

static gc_record* gc_lookup(uintptr_t ip) {
    for (int i = 0; i < gc_nrecords; i++) {
        if (gc_records[i].addr == ip) {
            return &gc_records[i];
        }
    }
    return NULL;
}

// Walk an arbitrary saved register context for GC roots (the shared core of the current-stack and
// stopped-carrier/parked-fiber walks — M6 · 6.2.1). Steps past the context's innermost frame into
// its callers; for each frame whose return address has a stackmap record, reads the live roots at
// (frame register + offset). The innermost frame is always a gc-leaf runtime C frame (the walker
// itself, or the `park`/`poll_slow`/`swapcontext` frame a stopped thread sits in), so skipping it
// is correct — the roots live in the Nomu callers.
static void nomu_gc_walk_context(unw_context_t* ctx, nomu_root_visitor visit, void* userdata) {
    nomu_gc_stackmap_init();
    unw_cursor_t cur;
    unw_init_local(&cur, ctx);
    while (unw_step(&cur) > 0) {
        unw_word_t ip = 0, sp = 0;
        unw_get_reg(&cur, UNW_REG_IP, &ip);
        unw_get_reg(&cur, UNW_REG_SP, &sp);
        gc_record* rec = gc_lookup((uintptr_t)ip);
        if (!rec) {
            continue;
        }
        for (int s = 0; s < rec->nslots; s++) {
            unw_word_t base = sp;
            if (rec->slots[s].reg == UNW_ARM64_FP) {
                unw_get_reg(&cur, UNW_ARM64_FP, &base);
            }
            void** slot = (void**)((char*)base + rec->slots[s].off);
            visit(slot, *slot, userdata);
        }
    }
}

void nomu_gc_walk_current(nomu_root_visitor visit, void* userdata) {
    unw_context_t ctx;
    unw_getcontext(&ctx);
    nomu_gc_walk_context(&ctx, visit, userdata);
}

// The saved register context for a carrier stopped at a GC safepoint (M6 · 6.2.3). Returns the
// context captured when the carrier with this tls parked at its poll slow path, or NULL if that
// carrier parked idle in the scheduler (holding no Nomu roots).
static unw_context_t* gc_carrier_context(void* carrier_tls) {
    pthread_t t = (pthread_t)carrier_tls;
    for (int i = 0; i < rt_ncarriers_reg; i++) {
        if (rt_carriers[i].in_use && pthread_equal(rt_carriers[i].tls, t) && rt_carriers[i].has_ctx) {
            return &rt_carriers[i].ctx;
        }
    }
    return NULL;
}

// The safepoint slow path (M6 · 6.2.3). The inlined poll (Lowering.swift) calls this when
// __nomu_stop_world is set. This call is a statepoint, so the caller (loop) frame's live roots are
// recorded at its return address; capturing the carrier's context here lets the collector unwind from
// the poll frame to those roots. Then the carrier parks until the world resumes. Not `gc-leaf`.
void __nomu_gc_poll_slow(void) {
    unw_context_t ctx;
    unw_getcontext(&ctx);
    rt_carrier_park_for_stw(&ctx);
}

// Stop every carrier at a safepoint (M6 · 6.2.3) — MMTk's `stop_all_mutators` rests on this, and the
// forced-STW smoke calls it directly. Raise the flag, wake idle carriers blocked in the scheduler so
// they re-check and park, then wait until every registered carrier has parked. Returns with the world
// stopped; the caller scans roots and then calls nomu_gc_resume_the_world.
static int rt_stw_dbg(void) { static int d = -1; if (d < 0) d = getenv("NOMU_GC_DEBUG_STW") != NULL; return d; }
void nomu_gc_stop_the_world(void) {
    if (rt_stw_dbg()) fprintf(stderr, "[stw] stop enter\n");
    __nomu_stop_world = 1;
    pthread_mutex_lock(&rt_queue_mu);
    pthread_cond_broadcast(&rt_queue_cond); // kick idle carriers out of their scheduler wait
    pthread_mutex_unlock(&rt_queue_mu);
    pthread_mutex_lock(&rt_stw_mu);
    static int dbg = -1;
    if (dbg < 0) { dbg = getenv("NOMU_GC_DEBUG_STW") != NULL; }
    int spins = 0;
    for (;;) {
        int all_parked = 1;
        for (int i = 0; i < rt_ncarriers_reg; i++) {
            if (rt_carriers[i].in_use && !rt_carriers[i].parked && !pthread_equal(rt_carriers[i].tls, pthread_self())) {
                all_parked = 0;
            }
        }
        if (all_parked) {
            break;
        }
        if (dbg) {
            struct timespec dl; clock_gettime(CLOCK_REALTIME, &dl); dl.tv_sec += 1;
            int rc = pthread_cond_timedwait(&rt_stw_cond, &rt_stw_mu, &dl);
            if (rc != 0 && ++spins) {
                fprintf(stderr, "[stw] waiting (%d carriers, gc_wanted=%d):", rt_ncarriers_reg, rt_gc_wanted);
                for (int i = 0; i < rt_ncarriers_reg; i++) {
                    fprintf(stderr, " c%d{use=%d,parked=%d,self=%d}", i, rt_carriers[i].in_use,
                            rt_carriers[i].parked, (int)pthread_equal(rt_carriers[i].tls, pthread_self()));
                }
                fprintf(stderr, "\n");
            }
        } else {
            pthread_cond_wait(&rt_stw_cond, &rt_stw_mu);
        }
    }
    pthread_mutex_unlock(&rt_stw_mu);
    if (rt_stw_dbg()) fprintf(stderr, "[stw] stop done (all parked)\n");
}

void nomu_gc_resume_the_world(void) {
    if (rt_stw_dbg()) fprintf(stderr, "[stw] resume\n");
    pthread_mutex_lock(&rt_stw_mu);
    __nomu_stop_world = 0;
    rt_gc_wanted = 0;   // release the carrier blocked in nomu_gc_block_for_gc (6.2.4)
    pthread_cond_broadcast(&rt_stw_cond);
    pthread_mutex_unlock(&rt_stw_mu);
}

// The carrier that triggered a collection blocks here until the cycle finishes (M6 · 6.2.4). It is
// deep inside `nomu_gc_alloc` (Rust), not at a Nomu poll, so it saves its own context and marks itself
// parked — that makes its roots scannable (6.2.1) and lets `nomu_gc_stop_the_world`, raised a moment
// later by the GC worker, count it as already stopped. `rt_gc_wanted` (not `__nomu_stop_world`, which
// isn't set yet) is the wait predicate; `nomu_gc_resume_the_world` clears it.
void nomu_gc_block_for_gc(void) {
    // Only a registered mutator carrier waits for GC. A thread with no carrier CB — the MMTk GC worker
    // — must never block here: under an aggressive `NOMU_GC_STRESS`, the collector's own evacuation
    // (copy) allocations can re-trip the stress trigger and call `block_for_gc` on the worker, which
    // with a single GC thread would wait for a collection only it can finish → deadlock. Returning lets
    // the collector proceed (the nested stress-GC request is simply dropped). Real (heap-pressure) GC
    // never calls this on the worker — copy space is reserved before the cycle. (M6 · 6.3.1.)
    if (!rt_self_cb) {
        return;
    }
    if (rt_stw_dbg()) fprintf(stderr, "[stw] block_for_gc enter\n");
    unw_context_t ctx;
    unw_getcontext(&ctx);
    CarrierCB* cb = rt_self_cb;
    pthread_mutex_lock(&rt_stw_mu);
    rt_gc_wanted = 1;
    if (cb) {
        cb->ctx = ctx;
        cb->has_ctx = 1;
        cb->parked = 1;
        pthread_cond_broadcast(&rt_stw_cond); // tell a waiting stop_the_world we are parked
    }
    while (rt_gc_wanted) {
        pthread_cond_wait(&rt_stw_cond, &rt_stw_mu);
    }
    if (cb) {
        cb->parked = 0;
        cb->has_ctx = 0;
    }
    pthread_mutex_unlock(&rt_stw_mu);
    if (rt_stw_dbg()) fprintf(stderr, "[stw] block_for_gc exit\n");
}

void nomu_gc_walk_carrier(void* carrier_tls, nomu_root_visitor visit, void* userdata) {
    unw_context_t* ctx = gc_carrier_context(carrier_tls);
    if (ctx) {
        nomu_gc_walk_context(ctx, visit, userdata);
    }
}

#if defined(__APPLE__) && defined(__aarch64__)
// Fabricate a libunwind context from a fiber's saved ucontext so its parked stack walks the same way
// as a live one (M6 · 6.2.2, Q8). On arm64 libunwind's register file (unw_context_t) begins with the
// GPRs x0–x28, then fp, lr, sp, pc — the same order as the saved arm_thread_state64 — so they copy
// across 1:1. The accessor macros strip pointer authentication (arm64e). The saved pc sits inside the
// gc-leaf park/swapcontext frame; the unwinder steps out through it to the Nomu frames above.
static void nomu_gc_ucontext_to_unwctx(const ucontext_t* uc, unw_context_t* out) {
    memset(out, 0, sizeof(*out));
    const _STRUCT_ARM_THREAD_STATE64* ss = &uc->uc_mcontext->__ss;
    uint64_t* d = (uint64_t*)out;
    for (int i = 0; i < 29; i++) {
        d[i] = ss->__x[i];
    }
    uint64_t lr = __darwin_arm_thread_state64_get_lr(*ss);
    uint64_t pc = __darwin_arm_thread_state64_get_pc(*ss);
    d[29] = __darwin_arm_thread_state64_get_fp(*ss);
    d[30] = lr;
    d[31] = __darwin_arm_thread_state64_get_sp(*ss);
    // Darwin's getcontext/swapcontext saves no PC — a parked fiber resumes via LR (the return address
    // just after its `swapcontext`, inside the gc-leaf park frame). Seed the unwind there so the walk
    // steps out through the park frame to the Nomu frames above.
    d[32] = pc ? pc : lr;
}
#endif

// Walk one parked fiber's stack for GC roots, seeding the walk from its saved context (M6 · 6.2.2).
void nomu_gc_walk_fiber(Fiber* f, nomu_root_visitor visit, void* userdata) {
#if defined(__APPLE__) && defined(__aarch64__)
    unw_context_t ctx;
    nomu_gc_ucontext_to_unwctx(&f->ctx, &ctx);
    nomu_gc_walk_context(&ctx, visit, userdata);
#else
    (void)f;
    (void)visit;
    (void)userdata;
#endif
}

// Scan every parked fiber's stack — the VM-specific roots the MMTk binding reports at STW (M6 ·
// 6.2.2). Only FIBER_PARKED has a valid saved context that can hold roots: a woken fiber stays
// PARKED until the scheduler makes it RUNNING, while FIBER_RUNNABLE is the freshly-spawned, never-run
// state (its context is a bare `makecontext` entry with no Nomu frames / no roots). FIBER_RUNNING is
// scanned through its carrier (6.2.1); FIBER_DONE holds nothing. Taking rt_queue_mu is safe here: a
// carrier stopped at a safepoint is never inside a scheduler critical section, so it holds no
// scheduler lock (the STW quiesce, 6.2.3, guarantees this).
void nomu_gc_scan_parked_fibers(nomu_root_visitor visit, void* userdata) {
    pthread_mutex_lock(&rt_queue_mu);
    for (Fiber* f = rt_fiber_list; f; f = f->rt_next) {
        if (f->status == FIBER_PARKED) {
            nomu_gc_walk_fiber(f, visit, userdata);
        }
    }
    // M6 · 6.4 — the scheduled-mailbox queue head is a GC root: reporting it keeps the whole
    // `sched_next` chain (each queued mailbox + its pending messages + receiver actor) live, so
    // fire-and-forget outstanding work isn't collected while an actor is otherwise unreferenced. The
    // chain past the head is reached through the mailbox pointer map (sched_next is a scanned field).
    if (rt_sched_head) {
        visit((void**)&rt_sched_head, rt_sched_head, userdata);
    }
    pthread_mutex_unlock(&rt_queue_mu);
}

// GC-root-walk smoke (M8.4.3, env-gated). At a `sleep` safepoint the caller's live class objects
// are recorded; the walk recovers them. The smoke fixture uses `class { var v: Int }`, whose object
// layout is `{ i64 header, i64 v }`, so dereferencing a recovered root at offset 8 yields the known
// field value — proving the root is the actual live object, not garbage. Reports to stderr, so a
// normal run's stdout (the corpus oracle) is unaffected whether or not the walk fires.
static void gc_smoke_visitor(void** slot, void* value, void* userdata) {
    int* count = (int*)userdata;
    long long v = value ? *(long long*)((char*)value + 8) : -1;
    fprintf(stderr, "nomu-gc-smoke: root %d ptr=%p v=%lld\n", ++(*count), value, v);
    (void)slot;
}

static void nomu_gc_smoke(void) {
    int count = 0;
    fprintf(stderr, "nomu-gc-smoke: walk begin\n");
    nomu_gc_walk_current(gc_smoke_visitor, &count);
    fprintf(stderr, "nomu-gc-smoke: %d roots\n", count);
}

// M6 · 6.2.2 parked-fiber smoke (env-gated). The highest-risk validation (Q8): recover a *parked*
// fiber's exact live set from its saved ucontext — not the current stack. Called from `main`'s sleep
// safepoint; spin-waits until a peer fiber has actually parked (bounded — the fixture's worker parks
// in microseconds), then scans the whole registry. The worker holds two class roots live across its
// own `park()` and a dead object that must be excluded.
static void nomu_gc_smoke_parked(void) {
    for (int spins = 0; spins < 100000; spins++) {
        int peer_parked = 0;
        pthread_mutex_lock(&rt_queue_mu);
        for (Fiber* f = rt_fiber_list; f; f = f->rt_next) {
            if (f != rt_current && f->status == FIBER_PARKED) {
                peer_parked = 1;
                break;
            }
        }
        pthread_mutex_unlock(&rt_queue_mu);
        if (peer_parked) {
            break;
        }
        usleep(50);
    }
    int count = 0;
    fprintf(stderr, "nomu-gc-smoke-parked: walk begin\n");
    nomu_gc_scan_parked_fibers(gc_smoke_visitor, &count);
    fprintf(stderr, "nomu-gc-smoke-parked: %d roots\n", count);
}

// M6 · 6.2.3 stop-the-world smoke (env-gated). Exercises the full handshake with no real collection:
// after a short delay (fibers get going — a compute fiber looping at its back-edge poll, a parked
// fiber), stop the world, scan every root the collector would (running carriers via their saved
// safepoint context, 6.2.1; parked fibers via the registry, 6.2.2), then resume. Proves the poll
// flag + poll slow path quiesce all carriers, the saved context reaches a running fiber's roots, and
// resume releases cleanly (the program runs to completion). Runs on a dedicated thread, not a carrier.
static void* rt_stw_smoke_thread(void* _) {
    (void)_;
    usleep(40000); // let the compute fiber start looping and the parked fiber park
    fprintf(stderr, "nomu-gc-stw: stopping the world\n");
    nomu_gc_stop_the_world();
    int count = 0;
    for (int i = 0; i < rt_ncarriers_reg; i++) {
        if (rt_carriers[i].in_use && rt_carriers[i].has_ctx) {
            nomu_gc_walk_context(&rt_carriers[i].ctx, gc_smoke_visitor, &count);
        }
    }
    int carrier_roots = count;
    nomu_gc_scan_parked_fibers(gc_smoke_visitor, &count);
    fprintf(stderr, "nomu-gc-stw: %d carrier roots, %d parked roots\n", carrier_roots, count - carrier_roots);
    nomu_gc_resume_the_world();
    fprintf(stderr, "nomu-gc-stw: resumed\n");
    return NULL;
}

// ---- Process entry ----
extern void nomu_main(void);

static void* __rt_main_entry(void* _) {
    nomu_main();
    return NULL;
}

int main(void) {
    nomu_gc_init(1ULL << 30); // M6 · 6.1.1 — init MMTk (NoGC, 1 GiB reserved) before any allocation
    if (getenv("NOMU_GC_TYPEMAPS")) {
        nomu_gc_dump_typemaps(); // 6.1.3 map-walk self-check
    }
#ifdef __APPLE__
    rt_kq = kqueue();
    pthread_t __poller_t;
    pthread_create(&__poller_t, NULL, rt_poller_thread, NULL);
    pthread_detach(__poller_t);
#endif
    pthread_t __timer_t;
    pthread_create(&__timer_t, NULL, rt_timer_thread, NULL);
    pthread_detach(__timer_t);
    int ncarriers = 4;                                  // parallelism knob — will be configurable later
    rt_main_fiber = fiber_spawn(__rt_main_entry, NULL); // 6.2.2 — remember `main` for the parked smoke
    for (int i = 1; i < ncarriers; i++) {
        pthread_t t;
        pthread_create(&t, NULL, rt_carrier_entry, NULL);
        pthread_detach(t);
    }
    if (getenv("NOMU_GC_STW_SMOKE")) { // 6.2.3 — forced stop-the-world handshake validation
        pthread_t __stw_t;
        pthread_create(&__stw_t, NULL, rt_stw_smoke_thread, NULL);
        pthread_detach(__stw_t);
    }
    rt_scheduler_run();
    if (getenv("NOMU_GC_STATS") || getenv("NOMU_GC_STATS_LIVE")) {   // M6 · 6.3.2 — footprint report
        nomu_gc_report_stats();
    }
    return 0;
}

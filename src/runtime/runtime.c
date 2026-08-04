// Nomu privileged runtime (M4.13) — the trusted core: allocator, M:N fiber
// scheduler, timer heap, I/O poller, and the process entry point. Carved verbatim
// from the former embedded preamble; the scheduler/timer/poller internals stay
// `static`, while the symbols generated code calls have external linkage via
// nomu_runtime.h. (Design: m4.13-spec.md §1, level 1.)
#define _XOPEN_SOURCE 600
#define _DARWIN_C_SOURCE
#include "runtime.h"
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <ucontext.h>
#include <stdint.h>
#define UNW_LOCAL_ONLY
#include <libunwind.h>
#ifdef __APPLE__
#include <sys/event.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>   // _mh_execute_header (M8.4.3: locate __llvm_stackmaps)
#endif

// ---- Allocation seam ----
void* rt_alloc(size_t size) {
    void* p = calloc(1, size);
    if (!p) { fputs("out of memory\n", stderr); exit(1); }
    ((ObjectHeader*)p)->refcount = 1;
    return p;
}

void rt_free(void* p) { free(p); }

// ---- Fiber scheduler (M4.5: multi-carrier, idle sleep, fiber-aware timer) ----
#define RT_MAX_FIBERS 256
#define RT_MAX_CARRIERS 16
#define RT_STACK_SIZE (128 * 1024)

typedef enum { FIBER_RUNNABLE, FIBER_PARKED, FIBER_DONE } FiberStatus;
struct Fiber {
    ucontext_t ctx;
    char* stack;
    FiberStatus status;
    void* result;
    struct Fiber* joiner;
    void* (*fn)(void*);
    void* arg;
};

static Fiber* rt_run_queue[RT_MAX_FIBERS];
static int rt_rq_head = 0, rt_rq_tail = 0;
static int rt_active = 0;
static pthread_mutex_t rt_queue_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t rt_queue_cond = PTHREAD_COND_INITIALIZER;
static _Thread_local Fiber* rt_current = NULL;
static _Thread_local ucontext_t rt_sched_ctx;

// Must be called with rt_queue_mu held. Signals a sleeping carrier.
static void rt_rq_push(Fiber* f) {
    rt_run_queue[rt_rq_tail % RT_MAX_FIBERS] = f;
    rt_rq_tail++;
    pthread_cond_signal(&rt_queue_cond);
}
// Must be called with rt_queue_mu held.
static Fiber* rt_rq_pop(void) {
    if (rt_rq_head == rt_rq_tail) return NULL;
    Fiber* f = rt_run_queue[rt_rq_head % RT_MAX_FIBERS];
    rt_rq_head++;
    return f;
}

static void rt_fiber_trampoline(void) {
    Fiber* self = rt_current;
    self->result = self->fn(self->arg);
    pthread_mutex_lock(&rt_queue_mu);
    self->status = FIBER_DONE;
    rt_active--;
    if (self->joiner) { rt_rq_push(self->joiner); self->joiner = NULL; }
    pthread_cond_broadcast(&rt_queue_cond); // wake all carriers to re-check rt_active == 0
    pthread_mutex_unlock(&rt_queue_mu);
    swapcontext(&self->ctx, &rt_sched_ctx);
}

Fiber* fiber_spawn(void* (*fn)(void*), void* arg) {
    Fiber* f = (Fiber*)calloc(1, sizeof(Fiber));
    f->stack = (char*)malloc(RT_STACK_SIZE);
    f->fn = fn; f->arg = arg; f->status = FIBER_RUNNABLE;
    getcontext(&f->ctx);
    f->ctx.uc_stack.ss_sp = f->stack;
    f->ctx.uc_stack.ss_size = RT_STACK_SIZE;
    f->ctx.uc_link = NULL;
    makecontext(&f->ctx, rt_fiber_trampoline, 0);
    pthread_mutex_lock(&rt_queue_mu);
    rt_active++;
    rt_rq_push(f);
    pthread_mutex_unlock(&rt_queue_mu);
    return f;
}

static void rt_scheduler_run(void) {
    pthread_mutex_lock(&rt_queue_mu);
    while (1) {
        Fiber* f = rt_rq_pop();
        if (f) {
            pthread_mutex_unlock(&rt_queue_mu);
            rt_current = f;
            swapcontext(&rt_sched_ctx, &f->ctx);
            pthread_mutex_lock(&rt_queue_mu);
        } else if (rt_active == 0) {
            break;
        } else {
            pthread_cond_wait(&rt_queue_cond, &rt_queue_mu);
        }
    }
    pthread_mutex_unlock(&rt_queue_mu);
}

static void* rt_carrier_entry(void* _) { rt_scheduler_run(); return NULL; }

void* spawn_join(SpawnHandle* h) {
    pthread_mutex_lock(&rt_queue_mu);
    if (h->fiber->status != FIBER_DONE) {
        h->fiber->joiner = rt_current;
        rt_current->status = FIBER_PARKED;
        pthread_mutex_unlock(&rt_queue_mu);
        swapcontext(&rt_current->ctx, &rt_sched_ctx);
    } else {
        pthread_mutex_unlock(&rt_queue_mu);
    }
    return h->fiber->result;
}

// ---- Actor mutex (opaque, heap-allocated) ----
// A `void*`-fronted `pthread_mutex_t` for the LLVM backend, which can't lay out the platform mutex
// inline. Additive to the ABI; the C backend keeps inlining `pthread_mutex_t` directly.
void* rt_mutex_new(void) {
    pthread_mutex_t* m = (pthread_mutex_t*)malloc(sizeof(pthread_mutex_t));
    pthread_mutex_init(m, NULL);
    return m;
}
void rt_mutex_lock(void* m)   { pthread_mutex_lock((pthread_mutex_t*)m); }
void rt_mutex_unlock(void* m) { pthread_mutex_unlock((pthread_mutex_t*)m); }

// ---- Timer heap (M4.5) ----
#define RT_MAX_TIMERS 256
typedef struct { uint64_t expiry_ns; Fiber* fiber; } TimerEntry;
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
    rt_timers[i] = (TimerEntry){ expiry, f };
    while (i > 0) {
        int p = (i - 1) / 2;
        if (rt_timers[p].expiry_ns <= rt_timers[i].expiry_ns) break;
        TimerEntry tmp = rt_timers[p]; rt_timers[p] = rt_timers[i]; rt_timers[i] = tmp;
        i = p;
    }
    pthread_cond_signal(&rt_timer_cond);
}
static void rt_timer_pop(void) {
    rt_timers[0] = rt_timers[--rt_timer_count];
    int i = 0;
    while (1) {
        int l = 2*i+1, r = 2*i+2, s = i;
        if (l < rt_timer_count && rt_timers[l].expiry_ns < rt_timers[s].expiry_ns) s = l;
        if (r < rt_timer_count && rt_timers[r].expiry_ns < rt_timers[s].expiry_ns) s = r;
        if (s == i) break;
        TimerEntry tmp = rt_timers[s]; rt_timers[s] = rt_timers[i]; rt_timers[i] = tmp;
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
            struct timespec ts = { (time_t)(next / 1000000000ULL), (long)(next % 1000000000ULL) };
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

static void nomu_gc_smoke(void);   // M8.4.3 — defined below (GC root-walk smoke)

int64_t rt_sleep_ms(int64_t ms) {
    // M8.4.3 smoke (env-gated, inert otherwise): `sleep` is a safepoint (this call is a statepoint),
    // so at entry the caller's live GC roots are recorded. Walk them before parking the fiber.
    if (getenv("NOMU_GC_SMOKE")) nomu_gc_smoke();
    uint64_t expiry = rt_now_ns() + (uint64_t)ms * 1000000ULL;
    pthread_mutex_lock(&rt_timer_mu);
    rt_timer_push(expiry, rt_current);
    pthread_mutex_unlock(&rt_timer_mu);
    rt_current->status = FIBER_PARKED;
    swapcontext(&rt_current->ctx, &rt_sched_ctx);
    return ms;
}

// ---- I/O poller (M4.4: kqueue, fiber-aware fd readiness) ----
#ifdef __APPLE__
static int rt_kq = -1;

static void rt_wait_readable(int fd) {
    struct kevent ev;
    EV_SET(&ev, fd, EVFILT_READ, EV_ADD | EV_ONESHOT, 0, 0, rt_current);
    kevent(rt_kq, &ev, 1, NULL, 0, NULL);
    rt_current->status = FIBER_PARKED;
    swapcontext(&rt_current->ctx, &rt_sched_ctx);
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
    if (n <= 0) return rt_str_lit("", 0);
    if (buf[n - 1] == '\n') n--;
    char* data = (char*)rt_alloc(sizeof(ObjectHeader) + (size_t)n + 1) + sizeof(ObjectHeader);
    memcpy(data, buf, (size_t)n);
    data[n] = '\0';
    return (String){ .data = data, .len = (int64_t)n };
}
#else
// Non-macOS: readLine is not wired yet (epoll path unwritten, runtime.md §... poller).
String rt_read_line(int fd) { (void)fd; return rt_str_lit("", 0); }
#endif

// ---- GC root scanning (M8.4.3; m8.4-spec.md D4) ----
// Parse the `__llvm_stackmaps` section (stackmap v3) into a return-address → live-GC-slot index,
// then walk a stack (libunwind) mapping each frame's return address to its record and reading the
// live roots. Inert now — nothing calls this except the smoke path (M6 drives it from the
// collector). The layout follows llvm/Object/StackMapParser.h.
typedef struct { int reg; int32_t off; } gc_slot;   // Indirect [dwarf reg + off]; reg 31=SP, 29=FP
typedef struct { uintptr_t addr; int nslots; gc_slot* slots; } gc_record;   // one statepoint
static gc_record* gc_records = NULL;
static int gc_nrecords = 0;
static int gc_inited = 0;

static uint16_t gc_rd16(const uint8_t* p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t gc_rd32(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t gc_rd64(const uint8_t* p) { return (uint64_t)gc_rd32(p) | ((uint64_t)gc_rd32(p + 4) << 32); }

void nomu_gc_stackmap_init(void) {
    if (gc_inited) return;
    gc_inited = 1;
#ifdef __APPLE__
    unsigned long size = 0;
    const uint8_t* sm = getsectiondata(&_mh_execute_header, "__LLVM_STACKMAPS", "__llvm_stackmaps", &size);
    if (!sm || size < 16 || sm[0] != 3) return;   // no section, or unsupported version
    uint32_t nfuncs = gc_rd32(sm + 4), nconsts = gc_rd32(sm + 8), nrecs = gc_rd32(sm + 12);
    const uint8_t* funcs = sm + 16;
    const uint8_t* recs = funcs + (size_t)nfuncs * 24 + (size_t)nconsts * 8;   // records follow funcs+consts
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
                if (kind != 3 /*Indirect*/ && kind != 1 /*Register*/) continue;
                int reg = gc_rd16(L + 4);
                int32_t off = (int32_t)gc_rd32(L + 8);
                int dup = 0;
                for (int s = 0; s < gr->nslots; s++)
                    if (gr->slots[s].reg == reg && gr->slots[s].off == off) { dup = 1; break; }
                if (!dup) { gr->slots[gr->nslots].reg = reg; gr->slots[gr->nslots].off = off; gr->nslots++; }
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
    for (int i = 0; i < gc_nrecords; i++) if (gc_records[i].addr == ip) return &gc_records[i];
    return NULL;
}

void nomu_gc_walk_current(nomu_root_visitor visit, void* userdata) {
    nomu_gc_stackmap_init();
    unw_context_t ctx;
    unw_cursor_t cur;
    unw_getcontext(&ctx);
    unw_init_local(&cur, &ctx);
    // Step past this walker's own frame into its callers; for each frame whose return address has a
    // stackmap record, read the live roots at (frame register + offset).
    while (unw_step(&cur) > 0) {
        unw_word_t ip = 0, sp = 0;
        unw_get_reg(&cur, UNW_REG_IP, &ip);
        unw_get_reg(&cur, UNW_REG_SP, &sp);
        gc_record* rec = gc_lookup((uintptr_t)ip);
        if (!rec) continue;
        for (int s = 0; s < rec->nslots; s++) {
            unw_word_t base = sp;
            if (rec->slots[s].reg == UNW_ARM64_FP) unw_get_reg(&cur, UNW_ARM64_FP, &base);
            void** slot = (void**)((char*)base + rec->slots[s].off);
            visit(slot, *slot, userdata);
        }
    }
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

// ---- Process entry ----
extern void nomu_main(void);
static void* __rt_main_entry(void* _) { nomu_main(); return NULL; }
int main(void) {
    #ifdef __APPLE__
    rt_kq = kqueue();
    pthread_t __poller_t; pthread_create(&__poller_t, NULL, rt_poller_thread, NULL); pthread_detach(__poller_t);
    #endif
    pthread_t __timer_t; pthread_create(&__timer_t, NULL, rt_timer_thread, NULL); pthread_detach(__timer_t);
    int ncarriers = 4; // parallelism knob — will be configurable later
    fiber_spawn(__rt_main_entry, NULL);
    for (int i = 1; i < ncarriers; i++) {
        pthread_t t; pthread_create(&t, NULL, rt_carrier_entry, NULL); pthread_detach(t);
    }
    rt_scheduler_run();
    return 0;
}

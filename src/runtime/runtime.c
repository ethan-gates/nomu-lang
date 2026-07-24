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
#ifdef __APPLE__
#include <sys/event.h>
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

int64_t rt_sleep_ms(int64_t ms) {
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

// Nomu privileged runtime — the C floor under the Nomu runtime: the GC driver threads. The scheduler
// and the collector are Nomu code (src/stdlib/runtime/); generated code calls them directly or through
// codegen-emitted forwarders. Symbols generated code calls here have external linkage via runtime.h. (Design: m4.13-spec.md §1, level 1.)
#define _XOPEN_SOURCE 600
#define _DARWIN_C_SOURCE
#include "runtime.h"
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// ---- The Nomu scheduler (src/stdlib/runtime/scheduler.nomu) ----
// Its entry points are Nomu functions, so codegen names them `nomu_fn_<name>`; the GC threads call them.
// The scheduler (`rtSched`) and whether an external stop-the-world driver owns collection
// (`rtGcExternalDriver`): runtime startup globals, set by nomu_runtime_init before anything below runs.
extern void* nomu_g_rtSched;
extern int64_t nomu_g_rtGcExternalDriver;

extern int64_t nomu_fn_nomuSchedWalkParked(void* sched, void* outBuf, int64_t cap);      // task 128.3.2
extern int64_t nomu_fn_nomuSchedStwCollect(void* sched);            // self-hosted evacuating collection at STW
extern int64_t nomu_fn_nomuSchedStwCollectDefrag(void* sched);      // defrag variant (heap-pressure path)
extern int64_t nomu_fn_nomuSchedStwCollectMinor(void* sched);       // minor (generational) collection (150.4.3)
extern int64_t nomu_fn_nomuGcSpaceAvail(void);                      // free blocks in the self-hosted heap
extern int64_t nomu_fn_nomuGcSpaceBlocks(void);                     // total blocks in the self-hosted heap
extern int __ulock_wake(uint32_t operation, void* addr, uint64_t wake_value);            // libSystem futex
extern int __ulock_wait(uint32_t operation, void* addr, uint64_t value, uint32_t timeout_us);   // libSystem futex wait


// ---- Safepoint ----
// The stop-the-world poll flag, read by the inlined back-edge poll (LLVMGenRuntime.swift) and the scheduler.
// A GC driver thread raises it with the scheduler's stw-request; a running fiber that sees it calls
// the codegen-emitted __nomu_gc_poll_slow. The runtime module defines it (`rtStopWorld`, a
// `Runtime.staticStorage` block).
extern volatile int nomu_static_rtStopWorld;

// ---- GC driver threads ----
// Forced self-hosted stop-the-world smoke (task 128.3.2, env NOMU_STW_SELFHOST). Drives a real STW over
// the self-hosted scheduler's carriers and runs the self-hosted root walk (rtWalkFrom over the live-fiber
// registry). This coordinator is a plain thread, not a fiber, so it never polls/parks itself. Sched field offsets mirror runtime/scheduler.nomu.
static int64_t rt_stw_ld(int off)  { return __atomic_load_n((int64_t*)((char*)nomu_g_rtSched + off), __ATOMIC_SEQ_CST); }
static void    rt_stw_st(int off, int64_t v) { __atomic_store_n((int64_t*)((char*)nomu_g_rtSched + off), v, __ATOMIC_SEQ_CST); }

static void* rt_stw_selfhost_thread(void* _) {
    struct timespec warmup = {0, 40 * 1000 * 1000}; nanosleep(&warmup, NULL); // let the program get going
    int rounds = 3;
    for (int r = 0; r < rounds; r++) {
        int64_t ncarriers = rt_stw_ld(160);
        // Request the stop: raise both the poll trigger (read by the inlined safepoint) and the Nomu
        // handshake request, then wake idle carriers so they reach the ack path promptly.
        rt_stw_st(136, 1);          // stw-request
        nomu_static_rtStopWorld = 1;
        __atomic_fetch_add((int64_t*)((char*)nomu_g_rtSched + 24), 1, __ATOMIC_SEQ_CST); // bump wake-gen
        __ulock_wake(0x01000101, (char*)nomu_g_rtSched + 24, 0);                          // wake all idle carriers
        // Wait until every carrier has acked (all mutators stopped at a safepoint / parked).
        while (rt_stw_ld(144) < ncarriers) {
            struct timespec s = {0, 500 * 1000}; nanosleep(&s, NULL);
        }
        // World stopped: run the self-hosted walk over every parked/stopped fiber's anchor.
        void** buf = (void**)malloc(sizeof(void*) * 1024);
        int64_t nr = nomu_fn_nomuSchedWalkParked(nomu_g_rtSched, buf, 1024);
        fprintf(stderr, "nomu-stw-selfhost: round %d nroots %lld\n", r, (long long)nr);
        for (int64_t i = 0; i < nr && i < 1024; i++) {   // nr is the total; the buffer holds the first 1024
            int64_t v = ((int64_t*)buf[i])[1];   // class { i64 header, i64 v } → the Int at offset 8
            fprintf(stderr, "STW-ROOT %lld\n", (long long)v);
        }
        free(buf);
        // Resume the world: reset the ack, clear the request, and wake the parked carriers.
        rt_stw_st(144, 0);
        rt_stw_st(136, 0);
        nomu_static_rtStopWorld = 0;
        __atomic_fetch_add((int64_t*)((char*)nomu_g_rtSched + 152), 1, __ATOMIC_SEQ_CST); // bump stw-gen
        __ulock_wake(0x01000101, (char*)nomu_g_rtSched + 152, 0);                          // wake parked carriers
        struct timespec between = {0, 25 * 1000 * 1000}; nanosleep(&between, NULL);
    }
    return NULL;
}

// Forced self-hosted COLLECTION smoke (env NOMU_STW_COLLECT). Same STW handshake as
// rt_stw_selfhost_thread, but instead of only walking roots it drives a real evacuating Immix collection
// over the self-hosted space (nomuSchedStwCollect): every stopped mutator's root slots are collected, the
// live graph is evacuated, and each slot is fixed up in place before resume. The program's output must be
// unchanged (moving is transparent), which is the fixup-correctness proof.
static void* rt_stw_collect_thread(void* _) {
    struct timespec warmup = {0, 40 * 1000 * 1000}; nanosleep(&warmup, NULL);
    int rounds = 3;
    for (int r = 0; r < rounds; r++) {
        int64_t ncarriers = rt_stw_ld(160);
        rt_stw_st(136, 1);
        nomu_static_rtStopWorld = 1;
        __atomic_fetch_add((int64_t*)((char*)nomu_g_rtSched + 24), 1, __ATOMIC_SEQ_CST);
        __ulock_wake(0x01000101, (char*)nomu_g_rtSched + 24, 0);
        while (rt_stw_ld(144) < ncarriers) {
            struct timespec s = {0, 500 * 1000}; nanosleep(&s, NULL);
        }
        int64_t nr = nomu_fn_nomuSchedStwCollect(nomu_g_rtSched);
        fprintf(stderr, "nomu-stw-collect: round %d fixed %lld roots\n", r, (long long)nr);
        rt_stw_st(144, 0);
        rt_stw_st(136, 0);
        nomu_static_rtStopWorld = 0;
        __atomic_fetch_add((int64_t*)((char*)nomu_g_rtSched + 152), 1, __ATOMIC_SEQ_CST);
        __ulock_wake(0x01000101, (char*)nomu_g_rtSched + 152, 0);
        struct timespec between = {0, 25 * 1000 * 1000}; nanosleep(&between, NULL);
    }
    return NULL;
}

// Heap-pressure-triggered self-hosted collection (env NOMU_GC_PRESSURE). A persistent GC thread polls the
// self-hosted Immix space's free-block count; when it drops below the reserve it drives a defrag collection
// at the STW (the same handshake), reclaiming garbage so an over-allocating program survives instead of
// exhausting the heap. The mutator stops at its next back-edge safepoint poll (a clean user statepoint), so
// its roots are walkable — collection happens between allocations, not mid-allocation. Reserve defaults to 1/8 of the heap; NOMU_GC_TRIGGER_RESERVE
// overrides it (in blocks) so a test can trigger earlier.
static void* rt_gc_pressure_thread(void* _) {
    while (nomu_fn_nomuGcSpaceBlocks() == 0) {           // wait for the space + program to come up
        if (rt_stw_ld(40) != 0) return NULL;
        struct timespec s = {0, 1 * 1000 * 1000}; nanosleep(&s, NULL);
    }
    int64_t nb = nomu_fn_nomuGcSpaceBlocks();
    int64_t reserve = nb / 8;
    const char* env = getenv("NOMU_GC_TRIGGER_RESERVE");
    if (env) { long v = atol(env); if (v > 0) reserve = v; }
    for (;;) {
        if (rt_stw_ld(40) != 0) break;                  // scheduler quiescent → program done
        int64_t avail = nomu_fn_nomuGcSpaceAvail();
        if (avail < 0) break;
        if (avail >= reserve) {
            struct timespec s = {0, 300 * 1000}; nanosleep(&s, NULL);
            continue;
        }
        int64_t ncarriers = rt_stw_ld(160);
        rt_stw_st(136, 1);
        nomu_static_rtStopWorld = 1;
        __atomic_fetch_add((int64_t*)((char*)nomu_g_rtSched + 24), 1, __ATOMIC_SEQ_CST);
        __ulock_wake(0x01000101, (char*)nomu_g_rtSched + 24, 0);
        while (rt_stw_ld(144) < ncarriers) {
            if (rt_stw_ld(40) != 0) break;              // program finished mid-wait — stop waiting
            struct timespec s = {0, 200 * 1000}; nanosleep(&s, NULL);
        }
        nomu_fn_nomuSchedStwCollectDefrag(nomu_g_rtSched);
        rt_stw_st(144, 0);
        rt_stw_st(136, 0);
        nomu_static_rtStopWorld = 0;
        __atomic_fetch_add((int64_t*)((char*)nomu_g_rtSched + 152), 1, __ATOMIC_SEQ_CST);
        __ulock_wake(0x01000101, (char*)nomu_g_rtSched + 152, 0);
    }
    return NULL;
}

// Synchronous block-on-OOM GC coordinator (task 150.3.11) — the default self-hosted GC trigger. Unlike
// rt_gc_pressure_thread (which polls a headroom reserve), this blocks until an allocating mutator hits true
// OOM (rtImmixRefill finds no block). The OOM'ing carrier initiates the STW itself — it sets stw-request (+136)
// under the scheduler lock, parks at its alloc-site anchor, and signals this coordinator via gc-request (+168).
// This thread then runs the same handshake as the pressure poller: set stop_world, wake carriers to park + ack,
// wait for all acks, run the defrag collection, and resume the world. The parked carriers (including the OOM
// initiator's) resume off the stw-gen bump (+152), exactly as in the poll-site path. A plain pthread (the STW
// coordinator must not be a fiber).
static void* rt_gc_sync_thread(void* _) {
    while (nomu_fn_nomuGcSpaceBlocks() == 0) {           // wait for the space + program to come up
        if (rt_stw_ld(40) != 0) return NULL;
        struct timespec s = {0, 1 * 1000 * 1000}; nanosleep(&s, NULL);
    }
    for (;;) {
        // Block until a mutator requests a collection (gc-request @168) or the program ends.
        while (rt_stw_ld(168) == 0) {
            if (rt_stw_ld(40) != 0) return NULL;
            __ulock_wait(0x01000101, (char*)nomu_g_rtSched + 168, 0, 1000);   // ~1ms backstop, re-checks the flag
        }
        rt_stw_st(168, 0);                               // consume the request (136 already set by the initiator)
        int64_t kind = rt_stw_ld(176);                   // collection kind: 1 = minor (nursery full), 0 = major/defrag (OOM)
        int64_t ncarriers = rt_stw_ld(160);
        nomu_static_rtStopWorld = 1;
        __atomic_fetch_add((int64_t*)((char*)nomu_g_rtSched + 24), 1, __ATOMIC_SEQ_CST);
        __ulock_wake(0x01000101, (char*)nomu_g_rtSched + 24, 0);              // wake carriers to poll + ack
        while (rt_stw_ld(144) < ncarriers) {
            if (rt_stw_ld(40) != 0) break;               // program finished mid-wait
            struct timespec s = {0, 200 * 1000}; nanosleep(&s, NULL);
        }
        if (kind == 1) {
            // Minor (generational) collection (150.4.3): promote the nursery, using the drained remembered set.
            nomu_fn_nomuSchedStwCollectMinor(nomu_g_rtSched);
        } else {
            nomu_fn_nomuSchedStwCollectDefrag(nomu_g_rtSched);
        }
        rt_stw_st(176, 0);                               // reset the kind for the next request
        rt_stw_st(144, 0);
        rt_stw_st(136, 0);
        nomu_static_rtStopWorld = 0;
        __atomic_fetch_add((int64_t*)((char*)nomu_g_rtSched + 152), 1, __ATOMIC_SEQ_CST);
        __ulock_wake(0x01000101, (char*)nomu_g_rtSched + 152, 0);             // resume parked carriers (incl. initiator)
    }
}

// Start the collector's coordinator threads. The process entry `main` (emitted by codegen) calls this after
// the runtime's init function and before it boots the scheduler.
void rt_gc_threads_start(void) {
    if (getenv("NOMU_STW_SELFHOST")) {   // 128.3.2 forced-STW smoke: coordinate a real STW + self-hosted walk
        pthread_t __stw_sh; pthread_create(&__stw_sh, NULL, rt_stw_selfhost_thread, NULL); pthread_detach(__stw_sh);
    }
    if (getenv("NOMU_STW_COLLECT")) {    // forced-collect smoke: real evacuating Immix collection at the STW
        pthread_t __stw_c; pthread_create(&__stw_c, NULL, rt_stw_collect_thread, NULL); pthread_detach(__stw_c);
    }
    if (getenv("NOMU_GC_PRESSURE")) {    // heap-pressure-triggered collection: a GC thread collects when the heap fills
        pthread_t __gc_p; pthread_create(&__gc_p, NULL, rt_gc_pressure_thread, NULL); pthread_detach(__gc_p);
    }
    // The default GC trigger (150.3.11): a synchronous block-on-OOM coordinator, started whenever no explicit
    // GC-driver knob is set (the smoke/pressure threads above drive collection their own way). It stays idle
    // until a mutator requests a collection — a minor GC when the nursery reserve fills (150.4.3), a stress
    // collection (NOMU_GC_STRESS), or a major/defrag at true OOM (150.3.11).
    if (!nomu_g_rtGcExternalDriver) {
        pthread_t __gc_s; pthread_create(&__gc_s, NULL, rt_gc_sync_thread, NULL); pthread_detach(__gc_s);
    }
}

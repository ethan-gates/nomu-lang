// Nomu privileged runtime — the C floor under the Nomu runtime: the process entry point, the GC driver
// threads, the per-carrier TLAB and mod-buffer registries, the GC descriptor accessors, raw memory, and stdin
// line input with its kqueue poller thread. The
// scheduler and the collector are Nomu code (src/stdlib/runtime.nomu); the entry points generated code calls
// here (fiber_spawn, spawn_join, rt_sleep_ms, the actor mailbox) forward to them. Symbols generated code calls
// have external linkage via runtime.h. (Design: m4.13-spec.md §1, level 1.)
#define _XOPEN_SOURCE 600
#define _DARWIN_C_SOURCE
#include "runtime.h"
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <poll.h>
#ifdef __APPLE__
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h> // _mh_execute_header (M8.4.3: locate __llvm_stackmaps)
#include <sys/event.h>
#endif

// ---- Write-barrier fast-path globals ----
// The codegen-inlined object-remembering barrier (`__nomu_write_barrier`) reads these. They stay 0 — barrier
// off — until the first self-hosted allocation creates the Immix space, which points them at the space's
// log-bit side table: base (folded so `(objInt >> log_region) >> 3` indexes the table), region shift, and the
// heap range the table covers (a store into an object outside it skips the barrier).
unsigned char __nomu_barrier_active = 0;
int64_t __nomu_logbit_base = 0;
unsigned char __nomu_logbit_log_region = 0;
int64_t __nomu_logbit_heap_lo = 0;
int64_t __nomu_logbit_heap_hi = 0;

// Nursery reserve override in blocks (env NOMU_NURSERY_RESERVE), a dev/test override of the default-on
// generational trigger. 0 = unset → use the descriptor's default reserve (1/4 of the pool); a positive value
// overrides the reserve (a small value forces frequent minor GCs so a test exercises the generational collector
// deterministically); a negative value disables generational entirely (major-only, the pre-generational path).
// Set once from the env in main() before any allocation; rtGenReserve resolves it against the descriptor.
// Non-static so the codegen intrinsic can load it.
int64_t __nomu_nursery_reserve = 0;

// Mature-pressure floor in blocks (task 150.4.4, env NOMU_MATURE_FLOOR). 0 = default (the minor/major driver
// falls back to the worst-case-promotion bound). When free mature blocks fall below it, a nursery-full trigger
// escalates to a full defrag major instead of a minor (rtImmixRefill reads it via RawPtr.gcMatureFloor). A
// large value forces majors to interleave with minors so a test exercises the escalation path deterministically.
// Non-static so the codegen intrinsic can load it.
int64_t __nomu_mature_floor = 0;

// Allocation stress in bytes (env NOMU_GC_STRESS). 0 = off. When positive, every self-hosted allocation takes
// the slow path (the TLAB's inline limit stays 0) and each carrier requests a collection after every
// `__nomu_gc_stress` bytes it allocates, so every allocation site is a collection point. Read via
// RawPtr.gcStress. Non-static so the codegen intrinsic can load it.
int64_t __nomu_gc_stress = 0;

// Set when an external STW driver (NOMU_STW_SELFHOST / NOMU_STW_COLLECT / NOMU_GC_PRESSURE) owns collection,
// so the default minor/OOM coordinator (rt_gc_sync_thread) is not started. The generational minor trigger
// parks a carrier and waits for that coordinator to service its request; with no coordinator running it would
// deadlock, so rtGenReserve returns 0 (generational off) when this is set — the external driver is the whole
// collection mechanism. Read via RawPtr.gcExternalDriver.
int64_t __nomu_gc_ext_driver = 0;

// ---- The Nomu scheduler (src/stdlib/runtime.nomu) ----
// Its entry points are Nomu functions, so codegen names them `nomu_fn_<name>`; fiber_spawn / spawn_join /
// rt_sleep_ms / the actor mailbox / main forward to them.
void* rt_nomu_sched = NULL;               // the opaque Nomu Sched handle (nomuSchedNew), bound at boot;
                                          // non-static so codegen's `RawPtr.schedHandle()` (__schedHandle) can load it
extern void* nomu_fn_nomuSchedNew(void);
extern void* nomu_fn_nomuSchedSpawn(void* sched, void* entry, void* arg);
extern void* nomu_fn_nomuSchedJoin(void* sched, void* target, void* anchorSp, void* anchorPc, int64_t final);
extern void  nomu_fn_nomuSchedBoot(void* sched, void* entryFn, int64_t ncarriers, void* drainFn);
extern int64_t nomu_fn_nomuSchedSleep(void* sched, int64_t ms, void* anchorSp, void* anchorPc);

// The user-frame anchor for the self-hosted STW walk (task 128.3.2). A C dispatch shim is the immediate
// callee of the user code that parks (sleep/join) or polls, so __builtin_return_address(0) is the user
// function's return address — a statepoint the pcsp walk (rtWalkFrom) matches — and the caller's SP is
// __builtin_frame_address(0)+16 on arm64 (past this shim's saved {fp,lr}), the same caller-frame math
// rtCollectRoots uses. A direct immediate-caller read; no libunwind/CFI.
#define RT_USER_ANCHOR(sp_var, pc_var) \
    void* pc_var = __builtin_return_address(0); \
    void* sp_var = (void*)((char*)__builtin_frame_address(0) + 16)
extern void  nomu_fn_nomuSchedActorSend(void* sched, void* mailbox, void* msg);
extern void* nomu_fn_nomuSchedMailboxPop(void* sched, void* mailbox);
extern void  nomu_fn_nomuSchedSafepoint(void* sched, void* anchorSp, void* anchorPc);   // task 128.3.2
extern int64_t nomu_fn_nomuSchedWalkParked(void* sched, void* outBuf, int64_t cap);      // task 128.3.2
extern int64_t nomu_fn_nomuSchedStwCollect(void* sched);            // self-hosted evacuating collection at STW
extern int64_t nomu_fn_nomuSchedStwCollectDefrag(void* sched);      // defrag variant (heap-pressure path)
extern int64_t nomu_fn_nomuSchedStwCollectMinor(void* sched);       // minor (generational) collection (150.4.3)
extern int64_t nomu_fn_nomuGcSpaceAvail(void);                      // free blocks in the self-hosted heap
extern int64_t nomu_fn_nomuGcSpaceBlocks(void);                     // total blocks in the self-hosted heap
extern int __ulock_wake(uint32_t operation, void* addr, uint64_t wake_value);            // libSystem futex
extern int __ulock_wait(uint32_t operation, void* addr, uint64_t value, uint32_t timeout_us);   // libSystem futex wait

// The self-hosted Immix space descriptor (task 174.3.1): a single process resource all carriers (and every
// compiled object, including a separately-compiled package that allocates) share. The codegen-generated
// self-hosted allocation function references this by name; it was formerly an internal per-object global,
// which stood up a separate heap whenever a non-entry object allocated. Defined here in the C floor so there
// is one definition process-wide. Null until the first self-hosted allocation creates the space under the
// space lock and release-stores the descriptor here (the acquire/release pairing lives in the generated
// function's double-checked lock).
void* __nomu_selfhost_space = NULL;

// ---- Self-hosted allocator TLABs (task 150 · 150.3.10.1) ----
// Each carrier owns a 48-byte TLAB { allocCursor@0, allocLimit@8, allocBlock@16, allocLine@24, stressLimit@32,
// stressBytes@40 } the codegen self-hosted-alloc seam bumps within (rtTlabAlloc). Under NOMU_GC_STRESS the hole
// end lives in stressLimit and allocLimit stays 0, so the inline bump always misses; stressBytes counts the
// bytes allocated since this carrier's last stress collection; on overflow it refills from the shared Immix pool under
// the space lock. Bound lazily on the carrier's first self-hosted allocation.
// Registered in a table so the collector can reset every carrier's TLAB at end-of-collection (evacuation may
// relocate a carrier's current block; the reset drops the stale hole so the next alloc refills).
_Thread_local void* rt_self_tlab = NULL;
#define RT_TLAB_MAX 256
static void* rt_tlab_table[RT_TLAB_MAX];
static int rt_tlab_count = 0;
static pthread_mutex_t rt_tlab_lock = PTHREAD_MUTEX_INITIALIZER;

// Return this carrier's TLAB, binding + registering it on first use (cursor/limit 0 and allocBlock = −1 so
// the first allocation refills). The codegen seam calls this, then rtTlabAlloc(tlab, space, size).
void* rt_self_tlab_get(void) {
    if (!rt_self_tlab) {
        int64_t* t = (int64_t*)calloc(1, 48);
        t[2] = -1;                    // allocBlock @16 = none (cursor/limit 0/0 force a refill)
        pthread_mutex_lock(&rt_tlab_lock);
        if (rt_tlab_count < RT_TLAB_MAX) { rt_tlab_table[rt_tlab_count++] = t; }
        pthread_mutex_unlock(&rt_tlab_lock);
        rt_self_tlab = t;
    }
    return rt_self_tlab;
}

// Reset every carrier's TLAB after a collection. Called under STW (all carriers stopped at safepoints, none
// in rt_self_tlab_get), so the table read needs no lock: drop the current hole (cursor = limit = 0) and
// current block (allocBlock = −1) so the next allocation refills from the post-collection pool. Required
// because evacuation may have relocated a carrier's current block.
void rt_tlab_reset_all(void) {
    for (int i = 0; i < rt_tlab_count; i++) {
        int64_t* t = (int64_t*)rt_tlab_table[i];
        t[0] = 0; t[1] = 0; t[2] = -1; t[3] = 0; t[4] = 0;
    }
}

// ---- Per-carrier write-barrier mod-buffers (task 150.4.2, §11.3) ----
// Each carrier owns a growable mod-buffer { count@0, cap@8, storage@16 } — the remembered set the barrier
// slow path (rtGcRemember) appends mutated mature objects to. Bound lazily per carrier and registered in a
// table so the collector resets every buffer at end-of-collection (rt_modbuf_reset_all), mirroring the TLAB.
// The Nomu side (rtModBufAppend) does the growth + append; C only binds, registers, and resets.
_Thread_local void* rt_self_modbuf = NULL;
#define RT_MODBUF_MAX 256
static void* rt_modbuf_table[RT_MODBUF_MAX];
static int rt_modbuf_count = 0;
static pthread_mutex_t rt_modbuf_lock = PTHREAD_MUTEX_INITIALIZER;

// Return this carrier's mod-buffer, binding + registering it on first use. Initial capacity 4096 object
// slots; rtModBufAppend doubles it on overflow (freeing the old storage), updating storage@16 + cap@8.
void* rt_self_modbuf_get(void) {
    if (!rt_self_modbuf) {
        int64_t* m = (int64_t*)calloc(1, 24);
        int64_t cap = 4096;
        m[0] = 0;                             // count @0
        m[1] = cap;                           // cap @8
        m[2] = (int64_t)calloc((size_t)cap, 8); // storage @16
        pthread_mutex_lock(&rt_modbuf_lock);
        if (rt_modbuf_count < RT_MODBUF_MAX) { rt_modbuf_table[rt_modbuf_count++] = m; }
        pthread_mutex_unlock(&rt_modbuf_lock);
        rt_self_modbuf = m;
    }
    return rt_self_modbuf;
}

// Reset every carrier's mod-buffer after a collection (count = 0; keep the grown storage + cap). Called under
// STW alongside rt_tlab_reset_all — the remembered set is drained by the collection, so it starts empty for
// the next cycle. No lock: all carriers are stopped at safepoints, none in rt_self_modbuf_get.
void rt_modbuf_reset_all(void) {
    for (int i = 0; i < rt_modbuf_count; i++) {
        int64_t* m = (int64_t*)rt_modbuf_table[i];
        m[0] = 0;
    }
}

// Drain every carrier's mod-buffer into `outBuf` (the minor GC's remembered set, task 150.4.3): copy each
// carrier's remembered object pointers (up to `cap` total), reset every buffer's count, and return the total.
// Called under STW by the minor collector (via RawPtr.gcDrainModBufs), so the table read needs no lock. The
// drain both collects and resets, so the coordinator does not also call rt_modbuf_reset_all.
// The remembered-set size the last drain returned, for the collection log.
static int64_t rt_dbg_last_drain = 0;

int64_t rt_modbuf_drain(void* outBuf, int64_t cap) {
    int64_t* out = (int64_t*)outBuf;
    int64_t total = 0;
    for (int i = 0; i < rt_modbuf_count; i++) {
        int64_t* m = (int64_t*)rt_modbuf_table[i];
        int64_t cnt = m[0];
        int64_t* storage = (int64_t*)m[2];
        for (int64_t j = 0; j < cnt && total < cap; j++) {
            out[total++] = storage[j];
        }
        m[0] = 0;   // reset — the remembered set is consumed by this collection
    }
    rt_dbg_last_drain = total;
    return total;
}

// Guards the one-time creation of the self-hosted Immix space (150.3.10.1). The alloc seam does
// double-checked locking around it: multiple carriers race the first self-hosted allocation, and without
// this each would build its own 256 MiB heap and corrupt the shared descriptor.
static pthread_mutex_t rt_selfhost_space_lock = PTHREAD_MUTEX_INITIALIZER;
void rt_selfhost_space_lock_acquire(void) { pthread_mutex_lock(&rt_selfhost_space_lock); }
void rt_selfhost_space_lock_release(void) { pthread_mutex_unlock(&rt_selfhost_space_lock); }

// ---- Write barrier slow path ----
// The codegen `__nomu_write_barrier` seam stores `val` into `*slot` (a managed reference field of the
// managed object `obj`), tests `obj`'s log bit inline, and calls this on the first mutation of a mature
// object. It remembers `obj` in this carrier's mod-buffer (task 150.4.2). rtGcRemember re-tests the log bit
// (the actor/mailbox path calls this seam directly, bypassing the inline test) so only mature objects are
// remembered; it no-ops before the space exists. slot/val are unused — the remembered set is
// object-remembering (the minor GC rescans the object's slots). Never triggers GC, so its call site stays
// `gc-leaf`.
extern void nomu_fn_rtGcRemember(void* modbuf, void* obj);

// Slow-path calls since the last collection, for the `NOMU_GC_DEBUG_PRESSURE` collection log.
static int64_t rt_dbg_barrier_slow = 0;

void rt_gc_write_barrier(void* obj, void* slot, void* val) {
    (void)slot;
    (void)val;
    __atomic_fetch_add(&rt_dbg_barrier_slow, 1, __ATOMIC_RELAXED);
    nomu_fn_rtGcRemember(rt_self_modbuf_get(), obj);
}

// ---- GC type descriptors (task 100.4.7: link-time offset-as-id) ----
// Every module emits a fixed-size descriptor per heap type into `__DATA,__nomu_descs` (weak, so
// cross-module duplicates fold at link), with the variable managed-offset map out of line in
// `__DATA,__nomu_ptrmaps`. A type-id is a descriptor's byte offset from the section start — a
// link-resolved symbol difference stamped into object headers and VWTs — so separately compiled
// modules never collide on id values and a dependency's types are present at the same section the
// collector reads here. The record layout matches the codegen `gcDescType` (backend.md §4).
typedef struct {
    int32_t size;        // fixed object byte size (header included); 0 for an array buffer
    int32_t stride;      // array element byte size; 0 for a fixed object
    int32_t kind;        // 0 = fixed, 1 = array buffer, 2 = shaped (task 176)
    int32_t nptr;        // number of managed-pointer offsets in the out-of-line map (serialized length for kind 2)
    int32_t ptrmap_off;  // byte offset of this type's [off…] array within __nomu_ptrmaps
    int32_t nshaped;     // count of shaped-field entries after the nptr direct offsets (task 176 site 2)
    int32_t header_size; // buffer user-header bytes between the 16-byte prefix and the elements (task 180); 0 otherwise
    int32_t nheader;     // count of managed-pointer offsets within that header, the blob prefix before the element map (task 180)
} nomu_gc_desc;

#define NOMU_GC_DESC_SIZE ((unsigned long)sizeof(nomu_gc_desc))

static const uint8_t* gc_descs_base = NULL;
static unsigned long   gc_descs_size = 0;
static const uint8_t* gc_ptrmaps_base = NULL;
static int gc_desc_inited = 0;

static void nomu_gc_desc_init(void) {
    if (gc_desc_inited) {
        return;
    }
    gc_desc_inited = 1;
#ifdef __APPLE__
    unsigned long sz = 0;
    gc_descs_base = getsectiondata(&_mh_execute_header, "__DATA", "__nomu_descs", &sz);
    gc_descs_size = gc_descs_base ? sz : 0;
    unsigned long psz = 0;
    gc_ptrmaps_base = getsectiondata(&_mh_execute_header, "__DATA", "__nomu_ptrmaps", &psz);
#endif
}

// The descriptor at byte offset `type_id`, or NULL if the offset is out of the section (a bug — every
// live object carries a codegen-stamped offset). Lazily resolves the section bases on first use.
static inline const nomu_gc_desc* gc_desc_at(uint64_t type_id) {
    if (!gc_desc_inited) {
        nomu_gc_desc_init();
    }
    if (!gc_descs_base || type_id + NOMU_GC_DESC_SIZE > gc_descs_size) {
        return NULL;
    }
    return (const nomu_gc_desc*)(gc_descs_base + type_id);
}

// The number of descriptors = section size / record size (task 100.4.7 replaces the compile-time dense
// count). The self-hosted collector sizes its per-type histograms from this; iteration steps by the
// record size to recover each type-id (see `rtTryMark` / `rtCheckPayloadWord`, runtime.nomu).
uint64_t nomu_gc_typecount(void) {
    if (!gc_desc_inited) {
        nomu_gc_desc_init();
    }
    return NOMU_GC_DESC_SIZE ? (uint64_t)(gc_descs_size / NOMU_GC_DESC_SIZE) : 0;
}

// Managed-field byte offsets for a type-id (NULL if out of range); *out_count receives the count.
// The binding's `scan_object` and the self-check below both walk objects through this.
const int32_t* nomu_gc_typemap(uint64_t type_id, int32_t* out_count) {
    const nomu_gc_desc* d = gc_desc_at(type_id);
    if (!d) {
        *out_count = 0;
        return NULL;
    }
    *out_count = d->nptr;
    return (const int32_t*)(gc_ptrmaps_base + (unsigned)d->ptrmap_off);
}

// Total object byte size for a type-id. The binding's `ObjectModel::get_current_size` reads this to
// size an object for copying — every object of a given type-id is this fixed size.
uint64_t nomu_gc_typesize(uint64_t type_id) {
    const nomu_gc_desc* d = gc_desc_at(type_id);
    return d ? (uint64_t)d->size : 0;
}

// Object kind for a type-id: 0 = fixed-size, 1 = variable-size array buffer.
int32_t nomu_gc_typekind(uint64_t type_id) {
    const nomu_gc_desc* d = gc_desc_at(type_id);
    return d ? d->kind : 0;
}

// Shaped fields (task 176 Stage 1 site 2): fields of an object, or of each buffer element, with conditional
// content (a `String`, an enum with managed payload), which the collector recurses into via their sub-shape
// rather than scanning as a direct managed pointer. The entries follow the `nheader` header offsets and the
// `nptr` direct offsets in the map, two i32 each — `(field byte offset, sub-shape type-id)`. `nshaped` is 0
// for the ordinary object and buffer, so these are off the hot path. The sub-shape type-id is a descriptor
// offset, handed straight to `nomu_gc_live_offsets`.
int32_t nomu_gc_shaped_count(uint64_t type_id) {
    const nomu_gc_desc* d = gc_desc_at(type_id);
    return d ? d->nshaped : 0;
}
int32_t nomu_gc_shaped_offset(uint64_t type_id, int32_t k) {
    const nomu_gc_desc* d = gc_desc_at(type_id);
    if (!d || k < 0 || k >= d->nshaped) return 0;
    const int32_t* map = (const int32_t*)(gc_ptrmaps_base + (unsigned)d->ptrmap_off);
    return map[d->nheader + d->nptr + 2 * k];
}
int32_t nomu_gc_shaped_shapeid(uint64_t type_id, int32_t k) {
    const nomu_gc_desc* d = gc_desc_at(type_id);
    if (!d || k < 0 || k >= d->nshaped) return 0;
    const int32_t* map = (const int32_t*)(gc_ptrmaps_base + (unsigned)d->ptrmap_off);
    return map[d->nheader + d->nptr + 2 * k + 1];
}

// Array element byte stride for an array-buffer type-id. 0 for a fixed type.
uint64_t nomu_gc_typestride(uint64_t type_id) {
    const nomu_gc_desc* d = gc_desc_at(type_id);
    return d ? (uint64_t)d->stride : 0;
}

// The descriptor record byte size (task 180). The single source of truth for the record stride: the
// self-hosted collector reads this to map a type-id (a descriptor byte offset) to its dense ordinal and
// back, so growing the record never desyncs the two sides.
uint64_t nomu_gc_descsize(void) {
    return NOMU_GC_DESC_SIZE;
}

// Buffer user-header byte size for a type-id (task 180): the bytes between the 16-byte primitive prefix
// (`{ type-id, cap }`) and the first element, so element 0 sits at `16 + header_size`. 0 for an array
// buffer (no header) and for a fixed object. Both collectors read it to locate the element region.
int32_t nomu_gc_typeheadersize(uint64_t type_id) {
    const nomu_gc_desc* d = gc_desc_at(type_id);
    return d ? d->header_size : 0;
}

// The buffer header's managed-pointer map (task 180): `nomu_gc_typeheaderptrs` is the count `nheader`, and
// `nomu_gc_headeroffset` the k-th header managed byte offset (relative to the header base at `base + 16`) —
// the first `nheader` entries of the pointer-map blob, before the element map. Both collectors scan the
// header once per buffer through these, the same way they scan the element map at each element.
int32_t nomu_gc_typeheaderptrs(uint64_t type_id) {
    const nomu_gc_desc* d = gc_desc_at(type_id);
    return d ? d->nheader : 0;
}
int32_t nomu_gc_headeroffset(uint64_t type_id, int32_t k) {
    const nomu_gc_desc* d = gc_desc_at(type_id);
    if (!d || k < 0 || k >= d->nheader) return 0;
    const int32_t* map = (const int32_t*)(gc_ptrmaps_base + (unsigned)d->ptrmap_off);
    return map[k];
}

// The shared shaped-root/field enumerator (task 176, shaped-roots.md Stage 5): resolve the live
// managed-pointer byte offsets of a value at `base` for `type_id`, writing the count to `*out_count` and
// returning a pointer to a contiguous `int32_t[*out_count]` offset array. For kind 0/1 with no shaped entries
// this is the static flat map (data-independent, identical to `nomu_gc_typemap`; `base` unused). For a kind-1
// buffer the offsets are an element's, relative to the element, and `base` is that element's address: a
// buffer whose elements carry shaped entries is enumerated once per element. For kind 2 (shaped) the map
// is discriminant-keyed — `[tag_off, tag_shift, ncases, (tag, count, off…)…]` — so the tag is read from the
// value (`*(uint64_t*)(base + tag_off) >> tag_shift`) and the matching case's offsets returned; a tag in no
// case (e.g. String `small` / `immortal`) yields count 0. Both the stackmap root path and the object-field
// recursion call through here, so the kind-2 tag-decode lives in exactly one place (the lockstep obligation).
// A per-thread scratch for the object-field fold below (carriers may scan concurrently). The returned
// offset array is valid only until the caller's next `nomu_gc_live_offsets` call, which every consumer
// honours (it reads the offsets before re-entering). Grows on demand and is reused across calls.
static _Thread_local int32_t* gc_live_scratch = NULL;
static _Thread_local int32_t gc_live_scratch_cap = 0;
static int32_t* gc_live_scratch_ensure(int32_t need) {
    if (need > gc_live_scratch_cap) {
        int32_t cap = gc_live_scratch_cap ? gc_live_scratch_cap : 16;
        while (cap < need) cap *= 2;
        gc_live_scratch = (int32_t*)realloc(gc_live_scratch, (size_t)cap * sizeof(int32_t));
        gc_live_scratch_cap = cap;
    }
    return gc_live_scratch;
}

// A second scratch for the enum kind-2 path (task 176.3b): distinct from `gc_live_scratch` so the kind-0
// object-field fold and a kind-2 enum scan can be live at once without aliasing (a struct holding an
// `Option<String>` folds the enum via this buffer while the object fold uses the other). An enum case's
// nested sub-entries are Strings — a kind-2 leaf that returns a static map pointer and uses no scratch — so
// one enum-scratch level suffices; a nested enum-in-enum payload is rejected at descriptor build.
static _Thread_local int32_t* gc_live_scratch_enum = NULL;
static _Thread_local int32_t gc_live_scratch_enum_cap = 0;
static int32_t* gc_live_scratch_enum_ensure(int32_t need) {
    if (need > gc_live_scratch_enum_cap) {
        int32_t cap = gc_live_scratch_enum_cap ? gc_live_scratch_enum_cap : 16;
        while (cap < need) cap *= 2;
        gc_live_scratch_enum = (int32_t*)realloc(gc_live_scratch_enum, (size_t)cap * sizeof(int32_t));
        gc_live_scratch_enum_cap = cap;
    }
    return gc_live_scratch_enum;
}

const int32_t* nomu_gc_live_offsets(uint64_t type_id, const void* base, int32_t* out_count) {
    const nomu_gc_desc* d = gc_desc_at(type_id);
    if (!d) {
        *out_count = 0;
        return NULL;
    }
    const int32_t* map = (const int32_t*)(gc_ptrmaps_base + (unsigned)d->ptrmap_off);
    if (d->kind == 2) {                 // shaped value: discriminant-keyed map, read the tag
        int32_t tag_off = map[0];
        int32_t tag_shift = map[1];
        int32_t ncases = map[2];
        uint64_t word = *(const uint64_t*)((const uint8_t*)base + tag_off);
        uint64_t tag = word >> tag_shift;
        // Per-case format `(tag, nFlat, flat…, nShaped, (off, subId)…)` (task 176.3b). A flat-only case
        // (String, or a conditional class pointer) returns its offsets directly; a case with nested shaped
        // sub-entries (an `Option<String>` payload) recurses each into the enum scratch.
        const int32_t* p = map + 3;
        for (int32_t c = 0; c < ncases; c++) {
            int32_t case_tag = p[0];
            int32_t nflat = p[1];
            const int32_t* flat = p + 2;
            int32_t nshaped = p[2 + nflat];
            const int32_t* subs = p + 2 + nflat + 1;   // `(off, subId)` pairs
            if ((uint64_t)case_tag != tag) { p = subs + 2 * nshaped; continue; }
            if (nshaped == 0) {               // flat-only case: the offsets live in the static map
                *out_count = nflat;
                return nflat ? flat : NULL;
            }
            int32_t* out = gc_live_scratch_enum_ensure(nflat + nshaped);
            int32_t n = 0;
            for (int32_t k = 0; k < nflat; k++) out[n++] = flat[k];
            for (int32_t k = 0; k < nshaped; k++) {
                int32_t off = subs[2 * k];
                int32_t sub_id = subs[2 * k + 1];
                int32_t sub_cnt = 0;
                const int32_t* sub = nomu_gc_live_offsets((uint64_t)sub_id, (const uint8_t*)base + off, &sub_cnt);
                out = gc_live_scratch_enum_ensure(n + sub_cnt);
                for (int32_t j = 0; j < sub_cnt; j++) out[n++] = off + sub[j];
            }
            *out_count = n;
            return n ? out : NULL;
        }
        *out_count = 0;                 // tag carries no managed pointer (String small/immortal, enum .none)
        return NULL;
    }
    // kind 0/1 with no shaped fields — the common object/array: the static flat map, no work (178.1).
    // For a buffer the element map follows the `nheader` header offsets in the blob (task 180), so skip
    // that prefix; a fixed object and an array both have `nheader = 0`, so the skip is a no-op there.
    const int32_t* flat = map + d->nheader;
    if (d->nshaped == 0) {
        *out_count = d->nptr;
        return flat;
    }
    // An object (kind 0) or a buffer element (kind 1) carrying shaped fields (task 176 Stage 1 site 2): a
    // `String` field inside a class/actor or an `Array<String>` element. Fold each shaped field's live
    // sub-offsets into the direct offsets so the one scan path reaches them — the flat `nptr` direct offsets,
    // then for each of the `nshaped` `(field offset, sub-shape type-id)` entries, the enumerator recurses into
    // the sub-shape at `base + field offset` (which reads its tag) and appends `field offset + sub offset` for
    // each live word. A `heap` String field thus contributes its `word0`; an `immortal`/`small` one contributes
    // nothing. The sub-shape is a kind-2 descriptor (a leaf, or an enum, which uses its own scratch), so its
    // recursive call never touches this scratch — a nested object-with-shaped-fields sub-shape would need a
    // recursion-safe buffer.
    int32_t base_n = d->nptr;
    int32_t* out = gc_live_scratch_ensure(base_n + d->nshaped);
    int32_t n = 0;
    for (int32_t i = 0; i < base_n; i++) out[n++] = flat[i];
    for (int32_t k = 0; k < d->nshaped; k++) {
        int32_t field_off = flat[base_n + 2 * k];
        int32_t sub_id = flat[base_n + 2 * k + 1];
        int32_t sub_cnt = 0;
        const int32_t* sub = nomu_gc_live_offsets((uint64_t)sub_id, (const uint8_t*)base + field_off, &sub_cnt);
        out = gc_live_scratch_ensure(n + sub_cnt);
        for (int32_t j = 0; j < sub_cnt; j++) out[n++] = field_off + sub[j];
    }
    *out_count = n;
    return out;
}

void rt_free(void* p) { free(p); }

// Unsafe raw-memory floor (task 125 · RawPtr / Ptr<T>). Off-heap, unmanaged memory the moving
// collector never sees — the surface the self-hosted allocator is built on (task 150). `align` is a
// power-of-two byte alignment. Memory is zero-initialized: the allocator relies on fresh memory reading as
// zero. Freed by hand via rt_raw_free; never GC-reclaimed.
void* rt_raw_alloc(int64_t bytes, int64_t align) {
    if (bytes <= 0) return NULL;
    size_t a = (size_t)align < sizeof(void*) ? sizeof(void*) : (size_t)align;
    void* p = NULL;
    if (posix_memalign(&p, a, (size_t)bytes) != 0) {
        fputs("out of memory\n", stderr);
        exit(1);
    }
    memset(p, 0, (size_t)bytes);
    return p;
}

void rt_raw_free(void* p) { free(p); }

// Array bounds violation (M6 stdlib · Slice 3). Codegen emits a check on every subscript and calls
// this on an out-of-range index; it prints and aborts (Swift-style trap). Never returns.
void rt_bounds_trap(int64_t idx, int64_t len) {
    fprintf(stderr, "fatal error: array index %lld out of range for length %lld\n",
            (long long)idx, (long long)len);
    abort();
}


// ---- Structured concurrency ----
// The returned handle is the Nomu scheduler's opaque fiber pointer, which spawn_join passes straight back to
// nomuSchedJoin (codegen treats it as an opaque Fiber*).
Fiber* fiber_spawn(void* (*fn)(void*), void* arg) {
    return (Fiber*)nomu_fn_nomuSchedSpawn(rt_nomu_sched, (void*)fn, arg);
}

// `final` (150.3.13): the structured scope-exit join, at which the scheduler drops the fiber from the
// live-fiber registry (its result box is no longer needed). Intermediate reads pass 0.
void* spawn_join(SpawnHandle* h, int64_t final) {
    RT_USER_ANCHOR(sp, pc);
    return nomu_fn_nomuSchedJoin(rt_nomu_sched, (void*)h->fiber, sp, pc, final);
}

// ---- Actor mailbox (fire-and-forget message-send) ----
// The mailbox and message layouts are the ABI contract in runtime.h; the Nomu scheduler owns the scheduled-
// mailbox queue and the mailbox-fiber pool (nomuSchedActorSend / nomuSchedMailboxPop).
//
// The drain LOOP is emitted by codegen, not written here: it must hold the mailbox + message as tracked
// addrspace(1) roots across each handler call (a moving GC can relocate them at a safepoint inside the
// handler), which C code can't. Codegen's `nomu_actor_drain(mailbox)` loops over rt_mailbox_pop →
// `msg->thunk(msg)` until the mailbox is empty. Codegen emits the real nomu_actor_drain only for programs
// that use actors; an actor-less program dead-strips the whole send/drain subgraph. main() passes its address
// to the scheduler boot unconditionally, so a weak fallback definition here keeps the symbol defined either
// way. The codegen strong definition overrides this stub when present; the stub is never called without an
// actor send.
__attribute__((weak)) void nomu_actor_drain(void* mailbox) { (void)mailbox; }

// Pop the next message from `mailbox` in FIFO order, or NULL when empty (which also clears the drain flag).
// No safepoint/allocation inside → GC cannot move `mailbox` across this call, so codegen's tracked mailbox
// pointer stays valid. Called from codegen's `nomu_actor_drain`.
void* rt_mailbox_pop(void* mailbox) {
    return nomu_fn_nomuSchedMailboxPop(rt_nomu_sched, mailbox);
}

// Enqueue `msg` on `mailbox` and return immediately — fire-and-forget (concurrency.md §9).
void rt_actor_send(void* mailbox, void* msg) {
    nomu_fn_nomuSchedActorSend(rt_nomu_sched, mailbox, msg);
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

// ---- Blocking primitives ----
int64_t rt_sleep_ms(int64_t ms) {
    RT_USER_ANCHOR(sp, pc);
    return nomu_fn_nomuSchedSleep(rt_nomu_sched, ms, sp, pc);
}

// ---- Line input and the I/O poller ----
// `readLine` reads stdin through one line buffer. A fiber whose line is not buffered yet checks readiness
// with poll(2); when stdin has nothing to read it joins the stdin waiter list and parks, so its carrier runs
// other fibers meanwhile. One poller thread (started on first use) blocks in kevent(2) on a one-shot read
// event for stdin and, when it fires, unparks every waiter; each re-checks the buffer, and one that still
// finds nothing waits again. Every waiter shares the one kqueue registration: kqueue keys an event by
// (fd, filter), so arming per fiber would overwrite an earlier waiter's wake-up.
//
// Lock order: rt_in_mu, then the scheduler lock. A parking fiber takes the scheduler lock before it
// releases rt_in_mu, and the poller takes the scheduler lock (rtSchedUnpark) only after releasing rt_in_mu,
// so an unpark cannot re-queue a fiber whose context is not saved yet. rt_in_mu is never held across a park.
extern void* nomu_fn_nomuSchedCurrent(void);
extern void  nomu_fn_nomuSchedParkLocked(void* sched, void* anchorSp, void* anchorPc);
extern void  nomu_fn_rtSchedLock(void* sched);
extern void  nomu_fn_rtSchedUnpark(void* sched, void* fib);

typedef struct RtWaiter { void* fiber; struct RtWaiter* next; } RtWaiter;

static pthread_mutex_t rt_in_mu = PTHREAD_MUTEX_INITIALIZER;
static char* rt_in_buf = NULL;        // buffered stdin bytes not yet returned
static size_t rt_in_len = 0, rt_in_cap = 0;
static int rt_in_eof = 0;
static RtWaiter* rt_in_waiters = NULL;
static int rt_in_armed = 0;           // a one-shot read event for stdin is registered

#ifdef __APPLE__
static int rt_kq = -1;
static pthread_once_t rt_poller_once = PTHREAD_ONCE_INIT;

static void* rt_poller_thread(void* _) {
    (void)_;
    struct kevent ev[8];
    for (;;) {
        int n = kevent(rt_kq, NULL, 0, ev, 8, NULL);
        if (n <= 0) continue;
        pthread_mutex_lock(&rt_in_mu);
        RtWaiter* w = rt_in_waiters;
        rt_in_waiters = NULL;
        rt_in_armed = 0;
        pthread_mutex_unlock(&rt_in_mu);
        while (w) {
            RtWaiter* nx = w->next;
            nomu_fn_rtSchedUnpark(rt_nomu_sched, w->fiber);
            free(w);
            w = nx;
        }
    }
    return NULL;
}

static void rt_poller_start(void) {
    rt_kq = kqueue();
    pthread_t t;
    pthread_create(&t, NULL, rt_poller_thread, NULL);
    pthread_detach(t);
}
#endif

// Whether `fd` has input (or end of input) right now, without blocking.
static int rt_fd_ready(int fd) {
    struct pollfd p = { fd, POLLIN, 0 };
    return poll(&p, 1, 0) > 0;
}

// Take one line (without its newline) off the front of the buffer, or the remainder at end of input, as an
// `immortal` String: an off-heap buffer never freed, so a moving collection never relocates it.
static String rt_in_take(size_t n, size_t consumed) {
    char* data = (char*)calloc(1, sizeof(ObjectHeader) + n + 1);
    if (!data) {
        fputs("out of memory\n", stderr);
        exit(1);
    }
    data += sizeof(ObjectHeader);
    memcpy(data, rt_in_buf, n);
    memmove(rt_in_buf, rt_in_buf + consumed, rt_in_len - consumed);
    rt_in_len -= consumed;
    return nomu_str_make(data, (int64_t)n, NOMU_STR_TAG_IMMORTAL);
}

// Read one line from stdin (`fd` is always 0: readLine's only source). Returns the line without its
// newline; at end of input, the unterminated remainder, then empty strings.
String rt_read_line(int fd) {
    RT_USER_ANCHOR(sp, pc);
    pthread_mutex_lock(&rt_in_mu);
    for (;;) {
        char* nl = rt_in_len ? memchr(rt_in_buf, '\n', rt_in_len) : NULL;
        if (nl) {
            size_t n = (size_t)(nl - rt_in_buf);
            String s = rt_in_take(n, n + 1);
            pthread_mutex_unlock(&rt_in_mu);
            return s;
        }
        if (rt_in_eof) {
            String s = rt_in_take(rt_in_len, rt_in_len);
            pthread_mutex_unlock(&rt_in_mu);
            return s;
        }
#ifdef __APPLE__
        if (!rt_fd_ready(fd)) {
            // Nothing to read: wait for the poller, then re-check from the top.
            pthread_once(&rt_poller_once, rt_poller_start);
            RtWaiter* w = (RtWaiter*)malloc(sizeof(RtWaiter));
            w->fiber = nomu_fn_nomuSchedCurrent();
            w->next = rt_in_waiters;
            rt_in_waiters = w;
            if (!rt_in_armed) {
                struct kevent ev;
                EV_SET(&ev, fd, EVFILT_READ, EV_ADD | EV_ONESHOT, 0, 0, NULL);
                kevent(rt_kq, &ev, 1, NULL, 0, NULL);
                rt_in_armed = 1;
            }
            nomu_fn_rtSchedLock(rt_nomu_sched);
            pthread_mutex_unlock(&rt_in_mu);
            nomu_fn_nomuSchedParkLocked(rt_nomu_sched, sp, pc);   // returns with the scheduler lock released
            pthread_mutex_lock(&rt_in_mu);
            continue;
        }
#endif
        // Readable (or no poller on this platform): read what is there. Holding rt_in_mu here serializes
        // readers; a readable fd does not block.
        if (rt_in_cap - rt_in_len < 4096) {
            rt_in_cap = rt_in_cap ? rt_in_cap * 2 : 8192;
            rt_in_buf = (char*)realloc(rt_in_buf, rt_in_cap);
            if (!rt_in_buf) {
                fputs("out of memory\n", stderr);
                exit(1);
            }
        }
        ssize_t n = read(fd, rt_in_buf + rt_in_len, rt_in_cap - rt_in_len);
        if (n > 0) {
            rt_in_len += (size_t)n;
        } else {
            rt_in_eof = 1;   // end of input (or a read error, treated the same)
        }
    }
}

// ---- GC frame index check ----
// The collector's stack walk (`rtFrameLookup` / `rtWalkFrom`, runtime.nomu) maps a frame's return address to
// its `__llvm_stackmaps` record through the frame index the driver writes into the binary after the link
// (`__DATA_CONST,__nomu_frameidx`, layout in the driver's FrameIndex.swift). A binary with stackmaps but no
// index was linked without that step; its frames' roots cannot be found, so main aborts up front.
#define GC_FRAMEIDX_MAGIC 0x5849464Eu // "NFIX"

static uint32_t gc_rd32(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void nomu_gc_frameidx_check(void) {
#ifdef __APPLE__
    unsigned long smsize = 0, fxsize = 0;
    const uint8_t* sm = getsectiondata(&_mh_execute_header, "__LLVM_STACKMAPS", "__llvm_stackmaps", &smsize);
    const uint8_t* fx = getsectiondata(&_mh_execute_header, "__DATA_CONST", "__nomu_frameidx", &fxsize);
    if (sm && smsize > 0) {
        // The index starts at the section's first 8-aligned address (the section itself is byte-aligned).
        uintptr_t at = ((uintptr_t)fx + 7) & ~(uintptr_t)7;
        if (!fx || at + 16 > (uintptr_t)fx + fxsize || gc_rd32((const uint8_t*)at) != GC_FRAMEIDX_MAGIC ||
            gc_rd32((const uint8_t*)at + 4) != 2) {
            fprintf(stderr, "nomu: this binary has no GC frame index (it was linked without `nomu build`)\n");
            abort();
        }
    }
#endif
}

// ---- Safepoint ----
// The stop-the-world poll flag, read by the inlined back-edge poll (LLVMGenRuntime.swift) and the scheduler.
// A GC driver thread raises it with the scheduler's stw-request; a running fiber that sees it calls
// __nomu_gc_poll_slow.
volatile int __nomu_stop_world = 0;

// The safepoint slow path. poll_slow is the immediate callee of the user code at the poll site, so its return
// address is a statepoint the pcsp walk (rtWalkFrom) matches; it hands that anchor to the scheduler, which
// parks this fiber at the safepoint until resume. Not `gc-leaf`.
void __nomu_gc_poll_slow(void) {
    RT_USER_ANCHOR(sp, pc);
    nomu_fn_nomuSchedSafepoint(rt_nomu_sched, sp, pc);
}

// ---- Process entry ----
extern void nomu_main(void);

static void* __rt_main_entry(void* _) {
    nomu_main();
    return NULL;
}

// Forced self-hosted stop-the-world smoke (task 128.3.2, env NOMU_STW_SELFHOST). Drives a real STW over
// the self-hosted scheduler's carriers and runs the self-hosted root walk (rtWalkFrom over the live-fiber
// registry). This coordinator is a plain thread, not a fiber, so it never polls/parks itself. Sched field offsets mirror runtime.nomu.
static int64_t rt_stw_ld(int off)  { return __atomic_load_n((int64_t*)((char*)rt_nomu_sched + off), __ATOMIC_SEQ_CST); }
static void    rt_stw_st(int off, int64_t v) { __atomic_store_n((int64_t*)((char*)rt_nomu_sched + off), v, __ATOMIC_SEQ_CST); }

static void* rt_stw_selfhost_thread(void* _) {
    struct timespec warmup = {0, 40 * 1000 * 1000}; nanosleep(&warmup, NULL); // let the program get going
    int rounds = 3;
    for (int r = 0; r < rounds; r++) {
        int64_t ncarriers = rt_stw_ld(160);
        // Request the stop: raise both the poll trigger (read by the inlined safepoint) and the Nomu
        // handshake request, then wake idle carriers so they reach the ack path promptly.
        rt_stw_st(136, 1);          // stw-request
        __nomu_stop_world = 1;
        __atomic_fetch_add((int64_t*)((char*)rt_nomu_sched + 24), 1, __ATOMIC_SEQ_CST); // bump wake-gen
        __ulock_wake(0x01000101, (char*)rt_nomu_sched + 24, 0);                          // wake all idle carriers
        // Wait until every carrier has acked (all mutators stopped at a safepoint / parked).
        while (rt_stw_ld(144) < ncarriers) {
            struct timespec s = {0, 500 * 1000}; nanosleep(&s, NULL);
        }
        // World stopped: run the self-hosted walk over every parked/stopped fiber's anchor.
        void** buf = (void**)malloc(sizeof(void*) * 1024);
        int64_t nr = nomu_fn_nomuSchedWalkParked(rt_nomu_sched, buf, 1024);
        fprintf(stderr, "nomu-stw-selfhost: round %d nroots %lld\n", r, (long long)nr);
        for (int64_t i = 0; i < nr; i++) {
            int64_t v = ((int64_t*)buf[i])[1];   // class { i64 header, i64 v } → the Int at offset 8
            fprintf(stderr, "STW-ROOT %lld\n", (long long)v);
        }
        free(buf);
        // Resume the world: reset the ack, clear the request, and wake the parked carriers.
        rt_stw_st(144, 0);
        rt_stw_st(136, 0);
        __nomu_stop_world = 0;
        __atomic_fetch_add((int64_t*)((char*)rt_nomu_sched + 152), 1, __ATOMIC_SEQ_CST); // bump stw-gen
        __ulock_wake(0x01000101, (char*)rt_nomu_sched + 152, 0);                          // wake parked carriers
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
        __nomu_stop_world = 1;
        __atomic_fetch_add((int64_t*)((char*)rt_nomu_sched + 24), 1, __ATOMIC_SEQ_CST);
        __ulock_wake(0x01000101, (char*)rt_nomu_sched + 24, 0);
        while (rt_stw_ld(144) < ncarriers) {
            struct timespec s = {0, 500 * 1000}; nanosleep(&s, NULL);
        }
        int64_t nr = nomu_fn_nomuSchedStwCollect(rt_nomu_sched);
        rt_tlab_reset_all();   // 150.3.10.1 — evacuation may have moved a carrier's block; refill on resume
        rt_modbuf_reset_all(); // 150.4.2 — the collection drains the remembered set; start empty next cycle
        fprintf(stderr, "nomu-stw-collect: round %d fixed %lld roots\n", r, (long long)nr);
        rt_stw_st(144, 0);
        rt_stw_st(136, 0);
        __nomu_stop_world = 0;
        __atomic_fetch_add((int64_t*)((char*)rt_nomu_sched + 152), 1, __ATOMIC_SEQ_CST);
        __ulock_wake(0x01000101, (char*)rt_nomu_sched + 152, 0);
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
    int dbg = getenv("NOMU_GC_DEBUG_PRESSURE") != NULL;
    int collections = 0;
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
        __nomu_stop_world = 1;
        __atomic_fetch_add((int64_t*)((char*)rt_nomu_sched + 24), 1, __ATOMIC_SEQ_CST);
        __ulock_wake(0x01000101, (char*)rt_nomu_sched + 24, 0);
        while (rt_stw_ld(144) < ncarriers) {
            if (rt_stw_ld(40) != 0) break;              // program finished mid-wait — stop waiting
            struct timespec s = {0, 200 * 1000}; nanosleep(&s, NULL);
        }
        int64_t nr = nomu_fn_nomuSchedStwCollectDefrag(rt_nomu_sched);
        rt_tlab_reset_all();   // 150.3.10.1 — evacuation may have moved a carrier's block; refill on resume
        rt_modbuf_reset_all(); // 150.4.2 — the collection drains the remembered set; start empty next cycle
        collections++;
        if (dbg) {
            int64_t after = nomu_fn_nomuGcSpaceAvail();
            fprintf(stderr, "nomu-gc-pressure: collection %d, %lld roots, avail %lld -> %lld\n",
                    collections, (long long)nr, (long long)avail, (long long)after);
        }
        rt_stw_st(144, 0);
        rt_stw_st(136, 0);
        __nomu_stop_world = 0;
        __atomic_fetch_add((int64_t*)((char*)rt_nomu_sched + 152), 1, __ATOMIC_SEQ_CST);
        __ulock_wake(0x01000101, (char*)rt_nomu_sched + 152, 0);
    }
    if (dbg) fprintf(stderr, "nomu-gc-pressure: exit after %d collections\n", collections);
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
    int dbg = getenv("NOMU_GC_DEBUG_PRESSURE") != NULL;
    int collections = 0;
    for (;;) {
        // Block until a mutator requests a collection (gc-request @168) or the program ends.
        while (rt_stw_ld(168) == 0) {
            if (rt_stw_ld(40) != 0) {
                if (dbg) fprintf(stderr, "nomu-gc-sync: exit after %d collections\n", collections);
                return NULL;
            }
            __ulock_wait(0x01000101, (char*)rt_nomu_sched + 168, 0, 1000);   // ~1ms backstop, re-checks the flag
        }
        rt_stw_st(168, 0);                               // consume the request (136 already set by the initiator)
        int64_t kind = rt_stw_ld(176);                   // collection kind: 1 = minor (nursery full), 0 = major/defrag (OOM)
        int64_t ncarriers = rt_stw_ld(160);
        __nomu_stop_world = 1;
        __atomic_fetch_add((int64_t*)((char*)rt_nomu_sched + 24), 1, __ATOMIC_SEQ_CST);
        __ulock_wake(0x01000101, (char*)rt_nomu_sched + 24, 0);              // wake carriers to poll + ack
        while (rt_stw_ld(144) < ncarriers) {
            if (rt_stw_ld(40) != 0) break;               // program finished mid-wait
            struct timespec s = {0, 200 * 1000}; nanosleep(&s, NULL);
        }
        int64_t nr;
        rt_dbg_last_drain = 0;
        if (kind == 1) {
            // Minor (generational) collection (150.4.3): promote the nursery, using the drained remembered set.
            nr = nomu_fn_nomuSchedStwCollectMinor(rt_nomu_sched);
            rt_tlab_reset_all();   // the reclaimed nursery blocks moved out from under the carriers' TLABs
            // No rt_modbuf_reset_all — the minor collection's drain already reset the mod-buffers.
        } else {
            nr = nomu_fn_nomuSchedStwCollectDefrag(rt_nomu_sched);
            rt_tlab_reset_all();   // 150.3.10.1 — evacuation may have moved a carrier's block; refill on resume
            rt_modbuf_reset_all(); // 150.4.2 — the collection drains the remembered set; start empty next cycle
        }
        rt_stw_st(176, 0);                               // reset the kind for the next request
        collections++;
        if (dbg) {
            int64_t after = nomu_fn_nomuGcSpaceAvail();
            int64_t slow = __atomic_exchange_n(&rt_dbg_barrier_slow, 0, __ATOMIC_RELAXED);
            fprintf(stderr, "nomu-gc-sync: collection %d (%s), %lld roots, avail -> %lld, "
                    "%lld remembered, %lld barrier slow calls\n",
                    collections, kind == 1 ? "minor" : "major", (long long)nr, (long long)after,
                    (long long)rt_dbg_last_drain, (long long)slow);
        }
        rt_stw_st(144, 0);
        rt_stw_st(136, 0);
        __nomu_stop_world = 0;
        __atomic_fetch_add((int64_t*)((char*)rt_nomu_sched + 152), 1, __ATOMIC_SEQ_CST);
        __ulock_wake(0x01000101, (char*)rt_nomu_sched + 152, 0);             // resume parked carriers (incl. initiator)
    }
}

int main(void) {
    // Nursery reserve override: a dev/test override of the default-on generational trigger (rtGenReserve reads
    // it). Positive = override the reserve; negative = disable generational (major-only); 0/unset = descriptor default.
    { const char* nr = getenv("NOMU_NURSERY_RESERVE"); if (nr) { long v = atol(nr); if (v != 0) __nomu_nursery_reserve = v; } }
    // Mature-pressure floor override (task 150.4.4): rtImmixRefill reads it to escalate a nursery-full trigger
    // to a full defrag major once free mature blocks fall below it.
    { const char* mf = getenv("NOMU_MATURE_FLOOR"); if (mf) { long v = atol(mf); if (v > 0) __nomu_mature_floor = v; } }
    // Allocation stress (rtTlabAlloc reads it): request a collection every N allocated bytes per carrier.
    { const char* gs = getenv("NOMU_GC_STRESS"); if (gs) { long v = atol(gs); if (v > 0) __nomu_gc_stress = v; } }
    // The collector's walk reads the GC frame index (`rtFrameLookup`); check here that the binary has one,
    // aborting if it was linked without it, since that walk has no C step of its own to check from.
    nomu_gc_frameidx_check();
    int nc = 4;
    const char* nc_env = getenv("NOMU_CARRIERS");
    if (nc_env) { int v = atoi(nc_env); if (v >= 1) nc = v; }
    rt_nomu_sched = nomu_fn_nomuSchedNew();
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
    int gc_driver_env = getenv("NOMU_STW_SELFHOST") || getenv("NOMU_STW_COLLECT") || getenv("NOMU_GC_PRESSURE");
    __nomu_gc_ext_driver = gc_driver_env ? 1 : 0;   // generational defers to an external STW driver (rtGenReserve)
    if (!gc_driver_env) {
        pthread_t __gc_s; pthread_create(&__gc_s, NULL, rt_gc_sync_thread, NULL); pthread_detach(__gc_s);
    }
    nomu_fn_nomuSchedBoot(rt_nomu_sched, (void*)__rt_main_entry, (int64_t)nc, (void*)nomu_actor_drain);
    return 0;
}

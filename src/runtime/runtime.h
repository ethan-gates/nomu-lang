// Nomu runtime — shared ABI (M4.13).
//
// The boundary between generated user code, the C core floor, and the privileged
// runtime. Anything the generated `user.c` or the other C files call is declared
// here; each `.c` includes this header. (Design: m4.13-spec.md; compiler.md §1.)
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

// String: length-prefixed, null-terminated, heap-allocated data.
typedef struct { char* data; int64_t len; } String;

// A fiber is opaque outside the privileged runtime; generated code only holds handles.
typedef struct Fiber Fiber;

// A structured spawn handle: a fiber whose result we will join.
typedef struct { Fiber* fiber; } SpawnHandle;

// ---- Allocation seam (privileged; the heap alloc/free the generated code uses) ----
void* rt_alloc(size_t size);
void* rt_alloc_immortal(size_t size);   // M6 · 6.2.4 — non-moving String buffers (immortal interim)
void  rt_free(void* p);
void  rt_bounds_trap(int64_t idx, int64_t len);   // M6 stdlib — array subscript out-of-range trap
void  rt_gc_write_barrier(void* obj, void* slot, void* val);   // M6 · 6.3.1 — generational write barrier

// ---- Core floor: pure value primitives ----
String rt_str_lit(const char* data, int64_t len);
String rt_str_concat(String a, String b);
void   rt_print_double(double x);   // M6 stdlib — print a Double: shortest round-tripping form, always with a decimal point, + newline

// ---- Privileged: blocking primitives + structured concurrency ----
int64_t rt_sleep_ms(int64_t ms);
String  rt_read_line(int fd);
Fiber*  fiber_spawn(void* (*fn)(void*), void* arg);
void*   spawn_join(SpawnHandle* h);

// ---- Actor mutex (opaque, heap-allocated) ----
// The C backend inlines a `pthread_mutex_t` in the actor struct; the LLVM backend has no portable
// `pthread_mutex_t` layout, so it holds an opaque `void*` to a runtime-allocated mutex instead.
void* rt_mutex_new(void);
void  rt_mutex_lock(void* m);
void  rt_mutex_unlock(void* m);

// ---- GC root scanning (M8.4.3; m6-spec.md §6.0.8) ----
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
